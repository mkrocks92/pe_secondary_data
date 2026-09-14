/*
    CVC's look-through NAV per portfolio company over time.
    COMMITMENT-BASED ownership (scaling method 1).

    ownership_pct    = cumulative Commitment transactions dated on or before the
                       valuation date / fund_size
    cvc_company_nav  = ownership_pct * company_valuation

    Ownership here is derived INDEPENDENTLY of the fund NAV, so summing
    cvc_company_nav per fund and date and comparing it to the fund's own reported
    NAV is a genuine reconciliation test. Contrast fct_company_nav_implied
    (method 2), which backsolves ownership from the fund NAV and therefore always
    ties by construction.

    Worked example from the specification: Palisade Ridge Capital's ownership is
    9,700,000 / 970,000,000 = 1%, so Brightridge Technologies at 2020-12-31 is
    150,000,000 * 1% = 1,500,000.

    ASSUMPTIONS - fct_company_nav

    Ownership numerator
    1.  Ownership is POINT IN TIME: only commitments dated on or before the
        valuation date count. Each fund currently has exactly one commitment, all
        dated 2020-12-31, so ownership is flat after that date. The cumulative
        logic still matters because it is the stated rule and because further
        commitments would change ownership mid-life.
    2.  Commitments are deduplicated on transaction_index BEFORE being summed. A
        restated commitment must replace its predecessor, not add to it, otherwise
        ownership silently doubles.
    3.  Commitment amounts are assumed positive and to represent CVC's own
        commitment, not total LP commitments to the fund.

    Ownership denominator - a known distortion
    4.  fund_size is the LATEST size of the fund, not its size at the transaction
        date, as stated in the specification. The denominator is therefore
        anachronistic: today's fund size is applied to historic valuations. If a
        fund grew after a valuation date, ownership for that date is understated
        and so is the company NAV. This cannot be corrected without a historic
        fund size series, which the extract does not provide.
    5.  fund_size is assumed constant per fund and non-zero (guarded with nullif).

    The pre-commitment edge case - READ THIS
    6.  Ironbrook Capital Partners has company valuations dated 2020-06-30, which
        PRECEDES its only commitment (2020-12-31). Applying the stated rule
        literally, cumulative commitments at that date are 0, so ownership is 0%
        and CVC's company NAV is 0 - despite Solstice Foods being valued at
        66,000,000 gross.
    7.  Those rows are RETAINED with a zero NAV rather than dropped, and flagged
        via is_pre_commitment_valuation, so the zero is visible and explainable
        instead of appearing as a silent gap. Do not report these as genuine zero
        valuations.
    8.  This is very likely the mistyped-year data issue: Ironbrook is 100%-owned,
        and the company total at 2020-06-30 (70,000,000) equals the fund NAV at
        2021-06-30 exactly. If confirmed, the fix belongs in the source, not here.

    Grain and coverage
    9.  One row per fund / company / valuation date. Company data contains only
        valuations, so unlike fct_fund_nav there are no cashflows to roll forward
        and no carry-forward to fund cashflow dates.
    10. Valuations are NOT carried forward to dates where the company was not
        valued. An absent company-date means the fund did not report, not that the
        holding was worth zero.
    11. company_valuation is gross, at 100% of the holding fund. Two funds holding
            the same company report different gross values (company 916 is carried at
        200,000,000 by Palisade and 155,000,000 by Summitvale on the same date),
        because each reports its own stake.
    12. cvc_company_nav IS additive across funds and companies within a date, which
        is the entire point of the scaling. It is a balance, so it is never additive
        across dates.
    13. 'Other Assets' (company_id 1) is a balancing plug, not a real company. It is
        included so that the sum over companies reconciles to the fund NAV; exclude
        it via dim_company.is_other_assets for genuine company-level analysis.

    Reconciliation
    14. Summing cvc_company_nav per fund and date should equal the fund's own
        reported NAV. It does so exactly except for Summitvale at 2020-12-31 and
        2021-03-31, which are unexplained source breaks, and Ironbrook at
        2020-06-30 per assumption 6.
    15. No FX conversion; all amounts assumed to be in one currency.
*/

with company_valuations as (

    select
        fund_name,
        company_id,
        company_name,
        transaction_date,
        transaction_date_key,
        gross_holding_value as company_valuation
    from {{ ref('fct_company_valuations') }}
    where transaction_type = 'Valuation'
    qualify row_number() over (
        partition by fund_name, company_id, transaction_date
        order by transaction_index desc
    ) = 1

),

commitments as (

    -- Deduplicate on transaction_index before summing, so a restated commitment
    -- replaces rather than adds to its predecessor.
    select
        fund_name,
        transaction_date as commitment_date,
        transaction_amount as commitment_amount
    from {{ ref('fct_fund_transaction') }}
    where transaction_type = 'Commitment'
    qualify row_number() over (
        partition by fund_name, transaction_date
        order by transaction_index desc
    ) = 1

),

fund_ownership as (

    -- Cumulative commitments as at each date on which the fund valued a company.
    -- The left join yields 0 where no commitment precedes the valuation.
    select
        v.fund_name,
        v.transaction_date,
        coalesce(sum(c.commitment_amount), 0) as cumulative_commitment_amount
    from (select distinct fund_name, transaction_date from company_valuations) v
    left join commitments c
        on c.fund_name = v.fund_name
       and c.commitment_date <= v.transaction_date
    group by v.fund_name, v.transaction_date

)

select
    {{ dbt_utils.generate_surrogate_key(['v.fund_name', 'v.company_id', 'v.transaction_date']) }} as company_nav_key,
    {{ dbt_utils.generate_surrogate_key(['v.fund_name']) }} as fund_key,
    {{ dbt_utils.generate_surrogate_key(['v.company_id']) }} as company_key,
    v.fund_name,
    v.company_id,
    v.company_name,
    v.transaction_date_key as report_date_key,
    v.transaction_date     as report_date,
    f.fund_size,
    o.cumulative_commitment_amount,
    o.cumulative_commitment_amount / nullif(f.fund_size, 0) as ownership_pct,
    -- Gross, at 100% of the holding fund. Not additive across funds.
    v.company_valuation,
    -- CVC's share. Additive across funds and companies within a date.
    v.company_valuation * o.cumulative_commitment_amount / nullif(f.fund_size, 0) as cvc_company_nav,
    -- True where the valuation predates every commitment, so ownership is 0%.
    -- See assumptions 6 to 8: these are not genuine zero valuations.
    o.cumulative_commitment_amount = 0 as is_pre_commitment_valuation
from company_valuations v
inner join fund_ownership o
    on v.fund_name = o.fund_name
   and v.transaction_date = o.transaction_date
inner join {{ ref('dim_fund') }} f
    on v.fund_name = f.fund_name

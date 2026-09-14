/*
    Company NAV using IMPLIED ownership (scaling method 2).

    ownership_pct   = fund NAV on the date / sum of that fund's company valuations
                      on the same date
    cvc_company_nav = ownership_pct * company_valuation

    Worked example from the specification: Palisade Ridge Capital at 2020-12-31 has
    company valuations totalling 850,000,000 and a fund NAV of 8,500,000, giving
    8,500,000 / 850,000,000 = 1% ownership.

    Contrast with fct_company_nav (method 1), which derives ownership independently
    as cumulative commitments / fund_size.

    ASSUMPTIONS - fct_company_nav_implied

    What this ratio actually measures
    1.  Despite the name, ownership_pct here is NOT an ownership percentage. It is a
        plug that forces the company NAVs to sum to the fund NAV. Anything that
        makes fund NAV differ from CVC's share of the gross portfolio - fund-level
        cash, accrued management fees, carried interest accrual, valuation timing
        lags, a stale fund_size - is absorbed into this single number and then
        spread evenly across every company.
    2.  Because it is a backsolve, sum(cvc_company_nav) per fund and date ALWAYS
        equals the fund NAV, by construction. This method can therefore never
        surface a reconciliation break. Method 1 derives ownership independently, so
        its variance against fund NAV is diagnostic. Use method 2 for internally
        consistent reporting, method 1 to detect problems.
    3.  The plug is spread PRO RATA across companies. This assumes any difference is
        proportional to holding size, which is right for a fund-level fee or cash
        balance but wrong if the cause is company-specific (an excused investment,
        or one company's mark being stale).

    Scope
    4.  Only dates having BOTH a fund NAV and a set of company valuations are
        included, per the specification. This is enforced by the inner join to
        fct_fund_nav, and it silently drops:
          - Ironbrook 2020-06-30 (company valuations, no fund NAV)
          - Ironbrook 2021-06-30 (fund NAV, no company valuations)
          - Palisade 2021-07-15 and 2021-08-11, Summitvale 2021-07-01
            (fund NAV on cashflow dates, no company valuations)
        So this model has 59 rows against method 1's 61, and covers 12 fund-dates
        against fct_fund_nav's 16.
    5.  Fund NAV is taken from fct_fund_nav, so it inherits every assumption there:
        latest restatement only, commitments excluded, a later valuation supersedes
        earlier cashflows. On the dates surviving assumption 4 the roll-forward
        contributes nothing, because company valuations only ever coincide with
        fund valuation dates, so nav equals the reported valuation.
    6.  The denominator sums ALL companies reported by the fund on that date,
        including the 'Other Assets' plug. Excluding it would inflate ownership and
        break the reconciliation.

    Data
    7.  Company valuations are deduplicated on transaction_index before summing, so
        a restated valuation replaces rather than adds to its predecessor.
    8.  Denominator guarded with nullif against a zero or absent company total.
    9.  Assumes the company list is COMPLETE for each fund-date. A missing company
        shrinks the denominator and inflates ownership for every other company on
        that date, with no error raised.
    10. No FX conversion; all amounts assumed to be in one currency.
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

fund_valuation_totals as (

    -- Denominator: the fund's whole reported portfolio on that date.
    select
        fund_name,
        transaction_date,
        sum(company_valuation) as total_company_valuation
    from company_valuations
    group by fund_name, transaction_date

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
    n.nav                  as fund_nav,
    t.total_company_valuation,
    -- A plug, not an ownership stake. See assumptions 1 to 3.
    n.nav / nullif(t.total_company_valuation, 0) as ownership_pct,
    v.company_valuation,
    v.company_valuation * n.nav / nullif(t.total_company_valuation, 0) as cvc_company_nav
from company_valuations v
inner join fund_valuation_totals t
    on v.fund_name = t.fund_name
   and v.transaction_date = t.transaction_date
-- Inner join enforces "only dates with both a fund NAV and company valuations".
inner join {{ ref('fct_fund_nav') }} n
    on v.fund_name = n.fund_name
   and v.transaction_date = n.report_date

/*
    ASSUMPTIONS - dim_fund

    Grain and identity
    1.  One row per fund. fund_name is the natural key; there is no numeric fund
        identifier in the source.

    Static attributes
    2.  fund_size, fund_strategy, country and region are STATIC over the fund's
        life. They are repeated on every transaction row and collapsed here with
        select distinct rather than max(), so if an attribute ever varies within a
        fund the row count doubles and the unique test on fund_key fails loudly
        instead of one value being silently chosen.
    3.  No slowly-changing-dimension handling. An attribute change overwrites
        history; there is no valid_from/valid_to. The source carries no as-of date,
        so SCD2 is not currently possible.

    Commitment
    4.  commitment_amount sums all rows of type 'Commitment'. Each fund has exactly
        one today, so this is equivalent to picking it; if a fund were ever to have
        multiple commitments, summing them is assumed to be correct.
    5.  Commitment is assumed to be CVC's commitment to the fund, not the GP's
        target or total LP commitments.

    ownership_pct - a LATEST-STATE summary, not the point-in-time figure
    6.  ownership_pct = total commitments / fund_size. The formula is CONFIRMED by
        the reporting specification (ownership = cumulative Commitment transactions
        / fund_size). It was originally inferred here, and the inference held: the
        ratio reconciles gross company valuations to reported fund NAV exactly for
        10 of 12 fund-date pairs across three unrelated values (1%, 5%, 100%). The
        exceptions are Summitvale at 2020-12-31 and 2021-03-31.
    7.  This column sums ALL commitments, so it is CVC's current ownership as at the
        latest extract. It is NOT valid for historic dates. Point-in-time ownership
        (cumulative commitments as at a given valuation date) is computed in
        fct_company_nav, and the two differ wherever a valuation predates a
        commitment - Ironbrook at 2020-06-30 is 100% here but 0% there. Use
        fct_company_nav for any dated calculation.
    8.  fund_size is the LATEST fund size, not the size at transaction time, per the
        specification. Ownership is therefore anachronistic for historic dates: if a
        fund grew after a valuation, ownership then is understated.
    9.  Ironbrook's implied stake is 100% (commitment equals fund size), which is
        implausible for a secondaries LP position and may itself be a data error.
    10. fund_size is assumed non-zero; guarded with nullif to avoid divide-by-zero
        rather than because a zero is expected.

    Dates
    10. first/latest_transaction_date span ALL transaction types, so they mark any
        activity, not specifically valuation coverage.
*/

with fund_attributes as (

    -- Fund attributes are repeated on every transaction row, so collapse to one
    -- row per fund. Using distinct (rather than max) means conflicting
    -- attributes surface as a failure of the unique test on fund_key.
    select distinct
        fund_name,
        fund_size,
        fund_strategy,
        country,
        region
    from {{ ref('stg_fund_data') }}

),

fund_activity as (

    select
        fund_name,
        min(transaction_date) as first_transaction_date,
        max(transaction_date) as latest_transaction_date,
        sum(case when transaction_type = 'Commitment' then transaction_amount end) as commitment_amount
    from {{ ref('stg_fund_data') }}
    group by fund_name

)

select
    {{ dbt_utils.generate_surrogate_key(['a.fund_name']) }} as fund_key,
    a.fund_name,
    a.fund_size,
    a.fund_strategy,
    a.country,
    a.region,
    -- Commitment is the investor's commitment to the fund, distinct from the
    -- total fund_size raised by the GP.
    y.commitment_amount,
    -- Latest-state ownership only. For any dated calculation use the point-in-time
    -- ownership_pct in fct_company_nav. See assumptions 6 and 7 above.
    y.commitment_amount / nullif(a.fund_size, 0) as ownership_pct,
    y.first_transaction_date,
    y.latest_transaction_date
from fund_attributes a
inner join fund_activity y
    on a.fund_name = y.fund_name

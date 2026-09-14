/*
    NAV roll-forward: the most recent valuation, plus every call and distribution
    booked since that valuation.

    ASSUMPTIONS - fct_fund_nav

    Definition
    1.  NAV = latest valuation + net calls and distributions since that valuation.
        Taken verbatim from the user's specification.
    2.  Calls INCREASE NAV and distributions DECREASE it, so this is a capital
        account style roll-forward rather than a pure market value. Confirmed by
        the expected output: Palisade's 1,000,000 call raises NAV from 9,800,000 to
        10,800,000.
    3.  Distributions are already negative in the source and are therefore ADDED.

    Which rows exist
    4.  One row per fund per date having Valuation, Call or Distribution activity.
        There is no continuous or daily series: NAV is not carried forward to dates
        with no activity. This matches the expected output exactly (16 rows).
    5.  Commitment-only dates produce NO row. Every fund's commitment happens to
        share a date with its opening valuation, so this is currently unobservable.
    6.  Cashflows preceding a fund's first valuation (valuation_period = 0) are
        DROPPED, because no valuation exists to anchor them to. None occur today.

    Restatements
    7.  Only the latest transaction_index per fund/type/date is used. Without this
        3 of 13 fund-quarters report a superseded figure, silently.
    8.  transaction_index is selected on explicitly here rather than reusing
        fct_fund_transaction.is_latest_restatement, so the NAV rule is auditable
        in one file.
        TRADE-OFF: the restatement rule is consequently expressed in two places
        and both must change together.
    9.  At most one valuation per fund per date is assumed after restatement
        resolution, which the max() in daily_activity relies on.

    Superseding
    10. A later valuation SUPERSEDES all earlier cashflows: the GP's new valuation
        is assumed to already reflect them. Summitvale's 2021-07-01 distribution
        must not carry into the 2021-09-30 valuation.
    11. A cashflow dated the SAME DAY as a valuation is treated as INCLUDED in the
        roll-forward, i.e. not yet reflected in that valuation. No such case exists
        in the data, so this is an unverified convention and the opposite choice is
        equally defensible. It becomes material the first time a call lands on a
        quarter end.

    Scope
    12. Commitments are excluded: they are a capital undertaking, not a cashflow.
    13. No FX conversion; all amounts assumed to be one currency.
    14. Fund-level only. Company-level NAV would need the ownership_pct scaling in
        fct_company_valuations.
*/

with current_transactions as (

    select
        fund_name,
        transaction_date,
        transaction_type,
        transaction_amount
    from {{ ref('fct_fund_transaction') }}
    -- Commitments are a capital undertaking, not a cashflow. Including
    -- Palisade's 9,700,000 would report 18,200,000 at 2020-12-31.
    where transaction_type in ('Valuation', 'Call', 'Distribution')
    qualify row_number() over (
        partition by fund_name, transaction_type, transaction_date
        order by transaction_index desc
    ) = 1

),

daily_activity as (

    select
        fund_name,
        transaction_date,
        max(case when transaction_type = 'Valuation' then transaction_amount end)     as valuation_amount,
        sum(case when transaction_type <> 'Valuation' then transaction_amount else 0 end) as cashflow_amount
    from current_transactions
    group by fund_name, transaction_date

),

valuation_periods as (

    -- Each valuation opens a new period, and cashflow-only dates inherit the
    -- period of the valuation before them. This one counter is what stops a
    -- cashflow surviving past the next valuation, which already reflects it.
    select
        fund_name,
        transaction_date,
        valuation_amount,
        cashflow_amount,
        count(valuation_amount) over (
            partition by fund_name
            order by transaction_date
            rows between unbounded preceding and current row
        ) as valuation_period
    from daily_activity

),

rolled_forward as (

    select
        fund_name,
        transaction_date as report_date,
        -- Exactly one valuation per period, and it is always the period's first
        -- date, so these need no frame or ordering.
        min(transaction_date) over (partition by fund_name, valuation_period) as valuation_date,
        max(valuation_amount) over (partition by fund_name, valuation_period) as valuation_amount,
        sum(cashflow_amount) over (
            partition by fund_name, valuation_period
            order by transaction_date
            rows between unbounded preceding and current row
        ) as cashflows_since_valuation
    from valuation_periods
    -- Period 0 is any cashflow preceding a fund's first valuation, where no NAV
    -- can be derived. None occur today.
    where valuation_period > 0

)

select
    {{ dbt_utils.generate_surrogate_key(['fund_name', 'report_date']) }} as fund_nav_key,
    {{ dbt_utils.generate_surrogate_key(['fund_name']) }} as fund_key,
    fund_name,
    to_number(to_char(report_date, 'YYYYMMDD')) as report_date_key,
    report_date,
    valuation_date,
    valuation_amount,
    cashflows_since_valuation,
    valuation_amount + cashflows_since_valuation as nav
from rolled_forward

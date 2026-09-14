/*
    Task 2.1 - Fund NAV over time.

    NAV = the most recent valuation of the fund, plus all calls and distributions
    booked since that valuation.

    Self-contained against the fund_data extract, so it can be lifted straight
    into a Snowflake worksheet.

    Three rules the naive version gets wrong, each silently:

    1. transaction_index is a RESTATEMENT version, not a sequence. The highest
       index for a fund / type / date supersedes. Ignoring it returns 8,000,000
       rather than 8,500,000 for Palisade at 2020-12-31.
    2. A LATER VALUATION SUPERSEDES EARLIER CASHFLOWS. Summitvale's 2021-07-01
       distribution reduces NAV that day but must not carry into the 2021-09-30
       valuation, which already reflects it.
    3. COMMITMENTS ARE NOT CASHFLOWS. Including Palisade's 9,700,000 commitment
       would report 18,200,000 at 2020-12-31 instead of 8,500,000.

    ASSUMPTIONS

    Definition
    a. Calls INCREASE NAV and distributions DECREASE it, so this is a capital
       account roll-forward, not a pure market value. Distributions are already
       negative in the source and are therefore added, not subtracted.
    b. NAV is reported ONLY on dates with valuation or cashflow activity. There is
       no daily or month-end series, and NAV is not carried forward to quiet dates.
       This matches the 16-row expected output.

    Edge cases, none of which occur in this extract
    c. A cashflow dated the SAME DAY as a valuation is treated as NOT yet reflected
       in that valuation, so it is added. The opposite convention is equally
       defensible; this becomes material the first time a call lands on a quarter
       end.
    d. Cashflows PRECEDING a fund's first valuation are dropped, as no valuation
       exists to anchor them to.
    e. Commitment-only dates produce no NAV row. Every fund's commitment currently
       shares a date with its opening valuation, so this is unobservable today.
    f. At most one valuation per fund per date is assumed after restatement
       resolution, which the max() in daily_activity relies on.
    g. transaction_index is compared numerically, so 1.000021 outranks 1.0. Ties
       would be broken arbitrarily, as the source has no further tiebreaker.

    Data
    h. All amounts are assumed to be in a single currency; the extract has no
       currency column despite funds domiciled in Sweden, France and the US.
    i. transaction_date is the effective date. There is no as-of date, so this
       query reports the CURRENT view only and cannot reproduce a prior reporting
       position.
    j. Snowflake syntax (qualify, ignore nulls, ::date) is assumed available.
*/

with current_transactions as (

    -- Rule 1: keep only the latest restatement of each fund / type / date.
    -- Rule 3: commitments are filtered out here.
    select
        fund_name,
        transaction_date::date as transaction_date,
        transaction_type,
        transaction_amount
    from {{ source('pe_secondary_data', 'fund_data') }}
    where transaction_type in ('Valuation', 'Call', 'Distribution')
    qualify row_number() over (
        partition by fund_name, transaction_type, transaction_date
        order by transaction_index desc
    ) = 1

),

daily_activity as (

    -- One row per fund per date; a date can carry both a valuation and cashflows.
    select
        fund_name,
        transaction_date,
        max(case when transaction_type = 'Valuation' then transaction_amount end)     as valuation_amount,
        sum(case when transaction_type <> 'Valuation' then transaction_amount else 0 end) as cashflow_amount
    from current_transactions
    group by fund_name, transaction_date

),

valuation_periods as (

    -- Rule 2: each valuation opens a new period, and cashflow-only dates inherit
    -- the period of the valuation before them. Running the cashflow total within
    -- the period is what resets it at every new valuation.
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
        transaction_date,
        max(valuation_amount) over (partition by fund_name, valuation_period) as valuation_amount,
        sum(cashflow_amount) over (
            partition by fund_name, valuation_period
            order by transaction_date
            rows between unbounded preceding and current row
        ) as cashflows_since_valuation
    from valuation_periods
    -- Period 0 is any cashflow preceding a fund's first valuation, where no NAV
    -- can be derived. None occur in this extract.
    where valuation_period > 0

)

select
    fund_name                                    as "Fund Name",
    transaction_date                             as "Date",
    valuation_amount + cashflows_since_valuation as "NAV"
from rolled_forward
order by fund_name, transaction_date

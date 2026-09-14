/*
    Task 2.3 - Company NAV over time using IMPLIED ownership (scaling method 2).

    ownership_pct   = fund NAV on the date
                      / sum of that fund's company valuations on the same date
    cvc_company_nav = ownership_pct * company_valuation

    Worked example from the specification: Palisade Ridge Capital at 2020-12-31 has
    company valuations totalling 850,000,000 against a fund NAV of 8,500,000, so
    ownership is 8,500,000 / 850,000,000 = 1%.

    Self-contained against the raw extracts. The productionised equivalent is
    models/marts/fct_company_nav_implied.sql; method 1 is exercise_2_2 /
    fct_company_nav.

    ASSUMPTIONS

    What the ratio measures
    a. This is a BACKSOLVE, not an ownership measurement. sum(cvc_company_nav) per
       fund and date always equals the fund NAV by construction, so the method can
       never reveal a reconciliation break. Anything that makes fund NAV differ from
       CVC's share of the gross portfolio - fund-level cash, accrued fees, carried
       interest, valuation timing lags, a stale fund_size - is absorbed into this
       one number.
    b. The difference is spread PRO RATA across companies, which assumes the cause
       is proportional to holding size. Correct for a fund-level fee or cash
       balance; wrong if the cause is company-specific.

    Scope
    c. Only dates having BOTH a fund NAV and company valuations are included, per
       the specification, via the inner join on fund_name and date. This drops
       Ironbrook 2020-06-30 (companies, no fund NAV), Ironbrook 2021-06-30 (fund
       NAV, no companies), and the three fund cashflow dates (Palisade 2021-07-15
       and 2021-08-11, Summitvale 2021-07-01). Result: 59 rows over 12 fund-dates.
    d. Fund NAV uses the same roll-forward as task 2.1 so that "fund NAV" means one
       thing throughout. On the qualifying dates it always equals the reported
       valuation, because company valuations only ever fall on fund valuation dates,
       so the roll-forward contributes nothing here. It is retained for correctness
       should a cashflow ever coincide with a company valuation date.
    e. The denominator includes the 'Other Assets' plug. Excluding it would inflate
       ownership and break the reconciliation.
    f. Assumes the company list is COMPLETE per fund-date. A missing company shrinks
       the denominator and inflates every other company's NAV, with no error raised.

    Data
    g. transaction_index is a restatement version; the highest per fund/type/date
       supersedes. Applied to both extracts before any aggregation, so a restated
       value replaces rather than adds to its predecessor.
    h. Commitments are excluded from the fund NAV roll-forward; distributions are
       already negative and are added.
    i. All amounts assumed to be in a single currency.
*/

with fund_transactions as (

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

fund_daily_activity as (

    select
        fund_name,
        transaction_date,
        max(case when transaction_type = 'Valuation' then transaction_amount end)     as valuation_amount,
        sum(case when transaction_type <> 'Valuation' then transaction_amount else 0 end) as cashflow_amount
    from fund_transactions
    group by fund_name, transaction_date

),

fund_valuation_periods as (

    -- Each valuation opens a new period; cashflow-only dates inherit the period of
    -- the valuation before them, so cashflows never survive past the next valuation.
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
    from fund_daily_activity

),

fund_nav as (

    select
        fund_name,
        transaction_date as report_date,
        max(valuation_amount) over (partition by fund_name, valuation_period)
            + sum(cashflow_amount) over (
                  partition by fund_name, valuation_period
                  order by transaction_date
                  rows between unbounded preceding and current row
              ) as nav
    from fund_valuation_periods
    where valuation_period > 0

),

company_valuations as (

    select
        fund_name,
        company_id,
        company_name,
        transaction_date::date as transaction_date,
        transaction_amount     as company_valuation
    from {{ source('pe_secondary_data', 'company_data') }}
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
    v.fund_name                                     as "Fund Name",
    v.company_name                                  as "Company Name",
    v.transaction_date                              as "Date",
    n.nav                                           as "Fund NAV",
    t.total_company_valuation                       as "Sum Company Valuations",
    n.nav / nullif(t.total_company_valuation, 0)    as "Ownership",
    v.company_valuation                             as "Company Valuation",
    v.company_valuation * n.nav
        / nullif(t.total_company_valuation, 0)      as "Company NAV"
from company_valuations v
inner join fund_valuation_totals t
    on v.fund_name = t.fund_name
   and v.transaction_date = t.transaction_date
-- Inner join restricts to dates having BOTH a fund NAV and company valuations.
inner join fund_nav n
    on v.fund_name = n.fund_name
   and v.transaction_date = n.report_date
order by v.fund_name, v.transaction_date, v.company_name

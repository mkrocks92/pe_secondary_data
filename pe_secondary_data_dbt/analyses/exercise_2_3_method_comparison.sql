/*
    Task 2.3 - Comparison of the two ownership scaling methods.

    Method 1 (fct_company_nav)         ownership = cumulative commitments / fund_size
    Method 2 (fct_company_nav_implied) ownership = fund NAV / sum company valuations

    Full outer join on the shared grain (fund, company, date) so rows present in
    only one method are surfaced rather than silently dropped.

    OBSERVED RESULT
    - 8 of 59 shared rows differ, all Summitvale Equity Group, all at 2020-12-31
      and 2021-03-31.
    - 2 rows exist in method 1 only: Ironbrook at 2020-06-30, which has company
      valuations but no fund NAV, so method 2 cannot produce a ratio.
    - Palisade (1%) and Ironbrook (100%) agree to the cent on every shared date.
    - Per fund-date, the total difference equals exactly the method 1 reconciliation
      variance against fund NAV: +400,000 at 2020-12-31 and -200,000 at 2021-03-31.
      Method 2 redistributes that residual across companies pro rata to holding size.
*/

with method_1 as (

    select
        company_nav_key,
        fund_name,
        company_name,
        report_date,
        ownership_pct,
        company_valuation,
        cvc_company_nav
    from {{ ref('fct_company_nav') }}

),

method_2 as (

    select
        company_nav_key,
        fund_name,
        company_name,
        report_date,
        ownership_pct,
        company_valuation,
        cvc_company_nav
    from {{ ref('fct_company_nav_implied') }}

)

select
    coalesce(m1.fund_name, m2.fund_name)        as fund_name,
    coalesce(m1.company_name, m2.company_name)  as company_name,
    coalesce(m1.report_date, m2.report_date)    as report_date,
    coalesce(m1.company_valuation, m2.company_valuation) as company_valuation,
    round(m1.ownership_pct * 100, 4)            as method_1_ownership_pct,
    round(m2.ownership_pct * 100, 4)            as method_2_ownership_pct,
    m1.cvc_company_nav                          as method_1_nav,
    m2.cvc_company_nav                          as method_2_nav,
    round(m2.cvc_company_nav - m1.cvc_company_nav, 2) as difference,
    case
        when m2.company_nav_key is null then 'method 1 only - no fund NAV on this date'
        when m1.company_nav_key is null then 'method 2 only'
        when abs(m2.cvc_company_nav - m1.cvc_company_nav) <= 0.005 then 'agrees'
        else 'differs'
    end                                         as comparison
from method_1 m1
full outer join method_2 m2
    on m1.company_nav_key = m2.company_nav_key
order by
    case
        when m1.company_nav_key is null or m2.company_nav_key is null then 0
        when abs(m2.cvc_company_nav - m1.cvc_company_nav) > 0.005 then 1
        else 2
    end,
    fund_name,
    report_date,
    company_name

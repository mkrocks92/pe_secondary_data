/*
    ASSUMPTIONS - dim_date

    Calendar
    1.  The fiscal year equals the CALENDAR year. Quarters end Mar/Jun/Sep/Dec and
        the year starts in January. No fiscal offset is applied; if CVC reports on
        a non-calendar fiscal year, fiscal_year and fiscal_quarter columns are
        needed.
    2.  is_weekend covers Saturday and Sunday only. There is no holiday or
        business-day calendar, so this is wrong for jurisdictions with different
        weekends and says nothing about settlement days.
    3.  dayname() is used rather than dayofweek() deliberately: dayofweek's
        numbering shifts with the WEEK_START session parameter, so it would produce
        different results depending on warehouse configuration.

    Spine bounds
    4.  Bounds are DERIVED from the min and max transaction date across both
        staging models, then padded to whole calendar years. The spine therefore
        contains no future-dated rows, so it cannot support forecasts or
        projections without changing this rule.
    5.  The 20,000-row generator caps the spine at roughly 54 years. Beyond that
        range dates would be silently missing.
    6.  Because the bounds depend on the facts, dim_date must be rebuilt whenever
        the fact date range widens. Running `dbt run --select fct_fund_transaction`
        alone will leave dim_date stale and fail the foreign key test; use
        `dbt build` or `--select +fct_fund_transaction`.

    Key
    7.  date_key is YYYYMMDD as an integer and MUST stay identical to the
        transaction_date_key expression in both staging models. It is generated
        with the same to_number(to_char(...)) call for that reason.
    8.  Every fact date is assumed to fall inside the spine, which holds by
        construction and is enforced by the relationships tests on both facts.
*/

with transaction_dates as (

    select transaction_date from {{ ref('stg_fund_data') }}
    union all
    select transaction_date from {{ ref('stg_company_data') }}

),

bounds as (

    -- Pad out to whole calendar years so quarter- and year-to-date logic has
    -- complete periods at both ends of the spine.
    select
        date_trunc('year', min(transaction_date)) as start_date,
        last_day(max(transaction_date), 'year')   as end_date
    from transaction_dates

),

spine as (

    -- Generator gives ~54 years of day offsets; the where clause trims the
    -- spine back to the derived bounds, so this resizes as new data arrives.
    select dateadd(day, g.day_offset, b.start_date) as calendar_date
    from bounds b
    cross join (
        select seq4() as day_offset from table(generator(rowcount => 20000))
    ) g
    where dateadd(day, g.day_offset, b.start_date) <= b.end_date

)

select
    -- Matches transaction_date_key on the fact tables.
    to_number(to_char(calendar_date, 'YYYYMMDD'))         as date_key,
    calendar_date,
    year(calendar_date)                                   as calendar_year,
    quarter(calendar_date)                                as calendar_quarter,
    month(calendar_date)                                  as calendar_month,
    day(calendar_date)                                    as day_of_month,
    monthname(calendar_date)                              as month_name,
    dayname(calendar_date)                                as day_name,
    to_char(calendar_date, 'YYYY-MM')                     as calendar_month_label,
    year(calendar_date) || '-Q' || quarter(calendar_date)  as calendar_quarter_label,
    date_trunc('month', calendar_date)                    as month_start_date,
    last_day(calendar_date, 'month')                      as month_end_date,
    date_trunc('quarter', calendar_date)                  as quarter_start_date,
    last_day(calendar_date, 'quarter')                    as quarter_end_date,
    date_trunc('year', calendar_date)                     as year_start_date,
    last_day(calendar_date, 'year')                       as year_end_date,
    calendar_date = last_day(calendar_date, 'month')      as is_month_end,
    -- Valuations are reported at quarter end, so this is the main filter for
    -- NAV and period-over-period analysis.
    calendar_date = last_day(calendar_date, 'quarter')    as is_quarter_end,
    calendar_date = last_day(calendar_date, 'year')       as is_year_end,
    -- dayname is independent of the WEEK_START session parameter, unlike dayofweek.
    dayname(calendar_date) in ('Sat', 'Sun')              as is_weekend
from spine

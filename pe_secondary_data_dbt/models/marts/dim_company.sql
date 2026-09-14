/*
    ASSUMPTIONS - dim_company

    Grain and identity
    1.  One row per company_id, conformed across funds. company_id is assumed
        GLOBAL rather than scoped to a fund: company 916 appears under two funds
        with identical attributes. Keying on (fund_name, company_id) instead would
        duplicate it and prevent "total exposure to company X" being answered with
        a single join.
    2.  Company attributes are assumed CONSISTENT for a given company_id across all
        holding funds. Verified for 916 today, and enforced going forward by the
        unique test on company_key: an inconsistency produces a duplicate row and
        fails the build rather than silently picking one version.

    Other Assets
    3.  'Other Assets' is a balancing plug, not a real portfolio company. It is
        identified by company_name rather than by company_id = 1, on the assumption
        that the label is the more stable of the two. Both are magic values.
    4.  Its null sector, country and region are assumed to be genuinely
        inapplicable rather than missing data.

    Derived attributes
    5.  holding_fund_count counts every fund that has EVER reported the company,
        not those currently holding it. The extract contains no acquisition or
        disposal events, so a realised position cannot be distinguished from a
        current one.
    6.  first/latest_transaction_date likewise mark reporting coverage, not
        entry and exit dates.

    Not modelled
    7.  No slowly-changing-dimension handling: a sector or country reclassification
        overwrites history.
    8.  No measures live here. Company valuations are fund-specific (see
        fct_company_valuations), so they cannot be attributes of the company.
*/

with company_attributes as (

    -- One row per company. company_id is conformed across funds: e.g. Zephiron
    -- Biopharma (916) is held by both Palisade Ridge and Summitvale, so the
    -- fund relationship belongs in fct_company_valuations, not here.
    select distinct
        company_id,
        company_name,
        sector,
        country,
        region
    from {{ ref('stg_company_data') }}

),

company_activity as (

    select
        company_id,
        count(distinct fund_name) as holding_fund_count,
        min(transaction_date)     as first_transaction_date,
        max(transaction_date)     as latest_transaction_date
    from {{ ref('stg_company_data') }}
    group by company_id

)

select
    {{ dbt_utils.generate_surrogate_key(['a.company_id']) }} as company_key,
    a.company_id,
    a.company_name,
    a.sector,
    a.country,
    a.region,
    -- "Other Assets" is a balancing plug carried by every fund (no sector,
    -- country or region), not a real portfolio company. Flag it so downstream
    -- company-level analysis can exclude it.
    case when a.company_name = 'Other Assets' then true else false end as is_other_assets,
    y.holding_fund_count,
    y.first_transaction_date,
    y.latest_transaction_date
from company_attributes a
inner join company_activity y
    on a.company_id = y.company_id

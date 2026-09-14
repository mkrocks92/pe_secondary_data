{{ config(materialized='table') }}

/*
    ASSUMPTIONS - stg_company_data

    Semantics
    1.  "sector" here is the INDUSTRY sector (Healthcare, Industrials, ...), not
        the fund strategy. The identically named column in fund_data holds the
        strategy, so the two must never be unioned or joined on this field.
    2.  transaction_amount is the holding fund's stake in the company stated at
        100% OF THE FUND, not CVC's share. Confirmed because the same company
        (916) is carried at 200,000,000 by one fund and 155,000,000 by another on
        the same date, and because summing these and scaling by
        commitment/fund_size reproduces the reported fund NAV exactly for 10 of 12
        fund-date pairs. Consequently these amounts are NOT additive across funds.
    3.  Only 'Valuation' rows exist in this extract. There are no company-level
        cashflows, so no cost basis and therefore no company-level MOIC or IRR.
    4.  transaction_date is the EFFECTIVE date; there is no as-of/report date.

    Identity
    5.  company_id is a GLOBAL company identifier, not scoped to a fund. Company
        916 appears under two funds with identical attributes, so the fund-company
        relationship belongs in the fact table, not the dimension.
    6.  company_id = 1 ('Other Assets') is a balancing plug carried by every fund,
        not a real portfolio company. It has no sector, country or region.

    Typing
    7.  transaction_amount is cast to number(18,0).
        LATENT BUG: zero decimal places will ROUND any fractional company
        valuation. Safe only because every source value is currently a whole
        number. stg_fund_data uses number(18,2); the two should agree.
    8.  transaction_index is cast to number(10,6) to match stg_fund_data.

    Cleaning
    9.  Both the string 'N/A' and empty/whitespace-only values are treated as
        missing for country and region.
    10. INCONSISTENCY: sector only maps 'N/A' to NULL, not empty strings. This
        works today only because Snowflake's loader maps empty CSV fields to NULL;
        a genuine empty string would survive as ''. Should be
        nullif(nullif(trim(sector), ''), 'N/A') to match country and region.
    11. INCONSISTENCY: the 'USA' comparison is case-SENSITIVE here, whereas
        stg_fund_data upper-cases first. 'usa' would not be standardised here.

    Load behaviour
    12. Full-snapshot source with no CDC, soft deletes or batch metadata.
    13. Company attributes are assumed static over time; no SCD is applied, so a
        sector reclassification would overwrite history.
    14. All amounts are assumed to be in a single currency (no currency column
        exists, despite companies in the US, France, UK and Luxembourg).
*/

with source_data as (

    select * from {{ source('pe_secondary_data', 'company_data') }}

),


staged as (
    
    select
        fund_name,
        company_id::int                 as company_id,
        company_name,
        transaction_type,
        transaction_index::number(10,6) as transaction_index,
        transaction_date::date          as transaction_date,
        to_number(to_char(transaction_date, 'YYYYMMDD')) as transaction_date_key,
        transaction_amount::number(18,0)            as transaction_amount,
        -- Industry sector (not fund strategy)
        nullif(trim(sector),'N/A')                  as sector,
        -- Standardise country
        case
            when trim(country) = 'USA' then 'United States'
            when nullif(trim(country), '') = 'N/A' then null
            when nullif(trim(country), '') is null then null
            else trim(country)
        end                                         as country,
        case
            when nullif(trim(region), '') = 'N/A' then null
            when nullif(trim(region), '') is null then null
            else trim(region)
        end                                         as region  
    from source_data
    
)


select * from staged

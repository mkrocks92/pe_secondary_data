{{ config(materialized='table') }}

/*
    ASSUMPTIONS - stg_fund_data

    Semantics
    1.  "sector" in fund_data is the fund STRATEGY (Private Equity, Venture
        Capital), not an industry sector. Renamed to fund_strategy. The identically
        named column in company_data means industry, so the two must never be
        unioned or joined on this field.
    2.  fund_size is the total fund raised by the GP. It is NOT CVC's commitment;
        the Commitment transaction rows carry that.
    3.  transaction_amount is CVC's pro-rata share (net), whereas company_data
        amounts are at 100% of the fund. See dim_fund.ownership_pct.
    4.  Distributions arrive already signed negative in the source, so no sign
        normalisation is applied. Calls and commitments are positive.
    5.  transaction_date is the EFFECTIVE date. The source carries no as-of or
        report date, so there is no way to know when a restatement arrived.

    Identity
    6.  fund_name is the only fund identifier and is assumed stable and unique.
        The source provides no numeric fund_id, so a GP rebranding would silently
        fork into two funds.

    Typing
    7.  transaction_index is cast to number(10,6): six decimal places are required
        to preserve the 1.000021 value present in the data.
    8.  transaction_amount is cast to number(18,2).
        INCONSISTENCY: stg_company_data casts to number(18,0), which would round
        away any fractional company valuation. The two should agree.

    Cleaning
    9.  'USA' and 'United States' are the same country; standardised to
        'United States'. The comparison is case-insensitive here.
        INCONSISTENCY: stg_company_data does the same comparison case-sensitively,
        so 'usa' would be standardised here but not there.
    10. Country and region are NOT null-normalised here, unlike stg_company_data.
        fund_data contains no blanks or 'N/A' values today; if any appear, empty
        strings will pass through as '' rather than NULL.

    Load behaviour
    11. The source is a full snapshot, replaced on each load. There is no CDC, no
        soft-delete marker and no batch metadata, so this model reflects only the
        current extract and cannot reproduce a prior reporting position.
    12. All amounts are assumed to be in a single currency. The source has no
        currency column, despite funds domiciled in Sweden, France and the US.
*/

with source_data as (

    select * from {{ source('pe_secondary_data', 'fund_data') }}

),

staged as (
    
    select 
        fund_name,
        fund_size::number(18,0)             as fund_size,
        transaction_type,
        transaction_index::number(10,6)     as transaction_index,
        transaction_date::date              as transaction_date,
        to_number(to_char(transaction_date, 'YYYYMMDD')) as transaction_date_key,
        transaction_amount::number(18,2)    as transaction_amount,
        -- In fund_data, "sector" is the fund strategy (PE/VC), not industry
        sector                              as fund_strategy,
        -- Standardise country: USA -> United States
        case
            when upper(trim(country)) = 'USA' then 'United States'
            else trim(country)
        end                                 as country,
        trim(region)                        as region
    from source_data
)

select * from staged

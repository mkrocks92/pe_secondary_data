/*
    ASSUMPTIONS - fct_company_valuations

    Grain
    1.  One row per fund / company / transaction_type / transaction_date /
        transaction_index. Tested with unique_combination_of_columns.
    2.  The grain is FUND x COMPANY, not company alone, because a valuation is
        specific to the holding fund's stake (see assumption 4).
    3.  Restated rows are retained; consumers must filter on is_latest_restatement.
        Restatement semantics are identical to fct_fund_transaction.

    Additivity - the easiest thing to get wrong here
    4.  gross_holding_value is stated at 100% OF THE HOLDING FUND, not CVC's share,
        and it is NOT additive across funds. Company 916 is carried at 200,000,000
        by Palisade and 155,000,000 by Summitvale on the same date, because each
        reports its own stake. Summing it across funds is meaningless.
    5.  This model deliberately holds GROSS values only. Ownership scaling lives in
        fct_company_nav, which applies point-in-time ownership (cumulative
        commitments as at the valuation date / fund_size). Keeping a second,
        statically scaled measure here would give two conflicting look-through
        numbers for the same company and date.
    6.  Values are balances, so they are additive across companies within one fund
        and date, but never across dates.

    Coverage
    7.  Only 'Valuation' rows exist; the accepted_values test will fail if company
        cashflows are ever added, which is intended.
    8.  The panel is complete within each fund (Palisade 7 companies x 5 dates,
        Summitvale 4 x 5, Ironbrook 2 x 3), so absent company-dates are assumed to
        mean the fund did not report, not that the holding was worth zero.
    9.  Ironbrook's company data is dated 2020-06-30 while the fund reports
        2021-06-30. This is preserved as-is rather than corrected, but is almost
        certainly a mistyped year: Ironbrook is 100%-owned, so the two must be
        equal, and the company total on 2020-06-30 equals the fund NAV on
        2021-06-30 exactly. Note the knock-on effect in fct_company_nav: that date
        precedes every commitment, so ownership there computes as 0%.
*/

with company_transactions as (

    select * from {{ ref('stg_company_data') }}

),

restatements_flagged as (

    select
        *,
        -- Same restatement semantics as fct_fund_transaction: highest transaction_index for
        -- a fund / company / type / date is the currently reported value.
        case
            when row_number() over (
                partition by fund_name, company_id, transaction_type, transaction_date
                order by transaction_index desc
            ) = 1 then true
            else false
        end as is_latest_restatement
    from company_transactions

)

select
    {{ dbt_utils.generate_surrogate_key(['f.fund_name', 'f.company_id', 'f.transaction_type', 'f.transaction_date', 'f.transaction_index']) }} as company_transaction_key,
    {{ dbt_utils.generate_surrogate_key(['f.fund_name']) }} as fund_key,
    {{ dbt_utils.generate_surrogate_key(['f.company_id']) }} as company_key,
    f.fund_name,
    f.company_id,
    f.company_name,
    f.transaction_date_key,
    f.transaction_date,
    f.transaction_type,
    f.transaction_index,
    f.is_latest_restatement,
    -- Stated at 100% of the holding fund, NOT CVC's share. Additive across
    -- companies within one fund and date; never additive across funds, because
    -- each fund reports its own stake in a shared company (company 916 is
    -- carried at 200m by one fund and 155m by another on the same date).
    f.transaction_amount as gross_holding_value,
    case when f.transaction_type = 'Valuation' then f.transaction_amount end as reported_value
from restatements_flagged f

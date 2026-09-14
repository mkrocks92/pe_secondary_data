/*
    Data quality test: invalid transaction_date

    Flags any transaction_date that is NULL, unparseable, or outside a
    reasonable business range. The staging models already cast to DATE, so
    this test guards against future-dated or far-past records leaking in.
*/

with all_transactions as (

    select transaction_date
    from {{ ref('stg_fund_data') }}

    union all

    select transaction_date
    from {{ ref('stg_company_data') }}

)

select *
from all_transactions
where transaction_date is null
   or transaction_date < '1990-01-01'
   or transaction_date > current_date() + 1

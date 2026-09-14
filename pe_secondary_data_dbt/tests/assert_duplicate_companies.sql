/*
    Data quality test: duplicate companies sharing the same company_id

    Company_id is treated as a global company identifier. This test fails
    if the same company_id is associated with more than one company_name,
    which would silently collapse into a single dimension row and lose
    one of the names.
*/

select
    company_id,
    count(distinct company_name) as distinct_name_count,
    array_agg(distinct company_name) as company_names
from {{ ref('stg_company_data') }}
group by 1
having count(distinct company_name) > 1

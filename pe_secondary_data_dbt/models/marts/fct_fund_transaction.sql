/*
    ASSUMPTIONS - fct_fund_transaction

    Grain
    1.  One row per fund / transaction_type / transaction_date / transaction_index.
        Tested with unique_combination_of_columns.
    2.  Restated rows are RETAINED rather than filtered out, to preserve the audit
        trail. Every consumer must therefore filter on is_latest_restatement or
        they will double count.

    Restatements
    3.  transaction_index is a restatement VERSION, not a sequence number: the
        highest index for a given fund, type and date is the currently reported
        figure. Verified against the expected NAV output, which requires index 2.0
        over 1.0, 1.000021 over 1.0, and 7.0 over 1.0.
    4.  Index values are compared NUMERICALLY, so 1.000021 correctly outranks 1.0.
    5.  Ties on transaction_index would be broken arbitrarily by row_number, as the
        source provides no further tiebreaker (no ingestion timestamp or row id).
        No ties exist today.
    6.  Non-contiguous indexes (the jump from 1.0 to 7.0) are assumed to mean
        missing restatement history rather than a different scheme.

    Measures
    7.  transaction_amount is CVC's pro-rata share, not the gross fund figure.
    8.  Distributions are already negative in the source, so distribution_amount is
        negative and is ADDED, never subtracted.
    9.  reported_nav is a BALANCE and therefore semi-additive: it may be summed
        across funds at a single date, never across dates. Not enforceable in SQL,
        so it is documented on the column instead.
    10. call_amount and commitment_amount are fully additive flows.
    11. transaction_type is assumed to be a CLOSED set of four values. The
        accepted_values test will fail the build if a fifth appears, which is
        intended: a new type would need explicit handling in fct_fund_nav.
    12. All amounts are assumed to share one currency.
*/

with fund_transactions as (

    select * from {{ ref('stg_fund_data') }}

),

restatements_flagged as (

    select
        *,
        -- transaction_index is a restatement version, not a sequence: where a
        -- fund reports more than one figure for the same type and date, the
        -- highest index is the currently reported value. Restatements are kept
        -- for auditability and filtered via is_latest_restatement.
        case
            when row_number() over (
                partition by fund_name, transaction_type, transaction_date
                order by transaction_index desc
            ) = 1 then true
            else false
        end as is_latest_restatement
    from fund_transactions

)

select
    {{ dbt_utils.generate_surrogate_key(['fund_name', 'transaction_type', 'transaction_date', 'transaction_index']) }} as fund_transaction_key,
    {{ dbt_utils.generate_surrogate_key(['fund_name']) }} as fund_key,
    fund_name,
    transaction_date_key,
    transaction_date,
    transaction_type,
    transaction_index,
    is_latest_restatement,
    transaction_amount,
    case when transaction_type = 'Commitment'   then transaction_amount end as commitment_amount,
    case when transaction_type = 'Call'         then transaction_amount end as call_amount,
    -- Distributions arrive already signed negative in the source.
    case when transaction_type = 'Distribution' then transaction_amount end as distribution_amount,
    -- Valuations are a balance, not a flow: never sum across dates.
    case when transaction_type = 'Valuation'    then transaction_amount end as reported_nav
from restatements_flagged

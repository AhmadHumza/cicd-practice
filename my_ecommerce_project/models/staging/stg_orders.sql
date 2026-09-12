select
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp as order_purchase_at,
    order_delivered_customer_date as delivered_at
from {{ ref('raw_orders') }}

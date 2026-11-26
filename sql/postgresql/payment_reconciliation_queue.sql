-- One row per order with a reconciliation exception in the purchase cohort.
WITH parameters AS (
    SELECT DATE '2018-07-01' AS purchase_start,
           DATE '2018-08-01' AS purchase_end,
           0.01::numeric AS tolerance_brl,
           0.20::numeric AS assumed_recovery_share
),
cohort AS (
    SELECT o.order_id, o.order_purchase_timestamp::date AS purchase_date, o.order_status
    FROM olist_source.orders AS o
    CROSS JOIN parameters AS p
    WHERE o.order_purchase_timestamp >= p.purchase_start
      AND o.order_purchase_timestamp < p.purchase_end
),
item_totals AS (
    SELECT i.order_id, sum(i.price + i.freight_value) AS expected_brl
    FROM cohort AS o
    JOIN olist_source.order_items AS i USING (order_id)
    GROUP BY i.order_id
),
payment_totals AS (
    SELECT pay.order_id, sum(pay.payment_value) AS recorded_brl,
           count(*) AS payment_records,
           string_agg(DISTINCT pay.payment_type, ', ' ORDER BY pay.payment_type) AS payment_types
    FROM cohort AS o
    JOIN olist_source.order_payments AS pay USING (order_id)
    GROUP BY pay.order_id
),
classified AS (
    SELECT o.*, i.expected_brl, pay.recorded_brl,
           coalesce(pay.payment_records, 0) AS payment_records, pay.payment_types,
           pay.recorded_brl - i.expected_brl AS difference_brl,
           CASE
               WHEN i.order_id IS NULL AND pay.order_id IS NULL THEN 'Missing items and payments'
               WHEN i.order_id IS NULL THEN 'Missing items'
               WHEN pay.order_id IS NULL THEN 'Missing payments'
               WHEN pay.recorded_brl - i.expected_brl < -p.tolerance_brl THEN 'Below expected'
               WHEN pay.recorded_brl - i.expected_brl > p.tolerance_brl THEN 'Above expected'
           END AS exception_type
    FROM cohort AS o
    LEFT JOIN item_totals AS i USING (order_id)
    LEFT JOIN payment_totals AS pay USING (order_id)
    CROSS JOIN parameters AS p
),
summary AS (
    SELECT count(exception_type) AS exception_orders,
           sum(recorded_brl) AS cohort_recorded_payments_brl,
           coalesce(sum(-difference_brl) FILTER (WHERE exception_type = 'Below expected'), 0)
               AS total_below_expected_brl,
           coalesce(sum(difference_brl) FILTER (WHERE exception_type = 'Above expected'), 0)
               AS total_above_expected_brl
    FROM classified
)
SELECT c.*, s.*, p.assumed_recovery_share,
       round(s.total_below_expected_brl * p.assumed_recovery_share, 2)
           AS estimated_recoverable_brl,
       round(100 * s.total_below_expected_brl * p.assumed_recovery_share
             / nullif(s.cohort_recorded_payments_brl, 0), 4) AS estimated_recoverable_pct
FROM classified AS c
CROSS JOIN summary AS s
CROSS JOIN parameters AS p
WHERE c.exception_type IS NOT NULL
ORDER BY abs(c.difference_brl) DESC NULLS LAST, c.order_id;

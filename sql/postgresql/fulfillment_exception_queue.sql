-- One row per overdue order from the selected purchase cohort.
WITH parameters AS (
    SELECT DATE '2018-07-01' AS purchase_start,
           DATE '2018-08-01' AS purchase_end,
           DATE '2018-09-01' AS cutoff,
           0.10::numeric AS assumed_prevention_rate,
           60.00::numeric AS assumed_cost_per_prevented_case_brl
),
cohort AS (
    SELECT o.*
    FROM olist_source.orders AS o
    CROSS JOIN parameters AS p
    WHERE o.order_purchase_timestamp >= p.purchase_start
      AND o.order_purchase_timestamp < LEAST(p.purchase_end, p.cutoff)
),
overdue AS (
    SELECT o.order_id, o.customer_id, o.order_estimated_delivery_date::date AS promised_date,
           p.cutoff - o.order_estimated_delivery_date::date AS days_overdue,
           CASE
               WHEN (o.order_delivered_carrier_date < p.cutoff
                     AND o.order_delivered_carrier_date < o.order_purchase_timestamp)
                 OR o.order_delivered_customer_date < o.order_purchase_timestamp
                 OR (o.order_delivered_carrier_date < p.cutoff
                     AND o.order_delivered_customer_date < o.order_delivered_carrier_date)
                   THEN 'Check timestamp records'
               WHEN o.order_delivered_carrier_date < p.cutoff THEN 'Check carrier tracking'
               ELSE 'Confirm seller dispatch'
           END AS initial_action
    FROM cohort AS o
    CROSS JOIN parameters AS p
    WHERE o.order_estimated_delivery_date::date < p.cutoff
      AND (
          o.order_delivered_customer_date IS NULL
          OR o.order_delivered_customer_date >= p.cutoff
          OR o.order_delivered_customer_date < o.order_purchase_timestamp
          OR (o.order_delivered_carrier_date < p.cutoff
              AND o.order_delivered_customer_date < o.order_delivered_carrier_date)
      )
),
seller_lists AS (
    SELECT i.order_id,
           string_agg(DISTINCT s.seller_id, ', ' ORDER BY s.seller_id) AS seller_ids
    FROM overdue AS o
    JOIN olist_source.order_items AS i USING (order_id)
    JOIN olist_source.sellers AS s USING (seller_id)
    GROUP BY i.order_id
),
queue AS (
    SELECT o.order_id, o.promised_date, o.days_overdue,
           c.customer_city, c.customer_state, s.seller_ids,
           CASE
               WHEN o.initial_action = 'Confirm seller dispatch' AND s.seller_ids IS NULL
                   THEN 'Check missing order items'
               ELSE o.initial_action
           END AS next_action
    FROM overdue AS o
    JOIN olist_source.customers AS c USING (customer_id)
    LEFT JOIN seller_lists AS s USING (order_id)
),
cohort_payments AS (
    SELECT sum(pay.payment_value) AS recorded_payments_brl
    FROM cohort AS o
    JOIN olist_source.order_payments AS pay USING (order_id)
),
queue_with_totals AS (
    SELECT q.*,
           count(*) OVER () AS queue_orders,
           count(*) FILTER (
               WHERE next_action IN ('Confirm seller dispatch', 'Check carrier tracking')
           ) OVER () AS followup_orders
    FROM queue AS q
)
SELECT q.*, p.cutoff AS cutoff_exclusive, cp.recorded_payments_brl,
       p.assumed_prevention_rate, p.assumed_cost_per_prevented_case_brl,
       round(impact.estimated_avoided_cost_brl, 2) AS estimated_avoided_cost_brl,
       round(100 * impact.estimated_avoided_cost_brl
             / nullif(cp.recorded_payments_brl, 0), 4) AS estimated_avoided_cost_pct
FROM queue_with_totals AS q
CROSS JOIN cohort_payments AS cp
CROSS JOIN parameters AS p
CROSS JOIN LATERAL (
    SELECT q.followup_orders * p.assumed_prevention_rate
           * p.assumed_cost_per_prevented_case_brl AS estimated_avoided_cost_brl
) AS impact
ORDER BY q.days_overdue DESC, q.order_id;

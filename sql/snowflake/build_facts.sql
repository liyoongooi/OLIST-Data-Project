-- Run after build_dimensions.sql. Each statement rebuilds one fact.
USE ROLE OLIST_PIPELINE;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE OLIST_PORTFOLIO;

-- FACT_ORDER: one row per order. No payment records yields a NULL total.
CREATE OR REPLACE TABLE ANALYTICS.FACT_ORDER COPY GRANTS AS
WITH payments_by_order AS (
    SELECT order_id, SUM(payment_value) AS payment_total_brl
    FROM STAGING.ORDER_PAYMENTS
    GROUP BY order_id
)
SELECT o.order_id, o.customer_id,
       TO_NUMBER(TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')) AS purchase_date_key,
       o.order_status AS snapshot_order_status,
       o.order_purchase_timestamp AS purchased_at,
       o.order_approved_at AS approved_at,
       o.order_delivered_carrier_date AS carrier_handoff_at,
       o.order_delivered_customer_date AS delivered_at,
       TO_DATE(o.order_estimated_delivery_date) AS estimated_delivery_date,
       p.payment_total_brl::NUMBER(14, 2) AS payment_total_brl
FROM STAGING.ORDERS AS o
LEFT JOIN payments_by_order AS p ON o.order_id = p.order_id;

-- FACT_ORDER_ITEM: one row per (order_id, order_item_id).
CREATE OR REPLACE TABLE ANALYTICS.FACT_ORDER_ITEM COPY GRANTS AS
SELECT i.order_id, i.order_item_id, o.customer_id,
       TO_NUMBER(TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')) AS purchase_date_key,
       i.product_id, i.seller_id,
       i.shipping_limit_date AS shipping_limit_at,
       i.price::NUMBER(14, 2) AS item_price_brl,
       i.freight_value::NUMBER(14, 2) AS freight_value_brl
FROM STAGING.ORDER_ITEMS AS i
JOIN STAGING.ORDERS AS o ON i.order_id = o.order_id;

-- FACT_REVIEW: one row per (order_id, review_id).
CREATE OR REPLACE TABLE ANALYTICS.FACT_REVIEW COPY GRANTS AS
SELECT r.order_id, r.review_id, o.customer_id,
       TO_NUMBER(TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')) AS purchase_date_key,
       r.review_score,
       r.review_creation_date AS review_created_at,
       r.review_answer_timestamp AS review_answered_at
FROM STAGING.ORDER_REVIEWS AS r
JOIN STAGING.ORDERS AS o ON r.order_id = o.order_id;

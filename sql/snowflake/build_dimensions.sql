-- Run in Snowsight with OLIST_PIPELINE. Each statement rebuilds one dimension.
USE ROLE OLIST_PIPELINE;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE OLIST_PORTFOLIO;

-- DIM_DATE: one row per day, including days with no purchases.
CREATE OR REPLACE TABLE ANALYTICS.DIM_DATE COPY GRANTS AS
WITH RECURSIVE purchase_bounds AS (
    SELECT MIN(TO_DATE(order_purchase_timestamp)) AS first_date,
           MAX(TO_DATE(order_purchase_timestamp)) AS last_date
    FROM STAGING.ORDERS
),
calendar (calendar_date, last_date) AS (
    SELECT first_date, last_date
    FROM purchase_bounds
    WHERE first_date IS NOT NULL
    UNION ALL
    SELECT DATEADD(day, 1, calendar_date), last_date
    FROM calendar
    WHERE calendar_date < last_date
)
SELECT TO_NUMBER(TO_CHAR(calendar_date, 'YYYYMMDD')) AS date_key,
       calendar_date,
       YEAR(calendar_date) AS calendar_year,
       QUARTER(calendar_date) AS calendar_quarter,
       MONTH(calendar_date) AS calendar_month,
       TO_CHAR(calendar_date, 'MMMM') AS month_name,
       DAYOFWEEKISO(calendar_date) AS day_of_week
FROM calendar;

-- DIM_CUSTOMER: one row per source customer record.
CREATE OR REPLACE TABLE ANALYTICS.DIM_CUSTOMER COPY GRANTS AS
SELECT customer_id, customer_unique_id,
       customer_zip_code_prefix AS zip_code_prefix,
       customer_city AS city,
       customer_state AS state
FROM STAGING.CUSTOMERS;

-- DIM_PRODUCT: one row per product, including untranslated categories.
CREATE OR REPLACE TABLE ANALYTICS.DIM_PRODUCT COPY GRANTS AS
SELECT p.product_id,
       p.product_category_name AS category_name_pt,
       t.product_category_name_english AS category_name_en,
       p.product_weight_g AS weight_g,
       p.product_length_cm AS length_cm,
       p.product_height_cm AS height_cm,
       p.product_width_cm AS width_cm
FROM STAGING.PRODUCTS AS p
LEFT JOIN STAGING.CATEGORY_TRANSLATIONS AS t
    ON p.product_category_name = t.product_category_name;

-- DIM_SELLER: one row per seller with its source location.
CREATE OR REPLACE TABLE ANALYTICS.DIM_SELLER COPY GRANTS AS
SELECT seller_id,
       seller_zip_code_prefix AS zip_code_prefix,
       seller_city AS city,
       seller_state AS state
FROM STAGING.SELLERS;

-- Run after build_facts.sql. A clean result shows zero differences for every check.
USE ROLE OLIST_PIPELINE;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE OLIST_PORTFOLIO;

WITH checks AS (
    SELECT 'DIM_DATE row count' AS check_name, COUNT(*) AS actual,
           (SELECT COALESCE(DATEDIFF(day, MIN(TO_DATE(order_purchase_timestamp)),
                   MAX(TO_DATE(order_purchase_timestamp))) + 1, 0) FROM STAGING.ORDERS) AS expected
    FROM ANALYTICS.DIM_DATE
    UNION ALL
    SELECT 'DIM_CUSTOMER row count', COUNT(*), (SELECT COUNT(*) FROM STAGING.CUSTOMERS)
    FROM ANALYTICS.DIM_CUSTOMER
    UNION ALL
    SELECT 'DIM_PRODUCT row count', COUNT(*), (SELECT COUNT(*) FROM STAGING.PRODUCTS)
    FROM ANALYTICS.DIM_PRODUCT
    UNION ALL
    SELECT 'DIM_SELLER row count', COUNT(*), (SELECT COUNT(*) FROM STAGING.SELLERS)
    FROM ANALYTICS.DIM_SELLER
    UNION ALL
    SELECT 'FACT_ORDER row count', COUNT(*), (SELECT COUNT(*) FROM STAGING.ORDERS)
    FROM ANALYTICS.FACT_ORDER
    UNION ALL
    SELECT 'FACT_ORDER_ITEM row count', COUNT(*), (SELECT COUNT(*) FROM STAGING.ORDER_ITEMS)
    FROM ANALYTICS.FACT_ORDER_ITEM
    UNION ALL
    SELECT 'FACT_REVIEW row count', COUNT(*), (SELECT COUNT(*) FROM STAGING.ORDER_REVIEWS)
    FROM ANALYTICS.FACT_REVIEW

    -- COUNT(DISTINCT ...) ignores null keys, so the comparison catches nulls and duplicates.
    UNION ALL
    SELECT 'DIM_DATE valid keys', COUNT(DISTINCT date_key), COUNT(*) FROM ANALYTICS.DIM_DATE
    UNION ALL
    SELECT 'DIM_CUSTOMER valid keys', COUNT(DISTINCT customer_id), COUNT(*) FROM ANALYTICS.DIM_CUSTOMER
    UNION ALL
    SELECT 'DIM_PRODUCT valid keys', COUNT(DISTINCT product_id), COUNT(*) FROM ANALYTICS.DIM_PRODUCT
    UNION ALL
    SELECT 'DIM_SELLER valid keys', COUNT(DISTINCT seller_id), COUNT(*) FROM ANALYTICS.DIM_SELLER
    UNION ALL
    SELECT 'FACT_ORDER valid keys', COUNT(DISTINCT order_id), COUNT(*) FROM ANALYTICS.FACT_ORDER
    UNION ALL
    SELECT 'FACT_ORDER_ITEM valid keys', COUNT(DISTINCT order_id, order_item_id), COUNT(*)
    FROM ANALYTICS.FACT_ORDER_ITEM
    UNION ALL
    SELECT 'FACT_REVIEW valid keys', COUNT(DISTINCT order_id, review_id), COUNT(*)
    FROM ANALYTICS.FACT_REVIEW

    UNION ALL
    SELECT 'FACT_ORDER missing dimension rows', COUNT(*), 0
    FROM ANALYTICS.FACT_ORDER AS f
    LEFT JOIN ANALYTICS.DIM_CUSTOMER AS c ON f.customer_id = c.customer_id
    LEFT JOIN ANALYTICS.DIM_DATE AS d ON f.purchase_date_key = d.date_key
    WHERE c.customer_id IS NULL OR d.date_key IS NULL
    UNION ALL
    SELECT 'FACT_ORDER_ITEM missing dimension rows', COUNT(*), 0
    FROM ANALYTICS.FACT_ORDER_ITEM AS f
    LEFT JOIN ANALYTICS.DIM_CUSTOMER AS c ON f.customer_id = c.customer_id
    LEFT JOIN ANALYTICS.DIM_DATE AS d ON f.purchase_date_key = d.date_key
    LEFT JOIN ANALYTICS.DIM_PRODUCT AS p ON f.product_id = p.product_id
    LEFT JOIN ANALYTICS.DIM_SELLER AS s ON f.seller_id = s.seller_id
    WHERE c.customer_id IS NULL OR d.date_key IS NULL OR p.product_id IS NULL OR s.seller_id IS NULL
    UNION ALL
    SELECT 'FACT_REVIEW missing dimension rows', COUNT(*), 0
    FROM ANALYTICS.FACT_REVIEW AS f
    LEFT JOIN ANALYTICS.DIM_CUSTOMER AS c ON f.customer_id = c.customer_id
    LEFT JOIN ANALYTICS.DIM_DATE AS d ON f.purchase_date_key = d.date_key
    WHERE c.customer_id IS NULL OR d.date_key IS NULL

    UNION ALL
    SELECT 'FACT_ORDER payment total BRL', SUM(payment_total_brl),
           (SELECT SUM(payment_value) FROM STAGING.ORDER_PAYMENTS)
    FROM ANALYTICS.FACT_ORDER
    UNION ALL
    SELECT 'FACT_ORDER payment mismatches by order', COUNT(*), 0
    FROM ANALYTICS.FACT_ORDER AS f
    LEFT JOIN (
        SELECT order_id, SUM(payment_value) AS expected_payment
        FROM STAGING.ORDER_PAYMENTS
        GROUP BY order_id
    ) AS p ON f.order_id = p.order_id
    WHERE f.payment_total_brl IS DISTINCT FROM p.expected_payment
    UNION ALL
    SELECT 'FACT_ORDER_ITEM item price total BRL', SUM(item_price_brl),
           (SELECT SUM(price) FROM STAGING.ORDER_ITEMS)
    FROM ANALYTICS.FACT_ORDER_ITEM
    UNION ALL
    SELECT 'FACT_ORDER_ITEM freight total BRL', SUM(freight_value_brl),
           (SELECT SUM(freight_value) FROM STAGING.ORDER_ITEMS)
    FROM ANALYTICS.FACT_ORDER_ITEM
)
SELECT check_name, actual, expected, actual - expected AS difference,
       IFF(actual IS NOT DISTINCT FROM expected, 'PASS', 'FAIL') AS status
FROM checks
ORDER BY status, check_name;

-- Source-shaped Snowflake tables. Run inside OLIST_PORTFOLIO as OLIST_PIPELINE.

CREATE TABLE IF NOT EXISTS STAGING.customers (
    customer_id VARCHAR NOT NULL,
    customer_unique_id VARCHAR NOT NULL,
    customer_zip_code_prefix VARCHAR NOT NULL,
    customer_city VARCHAR NOT NULL,
    customer_state VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.products (
    product_id VARCHAR NOT NULL,
    product_category_name VARCHAR,
    product_name_length NUMBER(10,0),
    product_description_length NUMBER(10,0),
    product_photos_qty NUMBER(10,0),
    product_weight_g NUMBER(10,0),
    product_length_cm NUMBER(10,0),
    product_height_cm NUMBER(10,0),
    product_width_cm NUMBER(10,0)
);

CREATE TABLE IF NOT EXISTS STAGING.sellers (
    seller_id VARCHAR NOT NULL,
    seller_zip_code_prefix VARCHAR NOT NULL,
    seller_city VARCHAR NOT NULL,
    seller_state VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.category_translations (
    product_category_name VARCHAR NOT NULL,
    product_category_name_english VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.geolocation (
    source_row_number NUMBER(19,0) NOT NULL,
    geolocation_zip_code_prefix VARCHAR NOT NULL,
    geolocation_lat FLOAT NOT NULL,
    geolocation_lng FLOAT NOT NULL,
    geolocation_city VARCHAR NOT NULL,
    geolocation_state VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.orders (
    order_id VARCHAR NOT NULL,
    customer_id VARCHAR NOT NULL,
    order_status VARCHAR NOT NULL,
    order_purchase_timestamp TIMESTAMP_NTZ NOT NULL,
    order_approved_at TIMESTAMP_NTZ,
    order_delivered_carrier_date TIMESTAMP_NTZ,
    order_delivered_customer_date TIMESTAMP_NTZ,
    order_estimated_delivery_date TIMESTAMP_NTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.order_items (
    order_id VARCHAR NOT NULL,
    order_item_id NUMBER(10,0) NOT NULL,
    product_id VARCHAR NOT NULL,
    seller_id VARCHAR NOT NULL,
    shipping_limit_date TIMESTAMP_NTZ NOT NULL,
    price NUMBER(12, 2) NOT NULL,
    freight_value NUMBER(12, 2) NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.order_payments (
    order_id VARCHAR NOT NULL,
    payment_sequential NUMBER(10,0) NOT NULL,
    payment_type VARCHAR NOT NULL,
    payment_installments NUMBER(10,0) NOT NULL,
    payment_value NUMBER(12, 2) NOT NULL
);

CREATE TABLE IF NOT EXISTS STAGING.order_reviews (
    order_id VARCHAR NOT NULL,
    review_id VARCHAR NOT NULL,
    review_score NUMBER(10,0) NOT NULL,
    review_comment_title VARCHAR,
    review_comment_message VARCHAR,
    review_creation_date TIMESTAMP_NTZ NOT NULL,
    review_answer_timestamp TIMESTAMP_NTZ NOT NULL
);

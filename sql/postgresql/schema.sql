-- Operational-style tables for the full Olist snapshot.
CREATE SCHEMA IF NOT EXISTS olist_source;

CREATE TABLE IF NOT EXISTS olist_source.customers (
    customer_id text PRIMARY KEY,
    customer_unique_id text NOT NULL,
    customer_zip_code_prefix text NOT NULL,
    customer_city text NOT NULL,
    customer_state text NOT NULL
);

CREATE TABLE IF NOT EXISTS olist_source.products (
    product_id text PRIMARY KEY,
    product_category_name text,
    product_name_length integer,
    product_description_length integer,
    product_photos_qty integer,
    product_weight_g integer,
    product_length_cm integer,
    product_height_cm integer,
    product_width_cm integer
);

CREATE TABLE IF NOT EXISTS olist_source.sellers (
    seller_id text PRIMARY KEY,
    seller_zip_code_prefix text NOT NULL,
    seller_city text NOT NULL,
    seller_state text NOT NULL
);

CREATE TABLE IF NOT EXISTS olist_source.category_translations (
    product_category_name text PRIMARY KEY,
    product_category_name_english text NOT NULL
);

CREATE TABLE IF NOT EXISTS olist_source.geolocation (
    source_row_number bigint PRIMARY KEY CHECK (source_row_number > 0),
    geolocation_zip_code_prefix text NOT NULL,
    geolocation_lat double precision NOT NULL CHECK (geolocation_lat BETWEEN -90 AND 90),
    geolocation_lng double precision NOT NULL CHECK (geolocation_lng BETWEEN -180 AND 180),
    geolocation_city text NOT NULL,
    geolocation_state text NOT NULL
);

CREATE TABLE IF NOT EXISTS olist_source.orders (
    order_id text PRIMARY KEY,
    customer_id text NOT NULL REFERENCES olist_source.customers (customer_id),
    order_status text NOT NULL,
    order_purchase_timestamp timestamp NOT NULL,
    order_approved_at timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp NOT NULL
);

CREATE TABLE IF NOT EXISTS olist_source.order_items (
    order_id text REFERENCES olist_source.orders (order_id),
    order_item_id integer CHECK (order_item_id > 0),
    product_id text NOT NULL REFERENCES olist_source.products (product_id),
    seller_id text NOT NULL REFERENCES olist_source.sellers (seller_id),
    shipping_limit_date timestamp NOT NULL,
    price numeric(12, 2) NOT NULL CHECK (price > 0),
    freight_value numeric(12, 2) NOT NULL CHECK (freight_value >= 0),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE IF NOT EXISTS olist_source.order_payments (
    order_id text REFERENCES olist_source.orders (order_id),
    payment_sequential integer CHECK (payment_sequential > 0),
    payment_type text NOT NULL,
    payment_installments integer NOT NULL CHECK (payment_installments >= 0),
    payment_value numeric(12, 2) NOT NULL CHECK (payment_value >= 0),
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE IF NOT EXISTS olist_source.order_reviews (
    order_id text REFERENCES olist_source.orders (order_id),
    review_id text,
    review_score integer NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title text,
    review_comment_message text,
    review_creation_date timestamp NOT NULL,
    review_answer_timestamp timestamp NOT NULL,
    PRIMARY KEY (order_id, review_id)
);

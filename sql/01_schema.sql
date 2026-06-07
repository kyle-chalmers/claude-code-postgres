-- Sample analytics schema for the Claude Code + PostgreSQL walkthrough.
-- A small orders / customers / products database with three things on purpose:
--   * visible PII in customers (name, email)  -> shows what leaves your machine
--   * a free-text notes column on orders       -> the untrusted-content angle
--   * an order_items child table               -> makes "top customers" ambiguous
--
-- Docker auto-loads this file on first start (see docker-compose.yml). To load it
-- by hand:  psql -U postgres -f sql/01_schema.sql

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path TO shop;

CREATE TABLE customers (
    customer_id   serial PRIMARY KEY,
    name          text NOT NULL,
    email         text NOT NULL,          -- PII: shown on screen to make egress concrete
    region        text NOT NULL,
    signup_date   date NOT NULL
);

CREATE TABLE products (
    product_id    serial PRIMARY KEY,
    name          text NOT NULL,
    category      text NOT NULL,
    unit_price    numeric(10,2) NOT NULL
);

CREATE TABLE orders (
    order_id      serial PRIMARY KEY,
    customer_id   integer NOT NULL REFERENCES customers(customer_id),
    order_date    date NOT NULL,
    status        text NOT NULL,          -- 'completed' | 'refunded' ('pending' also valid; none in this sample)
    notes         text                    -- free text; the untrusted-content leg
);

-- Note: a production order line usually snapshots the sale price at order time.
-- This demo keeps it simple and derives revenue from the current products.unit_price
-- (quantity * unit_price), which is fine for a teaching schema but not how you'd
-- model real orders.
CREATE TABLE order_items (
    order_id      integer NOT NULL REFERENCES orders(order_id),
    product_id    integer NOT NULL REFERENCES products(product_id),
    quantity      integer NOT NULL,
    PRIMARY KEY (order_id, product_id)
);

INSERT INTO customers (name, email, region, signup_date) VALUES
 ('Ava Romano',    'ava.romano@example.com',    'West',    '2025-01-12'),
 ('Liam Chen',     'liam.chen@example.com',     'East',    '2025-02-03'),
 ('Noah Patel',    'noah.patel@example.com',    'West',    '2025-02-20'),
 ('Mia Johnson',   'mia.johnson@example.com',   'Central', '2025-03-11'),
 ('Ethan Brooks',  'ethan.brooks@example.com',  'East',    '2025-04-01');

INSERT INTO products (name, category, unit_price) VALUES
 ('Standard Widget', 'Widgets',     12.00),
 ('Pro Widget',      'Widgets',     49.00),
 ('Gadget Mini',     'Gadgets',      8.50),
 ('Gadget Max',      'Gadgets',    120.00),
 ('Support Plan',    'Services',   200.00);

-- Orders are arranged so "top customers" disagrees by interpretation:
--   Liam Chen    = many small orders (#1 by COUNT, near-bottom by revenue)
--   Ethan Brooks = one large order   (#1 by REVENUE, low count)
-- and one refunded order (Noah) sets up the missing-WHERE-filter beat.
INSERT INTO orders (customer_id, order_date, status, notes) VALUES
 (2, '2025-05-02', 'completed', 'reorder'),
 (2, '2025-05-09', 'completed', 'reorder'),
 (2, '2025-05-16', 'completed', 'reorder'),
 (2, '2025-05-23', 'completed', 'reorder'),
 (5, '2025-05-20', 'completed', 'bulk annual purchase'),
 (1, '2025-05-05', 'completed', NULL),
 (3, '2025-05-18', 'refunded',  'returned, damaged in transit'),
 (4, '2025-05-25', 'completed', NULL);

INSERT INTO order_items (order_id, product_id, quantity) VALUES
 (1, 1, 1),            -- Liam   12.00
 (2, 1, 1),            -- Liam   12.00
 (3, 3, 1),            -- Liam    8.50
 (4, 1, 1),            -- Liam   12.00
 (5, 5, 1),(5, 4, 2),  -- Ethan  200 + 240 = 440.00 (one order, two line items)
 (6, 2, 1),            -- Ava    49.00
 (7, 4, 1),            -- Noah  120.00 (refunded)
 (8, 2, 2);            -- Mia    98.00

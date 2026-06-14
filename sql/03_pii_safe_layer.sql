-- PII-safe layer: let an AI agent analyze real data without ever reading raw PII.
-- This is the Postgres version of the three principles from the companion video
-- "So AI Can Access Your Database's PII, What to Do?"
-- (https://www.youtube.com/watch?v=NJolk9KBn7c):
--   1. Schema segregation  - the agent reaches a curated schema, never the raw tables.
--   2. Hashing with a salt  - PII it must join on is hashed (SHA-256 + per-row salt),
--                             never shown in the clear; PII it doesn't need is dropped.
--   3. Identity selection   - a dedicated AI role granted ONLY the curated schema.
--
-- Why this works in Postgres: a regular VIEW reads its underlying tables with the
-- VIEW OWNER's privileges, not the caller's. So the curated views (owned by the
-- admin running this file) can read shop.* under the hood, while the AI role gets
-- SELECT on the VIEWS ONLY and no grant on the shop schema at all. The raw tables
-- are then literally unreachable for that role.
--
-- Run as admin, AFTER 01_schema.sql and 02_create_readonly_role.sql:
--   psql -h localhost -p 55432 -U postgres -v ON_ERROR_STOP=1 -f sql/03_pii_safe_layer.sql

-- pgcrypto gives us digest() for SHA-256. (On Supabase it lives in the extensions
-- schema; locally it installs into public, so digest() resolves unqualified.)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. The curated schema: the one and only schema the AI role will ever reach.
CREATE SCHEMA IF NOT EXISTS ai_curated;

-- 1b. A PRIVATE schema for the salts. The AI role is never granted this schema, so it
--     can see the hash but not the salt. That matters: a low-entropy value (a phone
--     number, say) is brute-forceable if you know the salt, so the salt must stay
--     unreadable to the agent. The curated views below are owned by the admin running
--     this file, so they can still join the salts under the hood.
CREATE SCHEMA IF NOT EXISTS ai_private;

-- 2. Per-customer salts: one stable salt per customer (NOT a random salt per row). A
--    global hash of an email is reversible by a rainbow table; a stable per-customer salt
--    defeats that while keeping the hash consistent for that customer, so hash-joins and
--    group-bys still work. Because the salt is stable per entity, the result is a pseudonym
--    you can join on, not an anonymized value (and a low-entropy value like a phone is
--    brute-forceable if the salt ever leaks, which is why the salt schema stays private).
CREATE TABLE IF NOT EXISTS ai_private.salt_keys (
  customer_id INT PRIMARY KEY,
  salt        TEXT NOT NULL DEFAULT encode(gen_random_bytes(16), 'hex')
);
INSERT INTO ai_private.salt_keys (customer_id)
SELECT customer_id FROM shop.customers
ON CONFLICT (customer_id) DO NOTHING;

-- 3a. customers: hash the email (a join-able pseudonym, not readable), and DROP name (PII
--     the analytics here do not need). The rule for your own data: keep a column only if the
--     agent needs it; hash it if it must join on it; drop it otherwise.
CREATE OR REPLACE VIEW ai_curated.customers AS
SELECT
  c.customer_id,
  c.region,
  c.signup_date,
  encode(digest(c.email || s.salt, 'sha256'), 'hex') AS email_hash
FROM shop.customers c
JOIN ai_private.salt_keys s ON s.customer_id = c.customer_id;

-- 3b. Explicit allow-lists, never SELECT * (so a new PII column added later cannot auto-leak).
--     orders.notes is free text (the untrusted-content / prompt-injection leg), so it becomes a
--     length, never the raw text. products and order_items carry no PII.
CREATE OR REPLACE VIEW ai_curated.orders AS
  SELECT order_id, customer_id, order_date, status, length(notes) AS notes_len FROM shop.orders;
CREATE OR REPLACE VIEW ai_curated.order_items AS
  SELECT order_id, product_id, quantity FROM shop.order_items;
CREATE OR REPLACE VIEW ai_curated.products AS
  SELECT product_id, name, category, unit_price FROM shop.products;

-- 4. Identity selection: a dedicated AI role that can reach ONLY ai_curated.
--    Set your own password where marked, the same way you do for analyst_ro.
CREATE ROLE analyst_ai LOGIN PASSWORD 'CHANGE_ME_BEFORE_RUNNING';

GRANT USAGE ON SCHEMA ai_curated TO analyst_ai;
GRANT SELECT ON ALL TABLES IN SCHEMA ai_curated TO analyst_ai;   -- covers views too
ALTER DEFAULT PRIVILEGES IN SCHEMA ai_curated GRANT SELECT ON TABLES TO analyst_ai;

-- Guardrails (same spirit as analyst_ro): resolve names against the curated schema,
-- and cap a runaway read so an accidental cross join can't hammer the database.
ALTER ROLE analyst_ai SET search_path TO ai_curated;
ALTER ROLE analyst_ai SET statement_timeout = '30s';

-- Crucially, analyst_ai is granted NOTHING on the shop schema. The raw PII tables
-- are unreachable for it. Prove it (run as analyst_ai):
--   SELECT email_hash FROM ai_curated.customers LIMIT 1;  -> works, hash only
--   SELECT email      FROM shop.customers       LIMIT 1;  -> ERROR: permission denied for schema shop
--
-- Note on RLS: a view reads with the owner's row visibility. Create these views as a
-- role that can see all rows (the table owner / a BYPASSRLS role) or the curated view
-- will only expose the rows that owner's RLS lets through.

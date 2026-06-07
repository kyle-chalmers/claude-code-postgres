-- The highest-impact step: a read-only role, created as admin, BEFORE you point
-- an AI agent at the database. With SELECT-only, the agent physically cannot
-- write, drop, or delete -- the database enforces it, not the model's good behavior.
--
-- Run this yourself, as an admin/superuser. Do NOT let an AI agent generate the
-- password: set your own where marked, then run it.
--
--   psql -U postgres -f sql/02_create_readonly_role.sql      (after editing the password)

-- 1. The login. Set your own password here; keep secrets out of the model's hands.
CREATE ROLE analyst_ro LOGIN PASSWORD 'CHANGE_ME_BEFORE_RUNNING';

-- 2. Scope to the schema, not the whole cluster, and SELECT only.
GRANT USAGE ON SCHEMA shop TO analyst_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO analyst_ro;

-- 3. GRANT ON ALL TABLES only covers tables that exist right now. So that a table
--    you add later is readable too (without re-granting), set the default:
ALTER DEFAULT PRIVILEGES IN SCHEMA shop GRANT SELECT ON TABLES TO analyst_ro;

-- Prove it works (run as analyst_ro): SELECT succeeds; DROP and UPDATE are refused.
--   DROP TABLE shop.orders;            -> ERROR: must be owner of table orders
--   UPDATE shop.orders SET status='x'; -> ERROR: permission denied for table orders
--   SELECT count(*) FROM shop.orders;  -> works

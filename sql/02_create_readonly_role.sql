-- The highest-impact step: a read-only role, created as admin, BEFORE you point
-- an AI agent at the database. With SELECT-only, the agent cannot write to, drop,
-- or delete your data -- the database enforces it, not the model's good behavior.
--
-- Prerequisite: the shop schema must already exist. Run `docker compose up -d`
-- first (it loads sql/01_schema.sql), then run this file.
--
-- Run this yourself, as an admin/superuser. Do NOT let an AI agent generate the
-- password: set your own where marked, then run it.
--
--   psql -h localhost -p 55432 -U postgres -v ON_ERROR_STOP=1 -f sql/02_create_readonly_role.sql
--
-- Same file works against a managed cloud Postgres (Neon, Supabase, RDS/Aurora,
-- Cloud SQL, Azure, Render, Railway): connect as your project's OWNER role rather
-- than a local superuser (on Neon that is the <db>_owner role, which can CREATE
-- ROLE) and add ?sslmode=require to the connection. The GRANTs below are unchanged:
--
--   psql "postgresql://<owner>:<pw>@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require" \
--     -v ON_ERROR_STOP=1 -f sql/02_create_readonly_role.sql

-- 1. The login. Set your own password here; keep secrets out of the model's hands.
CREATE ROLE analyst_ro LOGIN PASSWORD 'CHANGE_ME_BEFORE_RUNNING';

-- 2. Scope to the schema, not the whole cluster, and SELECT only.
GRANT USAGE ON SCHEMA shop TO analyst_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO analyst_ro;

-- 3. GRANT ON ALL TABLES only covers tables that exist right now. So that a table
--    you add later is readable too (without re-granting), set the default. Note:
--    ALTER DEFAULT PRIVILEGES applies to objects created by the role that runs it;
--    for tables another role creates in this schema, add FOR ROLE that_role.
ALTER DEFAULT PRIVILEGES IN SCHEMA shop GRANT SELECT ON TABLES TO analyst_ro;

-- 4. Quality-of-life + guardrails for an agent-driven session:
--    - resolve unqualified names against shop (so `SELECT * FROM orders` works)
--    - cap a runaway query (an agent can write an accidental cross join)
ALTER ROLE analyst_ro SET search_path TO shop, public;
ALTER ROLE analyst_ro SET statement_timeout = '30s';

-- Note on "read-only": SELECT-only blocks writes to YOUR data. Postgres still grants
-- every role TEMPORARY (temp tables) and CONNECT by default, which don't touch your
-- tables. If you want to forbid even temp tables, also run (as admin):
--   REVOKE TEMPORARY ON DATABASE postgres FROM analyst_ro;

-- Prove it works (run as analyst_ro): SELECT succeeds; DROP and UPDATE are refused.
--   DROP TABLE shop.orders;            -> ERROR: must be owner of table orders
--   UPDATE shop.orders SET status='x'; -> ERROR: permission denied for table orders
--   SELECT count(*) FROM orders;       -> works

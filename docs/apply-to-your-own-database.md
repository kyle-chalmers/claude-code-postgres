# Apply the PII-safe layer to your own production database

[`sql/03_pii_safe_layer.sql`](../sql/03_pii_safe_layer.sql) shows the pattern on the sample `shop` schema. To do this on your own database, you adapt the same three principles to your tables, then apply it the careful way: you run the privileged setup yourself, and the agent only ever logs in as the scoped, read-only, curated role.

## 1. Build your curated layer (adapt `sql/03`)

For every table you want the agent to analyze, add a view in an `ai_curated` schema that:

- **Hashes the columns it must join on** (email, phone, user id) with a stable per-entity salt kept in a separate `ai_private` schema the agent is never granted. Same entity, same salt, so the hash still joins; the salt stays private so the hash cannot be reversed.
- **Reduces free text to a length** (`length(col) AS col_len`). Anything a user can type is both PII and the prompt-injection ("untrusted content") leg; dropping it to a length removes both.
- **Drops columns it does not need** (raw PII, secrets, tokens).
- **Lists columns explicitly, never `SELECT *`,** so a column added to the raw table later cannot auto-leak into the curated view.

Then create one scoped role that can reach only the curated schema:

```sql
CREATE ROLE ai_agent NOLOGIN;                       -- set LOGIN + password yourself, later
GRANT USAGE ON SCHEMA ai_curated TO ai_agent;
GRANT SELECT ON ALL TABLES IN SCHEMA ai_curated TO ai_agent;
ALTER ROLE ai_agent SET search_path TO ai_curated;
ALTER ROLE ai_agent SET statement_timeout = '30s';  -- read-only does not stop a runaway scan
-- ai_agent is granted NOTHING on your raw schema, so the raw tables are unreachable.
```

The curated views are owned by the admin who creates them, so they read the raw tables under the hood (Postgres views use the owner's privileges) while `ai_agent` holds `SELECT` on the views only. See `sql/03` for the worked version, including the salts table and the masked views.

## 2. Apply it safely

Paste this into a Claude Code session that has your **owner/admin** database access (not the agent's session):

```
Help me apply a PII-safe curated layer to my production Postgres, carefully.
I have drafted the SQL (a curated ai_curated schema of masked views + a private
ai_private salt schema + a scoped read-only ai_agent role). Do this in order and
STOP if anything looks off:

1. REVIEW: confirm the SQL is additive-only (CREATE SCHEMA/VIEW/ROLE/GRANT only;
   no ALTER/DROP/data writes on my existing tables). Summarize what it creates.
2. DRIFT CHECK: for every column each curated view references, confirm it exists in
   the live table (information_schema.columns). Stop on any missing/renamed column.
3. DRY-RUN, not prod: apply it to a branch, a staging copy, or a throwaway clone,
   then verify as a test login:
     - ai_agent reads ai_curated and gets hashes, not raw PII
     - ai_agent can SELECT zero raw tables:
       SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relkind='r'
         AND has_table_privilege('ai_agent', c.oid, 'SELECT');   -- must be 0
     - ai_agent cannot read ai_private (the salts)
     - a hashed join key matches across two tables for the same entity
   Show me the results.
4. APPLY TO PRODUCTION only after I approve the dry-run.
5. STOP for the password: I will set it myself, in a session you do not see
   (ALTER ROLE ai_agent LOGIN PASSWORD '...'). Do not generate or store it.
6. After I set it, put the ai_agent password in ~/.pgpass (chmod 0600; sslmode goes
   in the connection string), and re-run the step-3 checks against production.
```

## 3. What "verified" means

After it is live, the agent should:

- read real data through `ai_curated` and never a raw value,
- be unable to `SELECT` any raw table (the `has_table_privilege` count is `0`),
- be unable to read the salts,
- still join and group on the hashed keys.

`bash scripts/validate.sh` runs exactly these checks against the sandbox so you can see them pass before you adapt the pattern to your own schema.

> The full step-by-step build of this masking (schema segregation, hashing with a salt, the scoped role) is walked through on Snowflake in [So AI Can Access Your Database's PII, What to Do?](https://www.youtube.com/watch?v=NJolk9KBn7c).

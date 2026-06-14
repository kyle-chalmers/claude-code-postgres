# Claude Code + PostgreSQL: query your database in plain English, safely

Point [Claude Code](https://www.anthropic.com/claude-code) at a real PostgreSQL database, ask questions in plain English, and read the answers, without ever giving the agent the power to change a single row or read a raw personal record. The safe version puts the guardrails at the database:

1. **Create a read-only role first** so the agent cannot write to, drop, or delete your data. The database enforces it, not the model's good behavior.
2. **Put a curated, PII-safe schema in front of it** (see [Connect to PII safely](#connect-to-pii-safely-point-the-agent-at-production-responsibly)) so it analyzes real data without ever reading raw personal values: hash what it must join on, drop the rest.
3. **Read the SQL it writes before it runs.** A strong model rarely produces broken SQL; the quieter failure is correct SQL that answers the wrong question.
4. **Be honest about what leaves your machine.** When the database is in the cloud the SQL runs on the provider's server (your local `psql` only sends the query text and receives rows), and your question, the schema, and the result rows go on to a separate model API.

This repo is the companion to the video. It gives you a small sample database, the exact read-only role commands, and the prompts to try, so you can reproduce the whole thing in a few minutes.

> Channel: [Kyle Chalmers Data Plus AI](https://www.youtube.com/@kylechalmersdataai)

## How it connects (official-first)

`psql` is PostgreSQL's official, first-party command-line client. It ships with Postgres, so there is nothing third-party between Claude Code and your database, even when that database is a managed cloud one (Neon, Supabase, Amazon RDS or Aurora, Google Cloud SQL, Azure Database for PostgreSQL, Render, Railway). You point at the provider's host and require SSL; nothing else about the workflow changes. That is the path this repo uses, and the one to reach for.

You will also hear about MCP servers. Worth knowing: **there is no official, PostgreSQL-project MCP server.** Anthropic published a reference one, but reference servers are teaching examples, not production tools, and it is archived (it is also the subject of a [documented SQL-injection](https://securitylabs.datadoghq.com/articles/mcp-vulnerability-case-study-SQL-injection-in-the-postgresql-mcp-server/)). Every usable option today is community or vendor ([Postgres MCP Pro](https://github.com/crystaldba/postgres-mcp), pgEdge, Supabase, Neon). They are reasonable if you want structured tooling, just go in knowing you are trusting and maintaining a third-party server, and that whichever way you connect, **the read-only database role is the thing that actually protects you.**

![The egress boundary: psql runs locally, the SQL executes on the database, your question and result rows go to the model API](./images/egress-boundary.png)

## Prerequisites

| Tool | Why | Install |
|------|-----|---------|
| Docker | Runs the local Postgres in one command | https://docs.docker.com/get-docker/ |
| `psql` (PostgreSQL client) | The official client Claude Code shells out to | macOS: `brew install libpq`, then add it to PATH: `echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc`. (libpq is keg-only, and the versioned `postgresql@16` formula is keg-only too, so both need this PATH step. Install the full `postgresql@16` if you also want a local server.) |
| Claude Code | The agent that writes and runs the SQL | https://www.anthropic.com/claude-code |

Two ways to run the database: the **local Docker** path below needs no cloud account and is fully disposable, and the [**cloud Postgres**](#connect-to-a-cloud-postgres-the-same-thing-on-a-real-server) path needs only a free Neon or Supabase project. The raw `shop` tables here are sample data; before you point Claude Code at real production data, put it behind the curated PII-safe schema in [Connect to PII safely](#connect-to-pii-safely-point-the-agent-at-production-responsibly).

## Setup

**1. Start Postgres with the sample schema loaded:**

```bash
docker compose up -d --wait
```

This runs `postgres:16-alpine` on `localhost:55432` and auto-loads [`sql/01_schema.sql`](./sql/01_schema.sql) (a small `shop` schema: `customers`, `products`, `orders`, `order_items`). The `--wait` flag blocks until the database is actually accepting connections, so the next step can't race a cold start. (Port `55432`, not the default `5432`, so this won't clash with a Postgres you already run locally.)

**2. Create the read-only role (do this yourself, as admin):**

Open [`sql/02_create_readonly_role.sql`](./sql/02_create_readonly_role.sql), set your own password where marked, then run it:

```bash
psql -h localhost -p 55432 -U postgres -v ON_ERROR_STOP=1 -f sql/02_create_readonly_role.sql   # password: demo
```

Creating this role is the highest-impact step, and you set the password, not the agent. Keep secrets out of the model's hands.

**3. Prove it's read-only:**

```bash
PGPASSWORD='<the password you set>' psql -h localhost -p 55432 -U analyst_ro -d postgres \
  -c "DROP TABLE shop.orders;"            # -> ERROR: must be owner of table orders
```

A `DROP` is refused (`must be owner`), an `UPDATE` is refused (`permission denied`), and a `SELECT` works. The destructive part is gone.

**4. Point Claude Code at it as the read-only role.** Put the `analyst_ro` password in `~/.pgpass` (edit the file directly, or prepend the command with a space, so the password itself stays out of shell history):

```bash
echo 'localhost:55432:postgres:analyst_ro:<the password you set>' >> ~/.pgpass
chmod 0600 ~/.pgpass     # libpq ignores ~/.pgpass unless it's 0600
```

Then start Claude Code in this folder and let it connect as `analyst_ro` over Bash, e.g.:

```bash
claude "Connect to Postgres as analyst_ro: psql -h localhost -p 55432 -U analyst_ro -d postgres. From now on, write the SQL, show it to me, wait for my OK, then run it."
```

Approve the `psql` Bash call when prompted, then ask in plain English. (The repo's [`CLAUDE.md`](./CLAUDE.md) already tells the agent to connect as `analyst_ro` and to show SQL before running it.)

> Want to check the whole thing end to end first? Run `bash scripts/validate.sh`. It stands up a throwaway Postgres, creates the role, proves writes are blocked, and runs the demo queries.

## Connect to a cloud Postgres (the same thing, on a real server)

The local Docker database above is the zero-setup way to follow along. In real life your database lives on a server, not on your laptop, so here is the same workflow against a managed cloud Postgres. This raw walkthrough uses sample data; to point Claude Code at real production data, add the curated PII-safe layer below first. The host, the login, and requiring SSL change, and the exact admin role you create the role from varies by provider; the rest of the workflow does not. This works the same on Neon, Supabase, Amazon RDS or Aurora, Google Cloud SQL, Azure Database for PostgreSQL, Render, and Railway. The examples below use [Neon](https://neon.tech)'s free tier.

**1. Create a database and load the schema.** Create a project (on Neon, a free one is enough), then load the same schema into it as the project owner role:

```bash
psql "postgresql://<owner>:<owner-pw>@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require" \
  -v ON_ERROR_STOP=1 -f sql/01_schema.sql
```

**2. Create the read-only role, as the project owner.** Run the same [`sql/02_create_readonly_role.sql`](./sql/02_create_readonly_role.sql) connected as your project's owner role. On Neon that is the `<db>_owner` role, which can `CREATE ROLE`. A role created from SQL on a managed provider gets only basic privileges, so the explicit `GRANT SELECT` in that file is exactly what scopes it:

```bash
psql "postgresql://<owner>:<owner-pw>@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require" \
  -v ON_ERROR_STOP=1 -f sql/02_create_readonly_role.sql
```

**3. Put the read-only login in `~/.pgpass`** with the provider's host on the line (SSL goes in the connection string, not in `.pgpass`; edit the file directly or prepend the command with a space so the password stays out of shell history). The host in `.pgpass` must exactly match the host in your connection string; Neon exposes both a pooled `-pooler` host and a direct host, so pick one and use it in both places:

```bash
echo '<endpoint>.<region>.aws.neon.tech:5432:<db>:analyst_ro:<the password you set>' >> ~/.pgpass
chmod 0600 ~/.pgpass
```

**4. Point Claude Code at it as `analyst_ro`,** requiring SSL:

```bash
claude "Connect to Postgres as analyst_ro: psql 'postgresql://analyst_ro@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require'. From now on, write the SQL, show it to me, wait for my OK, then run it."
```

**5. Prove it's read-only on the cloud too.** Same as local Step 3, but against the cloud host as `analyst_ro`:

```bash
psql "postgresql://analyst_ro@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require" \
  -c "DROP TABLE shop.orders;"   # -> ERROR: must be owner of table orders
psql "postgresql://analyst_ro@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require" \
  -c "UPDATE shop.orders SET status='x';"   # -> ERROR: permission denied for table orders
```

A `DROP` returns `must be owner`, an `UPDATE`/`DELETE` returns `permission denied`, and a `SELECT` works. The destructive part is gone on the provider too.

You are reaching the provider's own cloud with plain `psql`. You do not need their MCP server; the read-only role is what protects you either way. Two notes: keep the owner password out of shell history the same way you do for `analyst_ro` (omit it from the connection string so `psql` prompts, or add an owner line to `~/.pgpass`). And on serverless tiers (Neon, for example) the compute can pause after a few minutes idle and takes about a second to wake on the next query, so pre-warm it with one query if you care about that first response.

## Prompts to try

Set one standing rule for the session first: *"Write the SQL, show it to me, wait for my OK, then run it."* Then:

- "How many orders did we get in May, and what's the total order value?"
- "Walk the `shop` schema. List the tables, their columns, and how they relate."
- "Which product category brought in the most revenue from completed orders?"
- "Who are our top 5 customers?" Read the SQL: "top" by *order count* and by *revenue* are two different people here. Correct SQL can still answer the wrong question. (The durable fix for that ambiguity is a [semantic layer](https://www.youtube.com/watch?v=2hiELj4Yavw).)
- "Show me a few rows from the `customers` table." Those names and emails just went to the model API. A read-only role stops writes, not reads.

## What leaves your machine

`SELECT`-only protects against writes. It does nothing to stop sensitive rows being read into the model. Read-only is not the same as safe-to-read. Minimize what you send: aggregate first, use `LIMIT`, or query masked views / a reporting schema with no raw PII. The `orders.notes` column here is free text on purpose: if a row held attacker-planted text, an agent reading it could be steered by it (Simon Willison's ["lethal trifecta"](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)).

When the database is in the cloud, two more honest notes apply: your provider holds the data at rest on their infrastructure, and the connection is encrypted in transit (`sslmode=require`), which managed providers force (`require` encrypts but does not verify the server's identity; `verify-full` does, using a CA cert your provider supplies). None of that changes the model-API hop above.

You can point this at production. The responsible way is not avoiding production, it is putting the guardrails at the database first: the read-only role below, plus a curated, PII-safe schema. Where this is still not the answer: write-heavy workloads, or one instance the whole team writes against at once.

## Connect to PII safely (point the agent at production, responsibly)

A read-only role stops writes. It does nothing to stop raw PII being read into the model. The fix is a curated schema: the agent queries real data, but the raw values never reach it. [`sql/03_pii_safe_layer.sql`](./sql/03_pii_safe_layer.sql) builds the Postgres version of the three principles from the companion video ["So AI Can Access Your Database's PII, What to Do?"](https://www.youtube.com/watch?v=NJolk9KBn7c):

1. **Schema segregation.** The agent reaches one curated schema (`ai_curated`); the raw tables, and the salts, live where it cannot.
2. **Hashing with a stable per-entity salt.** PII the agent must join on (an email, a phone) becomes a SHA-256 hash with a stable per-entity salt: a pseudonym it can join on but cannot read back to the raw value. The salts sit in a separate `ai_private` schema the agent is never granted, so it cannot reverse the hash, and keeping the salt private is what stops a low-entropy value like a phone from being brute-forced. PII it does not need is dropped (free text becomes a length).
3. **Identity selection.** A dedicated `analyst_ai` role granted only `ai_curated`, nothing on the raw schema.

Run it after steps 1 and 2 (set the role password the same way you did for `analyst_ro`):

```bash
psql -h localhost -p 55432 -U postgres -v ON_ERROR_STOP=1 -f sql/03_pii_safe_layer.sql
```

Then prove it as `analyst_ai`: `SELECT email_hash FROM ai_curated.customers` works (hash only), `SELECT email FROM shop.customers` is refused. The agent can still do real analysis (joins, revenue, cohorts) over the curated views; it just can never read a raw value. `bash scripts/validate.sh` checks this end to end.

Why a view is enough to enforce it: a Postgres view reads its base tables with the view owner's privileges, so the curated views (owned by admin) read the raw tables under the hood while the agent holds `SELECT` on the views only.

## Project structure

```
claude-code-postgres/
├── docker-compose.yml              # one-command local Postgres, auto-loads the schema
├── sql/
│   ├── 01_schema.sql               # the shop schema + sample data (PII + a notes column)
│   ├── 02_create_readonly_role.sql # the read-only role (set your own password, run as admin)
│   └── 03_pii_safe_layer.sql       # curated schema + masked views + scoped AI role (PII-safe)
├── scripts/
│   └── validate.sh                 # end-to-end check: read-only role + PII-safe layer + demo queries
├── images/
│   └── egress-boundary.png         # what stays local vs what goes to the model API
├── .env.example                    # connection vars (no secrets)
└── README.md
```

## License

MIT

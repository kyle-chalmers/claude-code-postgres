# CLAUDE.md

> This repository is public. Do not put secrets, credentials, or personal/operational values in any tracked file. Owner-specific values live in `.internal/` (git-ignored).

## Project overview

A small, self-contained PostgreSQL analytics database used to query data in plain English from the terminal, with the safety controls that make that responsible. The database is a `shop` schema (customers, products, orders, order_items) that runs either locally in Docker or on a managed cloud Postgres (Neon, Supabase, RDS/Aurora, Cloud SQL, Azure, Render, Railway); only the connection differs. The intended users are data analysts, analytics engineers, and BI practitioners who already know SQL and want an AI agent to help them query a database without giving it the ability to modify it.

The core idea: an agent connects to the database as a **read-only role** and writes SQL that a human reads before it runs. The database enforces read-only at the role level, so the agent cannot write, drop, or delete regardless of what it is asked to do.

## The database

Schema `shop`, loaded from `sql/01_schema.sql`:

- `customers(customer_id, name, email, region, signup_date)`: `email` is synthetic PII (fake `@example.com` addresses, not real people).
- `products(product_id, name, category, unit_price)`
- `orders(order_id, customer_id, order_date, status, notes)`: `status` is `completed` | `refunded` | `pending`; `notes` is free text.
- `order_items(order_id, product_id, quantity)`: links orders to products (an order can have several line items).

Cardinality worth remembering: one customer has many orders; one order has many order_items. Revenue lives in `order_items.quantity * products.unit_price`, so revenue questions require the join through `order_items`.

## How to connect (official-first)

Use `psql`, PostgreSQL's official command-line client, through Bash. Do not reach for a third-party MCP server: there is no official Postgres MCP server (the reference one is archived), and the database role is what actually enforces safety regardless of the client.

- Admin (schema + role setup only): `psql -h localhost -p 55432 -U postgres` (password in `~/.pgpass`). On a managed cloud Postgres, connect as the project owner role instead (on Neon, `<db>_owner`) and add `?sslmode=require`.
- Analysis on real/PII-bearing data: connect as `analyst_ai`, the curated role scoped to the `ai_curated` PII-safe schema (set up by `sql/03`). It never reaches raw tables. Cloud: `psql "postgresql://analyst_ai@<endpoint>.<region>.aws.neon.tech/<db>?sslmode=require"`.
- Read-only on the raw `shop` sample: connect as `analyst_ro` (`psql -h localhost -p 55432 -U analyst_ro -d postgres`). This is the basic sandbox role and the deliberate "watch the PII leak, then fix it with the curated schema" teaching step, not the steady-state for real data.

Credentials belong in `~/.pgpass` (`chmod 0600`), never inline in a command or in shell history. On a cloud connection, SSL is required and goes in the connection string, not in `~/.pgpass`.

## Conventions

- **Write the SQL, show it, wait for approval, then run it.** This is a standing rule for every query, not a one-time ask. The value of an agent here is that a human can read the generated SQL before it executes.
- **Prefer `analyst_ai` (the curated, PII-safe role) for analysis on real data;** `analyst_ro` reads the raw sample only. Only use the admin/owner login to create the schema, roles, or the curated layer.
- **Never generate or hardcode a password.** When creating the read-only role, emit the SQL with a placeholder and let the human set the secret and run it.
- **Scope grants to the schema, SELECT only.** `GRANT USAGE ON SCHEMA shop` + `GRANT SELECT ON ALL TABLES IN SCHEMA shop`; set `ALTER DEFAULT PRIVILEGES` so future tables are covered. Never grant write privileges.
- **Confirm grain and filters on aggregates.** State whether a number is per-order or per-line-item; confirm whether `status` should be filtered (e.g. exclude `refunded`) before reporting a total.
- **Minimize what you read into context.** Prefer aggregates and `LIMIT` over selecting raw rows; remember that any rows returned (including PII) are sent to the model API.

## Working principles

- Explain non-obvious SQL choices briefly (join keys, the grain, why a filter is there).
- Print queries as formatted SQL before executing them.
- When a question is ambiguous ("top customers" can mean by count or by revenue), say so and pick the most likely reading, or ask, rather than silently choosing one.
- If a write is attempted and refused, that is the role working as intended, not an error to route around.

## Setup commands

```bash
docker compose up -d                                              # start Postgres + load schema
psql -h localhost -p 55432 -U postgres -f sql/02_create_readonly_role.sql   # create the role (set password first)
bash scripts/validate.sh                                          # end-to-end check
docker compose down -v                                            # tear down
```

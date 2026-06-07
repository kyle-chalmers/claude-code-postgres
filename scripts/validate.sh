#!/usr/bin/env bash
# End-to-end check that the demo works: stands up Postgres, loads the schema,
# creates the read-only role, proves writes are blocked, and runs the queries
# the walkthrough relies on (including the "top customers" ambiguity).
#
# This uses a throwaway role password for automated checking only -- when you do
# this for real, set your own password in sql/02_create_readonly_role.sql.
#
# Usage:  bash scripts/validate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=claude-code-postgres-validate
RO_PW=readonly_test
docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "Starting Postgres..."
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=demo -p 55433:5432 postgres:16-alpine >/dev/null
for i in $(seq 1 40); do docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

echo "Loading schema..."
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 < sql/01_schema.sql >/dev/null
echo "  loaded."

echo
echo "== 1. Create the read-only role =="
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE analyst_ro LOGIN PASSWORD '${RO_PW}';
GRANT USAGE ON SCHEMA shop TO analyst_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO analyst_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA shop GRANT SELECT ON TABLES TO analyst_ro;
SQL

echo
echo "== 2. Failed-write proof (connected as analyst_ro) =="
echo "-- attempt DROP --"
docker exec -e PGPASSWORD="${RO_PW}" "$NAME" psql -U analyst_ro -d postgres -c "DROP TABLE shop.orders;" 2>&1 | grep -i "error\|denied\|must be owner" | sed 's/^/   /' || true
echo "-- attempt UPDATE --"
docker exec -e PGPASSWORD="${RO_PW}" "$NAME" psql -U analyst_ro -d postgres -c "UPDATE shop.orders SET status='x';" 2>&1 | grep -i "error\|denied" | sed 's/^/   /' || true
echo "   (DROP -> 'must be owner of table orders'; UPDATE -> 'permission denied for table orders'; both blocked)"

echo
echo "== 3. SELECT works for analyst_ro =="
docker exec -e PGPASSWORD="${RO_PW}" "$NAME" psql -U analyst_ro -d postgres -c "SELECT count(*) AS orders_visible FROM shop.orders;"

echo
echo "== 4. 'Top customers' is ambiguous: count vs revenue =="
echo "-- by ORDER COUNT (expect Liam Chen #1) --"
docker exec "$NAME" psql -U postgres -c "
SET search_path TO shop;
SELECT c.name, count(*) AS orders
FROM customers c JOIN orders o ON o.customer_id=c.customer_id
GROUP BY c.name ORDER BY orders DESC, c.name LIMIT 5;"
echo "-- by REVENUE (expect Ethan Brooks #1) --"
docker exec "$NAME" psql -U postgres -c "
SET search_path TO shop;
SELECT c.name, sum(oi.quantity*p.unit_price) AS revenue
FROM customers c JOIN orders o ON o.customer_id=c.customer_id
JOIN order_items oi ON oi.order_id=o.order_id
JOIN products p ON p.product_id=oi.product_id
GROUP BY c.name ORDER BY revenue DESC LIMIT 5;"

echo
echo "== 5. Missing-filter trap: revenue with vs without refunded =="
docker exec "$NAME" psql -U postgres -c "
SET search_path TO shop;
SELECT sum(oi.quantity*p.unit_price) AS revenue_all,
       sum(oi.quantity*p.unit_price) FILTER (WHERE o.status='completed') AS revenue_completed
FROM orders o JOIN order_items oi ON oi.order_id=o.order_id
JOIN products p ON p.product_id=oi.product_id;"
echo "   (expect 751.50 all vs 631.50 completed -- the refunded \$120 order moves the number)"

echo
echo "Cleaning up..."
docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "Done."

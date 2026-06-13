#!/usr/bin/env bash
# End-to-end check that the demo works: stands up Postgres, loads the schema,
# creates the read-only role FROM THE ACTUAL FILE you run (sql/02), proves
# writes are blocked, and runs the demo queries as analyst_ro (the role the agent
# uses). Uses a throwaway role password for automated checking only -- when you do
# this for real, set your own password in sql/02_create_readonly_role.sql.
#
# Usage:  bash scripts/validate.sh
#
# This validates the LOCAL path (the canonical, no-account reproducible check).
# The cloud path uses the same sql/02 role file; see the README "Connect to a
# cloud Postgres" section. Nothing here needs a cloud account.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=claude-code-postgres-validate
RO_PW=readonly_test
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "Starting Postgres..."
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=demo -p 55433:5432 postgres:16-alpine >/dev/null
for i in $(seq 1 40); do docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

echo "Loading schema (sql/01_schema.sql)..."
docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1 < sql/01_schema.sql >/dev/null
echo "  loaded."

echo
echo "== 1. Create the read-only role (running the real sql/02 with a test password) =="
# Substitute only the placeholder password so the validation tests the actual artifact.
sed "s/CHANGE_ME_BEFORE_RUNNING/${RO_PW}/" sql/02_create_readonly_role.sql \
  | docker exec -i "$NAME" psql -U postgres -v ON_ERROR_STOP=1

ro() { docker exec -e PGPASSWORD="${RO_PW}" "$NAME" psql -U analyst_ro -d postgres "$@"; }

echo
echo "== 2. Failed-write proof (as analyst_ro) -- asserts the writes are actually refused =="
drop_out=$(ro -c "DROP TABLE shop.orders;" 2>&1 || true)
upd_out=$(ro -c "UPDATE shop.orders SET status='x';" 2>&1 || true)
echo "   DROP   -> ${drop_out##*ERROR:  }"
echo "   UPDATE -> ${upd_out##*ERROR:  }"
echo "$drop_out" | grep -qi "must be owner"      || { echo "FAIL: DROP was not refused as expected"; exit 1; }
echo "$upd_out"  | grep -qi "permission denied"  || { echo "FAIL: UPDATE was not refused as expected"; exit 1; }
echo "   OK: both writes refused."

echo
echo "== 3. SELECT works for analyst_ro =="
ro -c "SELECT count(*) AS orders_visible FROM orders;"   # search_path=shop is set on the role

echo
echo "== 4. 'Top customers' is ambiguous: count vs revenue (as analyst_ro) =="
echo "-- by ORDER COUNT (expect Liam Chen #1) --"
ro -c "
SELECT c.name, count(*) AS orders
FROM customers c JOIN orders o ON o.customer_id=c.customer_id
GROUP BY c.name ORDER BY orders DESC, c.name LIMIT 5;"
echo "-- by REVENUE (expect Ethan Brooks #1) --"
ro -c "
SELECT c.name, sum(oi.quantity*p.unit_price) AS revenue
FROM customers c JOIN orders o ON o.customer_id=c.customer_id
JOIN order_items oi ON oi.order_id=o.order_id
JOIN products p ON p.product_id=oi.product_id
GROUP BY c.name ORDER BY revenue DESC LIMIT 5;"

echo
echo "== 5. Missing-filter trap: revenue with vs without refunded (as analyst_ro) =="
ro -c "
SELECT sum(oi.quantity*p.unit_price) AS revenue_all,
       sum(oi.quantity*p.unit_price) FILTER (WHERE o.status='completed') AS revenue_completed
FROM orders o JOIN order_items oi ON oi.order_id=o.order_id
JOIN products p ON p.product_id=oi.product_id;"
echo "   (expect 751.50 all vs 631.50 completed -- the refunded \$120 order moves the number)"

echo
echo "Done."

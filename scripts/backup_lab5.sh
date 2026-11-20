#!/usr/bin/env bash
# ЛР №5: резервне копіювання (pg_dump, custom + plain) та перевірка відновлення в окрему БД.
# Змінні: CONTAINER=technomart_db DB=technomart PGUSER=postgres USE_DOCKER=1
set -euo pipefail
cd "$(dirname "$0")/.."
CONTAINER="${CONTAINER:-technomart_db}"; DB="${DB:-technomart}"; PGUSER="${PGUSER:-postgres}"
RESTORE_DB="${DB}_restore"; mkdir -p backups
STAMP=$(date +%Y%m%d_%H%M%S); DUMP="backups/${DB}_${STAMP}.dump"; SQL="backups/${DB}_${STAMP}.sql"

run() { if [ "${USE_DOCKER:-1}" = 1 ]; then docker exec -i "$CONTAINER" "$@"; else "$@"; fi; }
count_rows() {  # count_rows <db>
    run psql -U "$PGUSER" -d "$1" -At -c "SELECT 'customers='||count(*) FROM customers UNION ALL SELECT 'orders='||count(*) FROM orders UNION ALL SELECT 'order_items='||count(*) FROM order_items UNION ALL SELECT 'products='||count(*) FROM products UNION ALL SELECT 'audit_log='||count(*) FROM audit_log UNION ALL SELECT 'mv_daily_sales='||count(*) FROM mv_daily_sales"
}

echo "== 1. Резервні копії =="
run pg_dump -U "$PGUSER" -d "$DB" -F c -Z 6 > "$DUMP"          # custom-формат: стиснення, вибіркове відновлення
run pg_dump -U "$PGUSER" -d "$DB" --no-owner > "$SQL"          # plain SQL
ls -lh "$DUMP" "$SQL"
run pg_restore -l < "$DUMP" | head -15                          # вміст архіву

echo "== 2. Відновлення в нову БД $RESTORE_DB =="
run psql -U "$PGUSER" -d postgres -c "DROP DATABASE IF EXISTS $RESTORE_DB" -c "CREATE DATABASE $RESTORE_DB"
run pg_restore -U "$PGUSER" -d "$RESTORE_DB" --no-owner < "$DUMP"

echo "== 3. Порівняння кількості рядків =="
diff <(count_rows "$DB") <(count_rows "$RESTORE_DB") && echo "OK: дані в оригіналі та відновленій БД збігаються"
echo "== 4. Перевірка об'єктів у відновленій БД =="
run psql -U "$PGUSER" -d "$RESTORE_DB" -c "SELECT (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal) AS triggers, (SELECT count(*) FROM pg_indexes WHERE schemaname='public') AS indexes, (SELECT count(*) FROM pg_views WHERE schemaname='public') AS views, (SELECT count(*) FROM pg_matviews) AS matviews;"
echo "Відновлення вибіркової таблиці (приклад): pg_restore -d $RESTORE_DB -t customers --clean --if-exists $DUMP"

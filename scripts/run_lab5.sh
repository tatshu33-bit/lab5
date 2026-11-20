#!/usr/bin/env bash
# ЛР №5: повний прогін. Використання: ./scripts/run_lab5.sh
# Змінні: CONTAINER=technomart_db  DB=technomart  PGUSER=postgres  USE_DOCKER=1 (0 - локальний psql)
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-technomart_db}"; DB="${DB:-technomart}"; PGUSER="${PGUSER:-postgres}"
LAB=database/lab5; OUT=lab5_results; mkdir -p "$OUT"

psql_file() {   # psql_file <файл.sql> [вихідний файл]
    local f="$1" o="${2:-/dev/stdout}"
    if [ "${USE_DOCKER:-1}" = 1 ]; then
        docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$DB" -X -q -v ON_ERROR_STOP=0 < "$f" > "$o"
    else
        psql -U "$PGUSER" -d "$DB" -X -q -v ON_ERROR_STOP=0 -f "$f" > "$o"
    fi
}
run_strict() {  # зупиняється на першій помилці
    if [ "${USE_DOCKER:-1}" = 1 ]; then
        docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$DB" -X -q -v ON_ERROR_STOP=1 < "$1"
    else
        psql -U "$PGUSER" -d "$DB" -X -q -v ON_ERROR_STOP=1 -f "$1"
    fi
}

echo "== 0. Тестові дані (1-3 хв) =="; run_strict $LAB/00_seed_perf_data.sql
echo "== 1. Базовий стан без індексів ==";  run_strict $LAB/01_drop_baseline_indexes.sql
echo "== 2. EXPLAIN ANALYZE ДО (прогрів + вимір) =="
psql_file $LAB/explain_queries.sql /dev/null
psql_file $LAB/explain_queries.sql $OUT/explain_before.txt
echo "== 3. Індекси ==";                    run_strict $LAB/02_indexes.sql | tee $OUT/index_sizes.txt
echo "== 4. EXPLAIN ANALYZE ПІСЛЯ =="
psql_file $LAB/explain_queries.sql /dev/null
psql_file $LAB/explain_queries.sql $OUT/explain_after.txt
for f in 03_views 04_audit_validation 05_level3_matview_cascade 06_users_roles 07_maintenance; do
    echo "== $f =="; run_strict $LAB/$f.sql
done
echo "== Тести ==";                         psql_file $LAB/tests.sql $OUT/tests_output.txt 2>&1 || true
echo "== Обслуговування ==";
if [ "${USE_DOCKER:-1}" = 1 ]; then
    docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$DB" -X -q -c "CALL maintain_database();" -c "SELECT operation, object_name, round(duration_ms,1) AS ms FROM maintenance_log ORDER BY log_id DESC LIMIT 10;"
else
    psql -U "$PGUSER" -d "$DB" -X -q -c "CALL maintain_database();" -c "SELECT operation, object_name, round(duration_ms,1) AS ms FROM maintenance_log ORDER BY log_id DESC LIMIT 10;"
fi
echo "== Моніторинг =="; psql_file $LAB/08_monitor.sql $OUT/monitor_output.txt

echo; echo "== Порівняння часу виконання (Execution Time) =="
ext() { grep -E "^ *Execution Time:" "$1" | awk '{print $3}'; }
paste <(ext $OUT/explain_before.txt) <(ext $OUT/explain_after.txt) \
  | awk '{printf "Q%d  до: %9.3f мс   після: %9.3f мс   покращення: %6.1f%%  (x%.1f)\n", NR, $1, $2, ($1-$2)/$1*100, $1/$2}' \
  | tee $OUT/comparison.txt
echo "Результати збережено в $OUT/"

-- ЛР №5 / 08 (рівень 3): моніторинг продуктивності.
-- Запуск: psql -U postgres -d technomart -f database/lab5/08_monitor.sql
-- Для розділу про найповільніші запити потрібен pg_stat_statements (docker-compose.yml вже підключає його через
-- shared_preload_libraries; після зміни compose-файлу перезапустіть контейнер).
\pset pager off
\pset border 2

SELECT current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%' AS can_pss \gset
\if :can_pss
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
\endif

\echo
\echo '=== 1. Загальна інформація: розмір БД та частка потрапляння в кеш (shared buffers) ==='
SELECT current_database() AS db,
       pg_size_pretty(pg_database_size(current_database())) AS db_size,
       round(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) AS cache_hit_pct
FROM pg_stat_database WHERE datname = current_database();

\echo
\echo '=== 2. Використання індексів (найактивніші) ==='
SELECT s.relname AS table_name, s.indexrelname AS index_name, s.idx_scan,
       s.idx_tup_read, s.idx_tup_fetch,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_stat_user_indexes s
ORDER BY s.idx_scan DESC, pg_relation_size(s.indexrelid) DESC
LIMIT 15;

\echo
\echo '=== 3. Індекси, які ще не використовувались (кандидати на видалення; PK/UNIQUE виключено) ==='
SELECT s.relname AS table_name, s.indexrelname AS index_name, s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique
ORDER BY pg_relation_size(s.indexrelid) DESC;

\echo
\echo '=== 4. Таблиці з перевагою послідовних сканувань (можливо, бракує індексу) ==='
SELECT relname AS table_name, seq_scan, seq_tup_read, idx_scan,
       round(100.0 * idx_scan / NULLIF(seq_scan + idx_scan, 0), 1) AS idx_scan_pct,
       n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_tup_read DESC
LIMIT 10;

\echo
\echo '=== 5. Мертві кортежі та останнє очищення ==='
SELECT relname AS table_name, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 10;

\echo
\echo '=== 6. Найбільші таблиці та їхні індекси ==='
SELECT relname AS table_name,
       pg_size_pretty(pg_table_size(relid))   AS table_size,
       pg_size_pretty(pg_indexes_size(relid)) AS indexes_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;

\echo
\echo '=== 7. Поточні довготривалі запити (понад 5 секунд) ==='
SELECT pid, usename, state, now() - query_start AS running_for, left(query, 80) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid() AND now() - query_start > interval '5 seconds'
ORDER BY query_start;

\echo
\echo '=== 8. Найповільніші запити (pg_stat_statements) ==='
\if :can_pss
    SELECT left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS query,
           calls,
           round(total_exec_time::numeric, 1) AS total_ms,
           round(mean_exec_time::numeric, 2)  AS mean_ms,
           round(max_exec_time::numeric, 1)   AS max_ms,
           rows
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND query NOT ILIKE '%pg_stat_statements%'
    ORDER BY mean_exec_time DESC
    LIMIT 10;
\else
    \echo 'pg_stat_statements не підключено: додайте shared_preload_libraries = ''pg_stat_statements'' і перезапустіть сервер.'
\endif

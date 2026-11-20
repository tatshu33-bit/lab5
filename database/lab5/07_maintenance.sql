-- ЛР №5 / 07 (рівень 3): процедура автоматизованого обслуговування БД
\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS maintenance_log (
    log_id      SERIAL PRIMARY KEY,
    operation   TEXT NOT NULL,
    object_name TEXT,
    duration_ms NUMERIC(12,2),
    details     TEXT,
    executed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Викликати поза явною транзакцією (CALL maintain_database();): процедура робить COMMIT після кожної таблиці,
-- щоб REINDEX не тримав блокування на всіх таблицях одночасно.
-- VACUUM у процедурі неможливий (не працює в транзакції) - його виконує autovacuum або vacuumdb за розкладом;
-- тут лише перевіряємо частку мертвих кортежів і повідомляємо, кому потрібне очищення.
CREATE OR REPLACE PROCEDURE maintain_database(p_reindex BOOLEAN DEFAULT TRUE, p_dead_ratio NUMERIC DEFAULT 0.2)
LANGUAGE plpgsql AS $$
DECLARE
    r  RECORD;
    t0 TIMESTAMPTZ;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename LOOP
        t0 := clock_timestamp();
        EXECUTE format('ANALYZE public.%I', r.tablename);
        INSERT INTO maintenance_log (operation, object_name, duration_ms)
        VALUES ('ANALYZE', r.tablename, extract(epoch FROM clock_timestamp() - t0) * 1000);

        IF p_reindex THEN
            t0 := clock_timestamp();
            EXECUTE format('REINDEX TABLE public.%I', r.tablename);
            INSERT INTO maintenance_log (operation, object_name, duration_ms)
            VALUES ('REINDEX', r.tablename, extract(epoch FROM clock_timestamp() - t0) * 1000);
        END IF;
        COMMIT;
    END LOOP;

    t0 := clock_timestamp();
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;
    INSERT INTO maintenance_log (operation, object_name, duration_ms)
    VALUES ('REFRESH MV', 'mv_daily_sales', extract(epoch FROM clock_timestamp() - t0) * 1000);

    FOR r IN
        SELECT relname, n_dead_tup, n_live_tup
        FROM pg_stat_user_tables
        WHERE n_dead_tup > 1000 AND n_dead_tup > p_dead_ratio * GREATEST(n_live_tup, 1)
    LOOP
        INSERT INTO maintenance_log (operation, object_name, details)
        VALUES ('VACUUM NEEDED', r.relname, format('dead=%s live=%s', r.n_dead_tup, r.n_live_tup));
        RAISE NOTICE 'Таблиці % потрібен VACUUM (мертвих: %, живих: %)', r.relname, r.n_dead_tup, r.n_live_tup;
    END LOOP;
    COMMIT;
    RAISE NOTICE 'Обслуговування завершено';
END;
$$;

-- Запуск: CALL maintain_database();   Результат: SELECT * FROM maintenance_log ORDER BY log_id DESC LIMIT 20;

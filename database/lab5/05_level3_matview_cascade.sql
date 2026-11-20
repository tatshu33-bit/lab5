-- ЛР №5 / 05 (рівень 3): матеріалізоване представлення з автооновленням + каскадні тригери
\set ON_ERROR_STOP on

-- ===== Матеріалізоване представлення =====
DROP MATERIALIZED VIEW IF EXISTS mv_daily_sales;
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT o.order_date                                                        AS sale_date,
       count(DISTINCT o.order_id)                                          AS orders_count,
       sum(oi.quantity)                                                    AS items_sold,
       round(sum(oi.quantity * oi.unit_price * (1 - oi.discount)), 2)      AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.order_status <> 'cancelled'
GROUP BY o.order_date;

-- Унікальний індекс обов'язковий для REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX ux_mv_daily_sales_date ON mv_daily_sales (sale_date);

-- SECURITY DEFINER: REFRESH може виконати лише власник представлення, а викликати тригер буде модератор
CREATE OR REPLACE FUNCTION fn_refresh_mv_daily_sales() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;
    RETURN NULL;
END;
$$;

-- Оновлюємо лише після подій, що змінюють суми: позиції замовлень та зміна статусу/дати замовлення
DROP TRIGGER IF EXISTS trg_mv_refresh_items ON order_items;
CREATE TRIGGER trg_mv_refresh_items
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH STATEMENT EXECUTE FUNCTION fn_refresh_mv_daily_sales();

DROP TRIGGER IF EXISTS trg_mv_refresh_orders ON orders;
CREATE TRIGGER trg_mv_refresh_orders
AFTER UPDATE OF order_status, order_date ON orders
FOR EACH STATEMENT EXECUTE FUNCTION fn_refresh_mv_daily_sales();

-- ===== Каскад 1: позиція замовлення -> лояльність клієнта -> сповіщення =====
CREATE TABLE IF NOT EXISTS customer_loyalty (
    customer_id    INTEGER PRIMARY KEY REFERENCES customers(customer_id) ON DELETE CASCADE,
    lifetime_value NUMERIC(14,2) NOT NULL DEFAULT 0,
    orders_count   INTEGER       NOT NULL DEFAULT 0,
    tier           VARCHAR(10)   NOT NULL DEFAULT 'standard' CHECK (tier IN ('standard', 'silver', 'gold')),
    updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customer_notifications (
    notification_id BIGSERIAL PRIMARY KEY,
    customer_id     INTEGER NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    message         TEXT    NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION fn_loyalty_tier(p_value NUMERIC) RETURNS TEXT AS $$
    SELECT CASE WHEN p_value >= 1000000 THEN 'gold'
                WHEN p_value >= 300000  THEN 'silver'
                ELSE 'standard' END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_recalc_customer_loyalty(p_customer_id INT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO customer_loyalty (customer_id, lifetime_value, orders_count, tier)
    SELECT c.customer_id, COALESCE(x.v, 0), COALESCE(x.n, 0), fn_loyalty_tier(COALESCE(x.v, 0))
    FROM customers c
    LEFT JOIN (
        SELECT o.customer_id,
               sum(oi.quantity * oi.unit_price * (1 - oi.discount)) AS v,
               count(DISTINCT o.order_id)                           AS n
        FROM orders o
        JOIN order_items oi ON oi.order_id = o.order_id
        WHERE o.customer_id = p_customer_id AND o.order_status <> 'cancelled'
        GROUP BY o.customer_id
    ) x ON x.customer_id = c.customer_id
    WHERE c.customer_id = p_customer_id
    ON CONFLICT (customer_id) DO UPDATE
        SET lifetime_value = EXCLUDED.lifetime_value,
            orders_count   = EXCLUDED.orders_count,
            tier           = EXCLUDED.tier,
            updated_at     = now();
END;
$$;

-- Початкове заповнення для всіх клієнтів
INSERT INTO customer_loyalty (customer_id, lifetime_value, orders_count, tier)
SELECT c.customer_id,
       COALESCE(x.v, 0), COALESCE(x.n, 0), fn_loyalty_tier(COALESCE(x.v, 0))
FROM customers c
LEFT JOIN (
    SELECT o.customer_id,
           sum(oi.quantity * oi.unit_price * (1 - oi.discount)) AS v,
           count(DISTINCT o.order_id) AS n
    FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status <> 'cancelled'
    GROUP BY o.customer_id
) x ON x.customer_id = c.customer_id
ON CONFLICT (customer_id) DO NOTHING;

-- Ланка 1а: змінилась позиція замовлення
CREATE OR REPLACE FUNCTION fn_cascade_items_to_loyalty() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_customer INT;
BEGIN
    SELECT customer_id INTO v_customer FROM orders WHERE order_id = COALESCE(NEW.order_id, OLD.order_id);
    IF v_customer IS NOT NULL THEN
        PERFORM fn_recalc_customer_loyalty(v_customer);
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_items_loyalty ON order_items;
CREATE TRIGGER trg_cascade_items_loyalty
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION fn_cascade_items_to_loyalty();

-- Ланка 1б: змінився статус замовлення (скасування зменшує суму клієнта)
CREATE OR REPLACE FUNCTION fn_cascade_order_status_to_loyalty() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM fn_recalc_customer_loyalty(NEW.customer_id);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_status_loyalty ON orders;
CREATE TRIGGER trg_cascade_status_loyalty
AFTER UPDATE OF order_status ON orders
FOR EACH ROW WHEN (OLD.order_status IS DISTINCT FROM NEW.order_status)
EXECUTE FUNCTION fn_cascade_order_status_to_loyalty();

-- Ланка 2: змінився рівень лояльності -> сповіщення клієнту + запис в audit_log
CREATE OR REPLACE FUNCTION fn_loyalty_tier_notify() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO customer_notifications (customer_id, message)
    VALUES (NEW.customer_id, format('Рівень лояльності змінено: %s -> %s', OLD.tier, NEW.tier));
    INSERT INTO audit_log (operation, table_name, record_id, old_values, new_values, changed_columns)
    VALUES ('UPDATE', 'customer_loyalty', NEW.customer_id::text,
            jsonb_build_object('tier', OLD.tier), jsonb_build_object('tier', NEW.tier), ARRAY['tier']);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_loyalty_tier_notify ON customer_loyalty;
CREATE TRIGGER trg_loyalty_tier_notify
AFTER UPDATE OF tier ON customer_loyalty
FOR EACH ROW WHEN (OLD.tier IS DISTINCT FROM NEW.tier)
EXECUTE FUNCTION fn_loyalty_tier_notify();

-- ===== Каскад 2: продаж -> залишок (trg_order_items_stock з ЛР №4) -> заявка на поповнення =====
CREATE TABLE IF NOT EXISTS restock_requests (
    request_id SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    quantity   INTEGER NOT NULL CHECK (quantity > 0),
    status     VARCHAR(10) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Частковий унікальний індекс: на товар може бути лише одна відкрита заявка
CREATE UNIQUE INDEX IF NOT EXISTS ux_restock_open_per_product ON restock_requests (product_id) WHERE status = 'open';

CREATE OR REPLACE FUNCTION fn_products_restock_request() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO restock_requests (product_id, quantity)
    VALUES (NEW.product_id, GREATEST(NEW.reorder_level * 3, 10))
    ON CONFLICT (product_id) WHERE status = 'open' DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_restock ON products;
CREATE TRIGGER trg_products_restock
AFTER UPDATE OF units_in_stock ON products
FOR EACH ROW WHEN (NEW.units_in_stock <= NEW.reorder_level AND NOT NEW.discontinued
                   AND OLD.units_in_stock > NEW.units_in_stock)
EXECUTE FUNCTION fn_products_restock_request();

ANALYZE customer_loyalty;

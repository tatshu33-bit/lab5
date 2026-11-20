-- ЛР №5 / 06: користувач з обмеженими правами (рівень 1) та ієрархія ролей (рівень 3)
-- УВАГА: паролі нижче - навчальні. У реальній системі задавайте власні та не зберігайте їх у репозиторії.
\set ON_ERROR_STOP on

-- ===== Підготовка: функції тригерів мають працювати з правами власника, а не викликача =====
-- Без цього модератор, що вставляє в order_items, отримав би «permission denied» на products / activity_log.
ALTER FUNCTION fn_order_items_stock()        SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION fn_orders_cancel_restock()    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION fn_audit_row()                SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION log_activity(INT, VARCHAR, VARCHAR, INT, JSONB) SECURITY DEFINER SET search_path = public, pg_temp;

-- Історія цін: DEFAULT current_user став би власником функції, тому явно пишемо session_user
CREATE OR REPLACE FUNCTION fn_products_price_audit() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO product_price_history (product_id, old_price, new_price, changed_by)
    VALUES (NEW.product_id, OLD.unit_price, NEW.unit_price, session_user);
    RETURN NEW;
END;
$$;

-- ===== Рівень 1: користувач report_viewer =====
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'report_viewer') THEN
        CREATE ROLE report_viewer LOGIN PASSWORD 'Viewer#Lab5_change_me' CONNECTION LIMIT 5;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO report_viewer', current_database());
END $$;

ALTER ROLE report_viewer SET statement_timeout = '30s';
GRANT USAGE ON SCHEMA public TO report_viewer;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM report_viewer;

-- Таблиці без персональних даних і представлення-звіти
GRANT SELECT ON products, categories, regions,
                v_product_catalog, v_regional_customer_ranking,
                customer_orders_summary, monthly_sales_report TO report_viewer;
-- Стовпцеві права: контакти (email, phone, address) приховані
GRANT SELECT (customer_id, contact_name, city, region_id, customer_type, registration_date) ON customers TO report_viewer;

-- ===== Рівень 3: ієрархія ролей viewer < moderator < admin =====
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_viewer')    THEN CREATE ROLE role_viewer NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_moderator') THEN CREATE ROLE role_moderator NOLOGIN IN ROLE role_viewer; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_admin')     THEN CREATE ROLE role_admin NOLOGIN IN ROLE role_moderator; END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO role_viewer', current_database());
END $$;

-- viewer: лише читання бізнес-даних, без журналів, користувачів і сповіщень
GRANT USAGE ON SCHEMA public TO role_viewer;
GRANT SELECT ON regions, suppliers, categories, products, customers, employees, orders, order_items,
                order_totals, order_details, customer_orders_summary, product_sales_summary,
                monthly_sales_report, employee_performance, low_stock_products,
                v_product_catalog, v_regional_customer_ranking, v_customer_contacts,
                mv_daily_sales, customer_loyalty TO role_viewer;

-- moderator (успадковує viewer): змінює дані, читає журнали, але не видаляє довідники й клієнтів
GRANT INSERT, UPDATE ON customers, products, orders, order_items, restock_requests TO role_moderator;
GRANT DELETE ON orders, order_items TO role_moderator;                -- потрібно для delete_order()
GRANT SELECT ON audit_log, activity_log, product_price_history, restock_requests, customer_notifications TO role_moderator;
GRANT UPDATE ON v_customer_contacts TO role_moderator;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO role_moderator;

-- admin (успадковує moderator): повний доступ до даних + моніторинг; НЕ суперкористувач
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO role_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO role_admin;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO role_admin;
GRANT pg_monitor TO role_admin;

-- Нові таблиці, створені поточним власником, автоматично доступні для читання
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO role_viewer;

-- Користувачі-приклади
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab5_viewer') THEN
        CREATE ROLE lab5_viewer LOGIN PASSWORD 'View#Lab5_change_me' IN ROLE role_viewer;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab5_moderator') THEN
        CREATE ROLE lab5_moderator LOGIN PASSWORD 'Mod#Lab5_change_me' IN ROLE role_moderator;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lab5_admin') THEN
        CREATE ROLE lab5_admin LOGIN PASSWORD 'Admin#Lab5_change_me' IN ROLE role_admin;
    END IF;
END $$;

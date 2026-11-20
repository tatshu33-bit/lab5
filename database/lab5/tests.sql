-- ЛР №5: сценарій перевірки. Помилки у розділах «має бути відхилено» очікувані - це доказ роботи захисту.
\pset pager off
\set ON_ERROR_STOP off

\echo '--- Рівень 1: тригер логування (suppliers) ---'
BEGIN;
INSERT INTO suppliers (company_name, city, email) VALUES ('ТОВ Лаб5 Тест', 'Луцьк', 'lab5@test.ua');
UPDATE suppliers SET city = 'Київ' WHERE company_name = 'ТОВ Лаб5 Тест';
SELECT operation, table_name, record_id, changed_by, changed_at FROM audit_log WHERE table_name = 'suppliers' ORDER BY audit_id DESC LIMIT 3;
ROLLBACK;

\echo '--- Рівень 2: повний аудит INSERT/UPDATE/DELETE (categories) ---'
BEGIN;
INSERT INTO categories (category_name) VALUES ('Лаб5 тест');
UPDATE categories SET description = 'опис' WHERE category_name = 'Лаб5 тест';
DELETE FROM categories WHERE category_name = 'Лаб5 тест';
SELECT operation, table_name, record_id, changed_columns, old_values IS NOT NULL AS has_old, new_values IS NOT NULL AS has_new
FROM audit_log WHERE table_name = 'categories' ORDER BY audit_id DESC LIMIT 3;
ROLLBACK;

\echo '--- Рівень 2: валідація (має бути відхилено) ---'
INSERT INTO customers (contact_name, email, customer_type) VALUES ('Тест', 'invalid-email', 'individual');
INSERT INTO customers (contact_name, email, phone, customer_type) VALUES ('Тест', 'ok@example.com', 'abc', 'individual');
INSERT INTO customers (contact_name, email, registration_date, customer_type) VALUES ('Тест', 'ok2@example.com', CURRENT_DATE + 1, 'individual');
BEGIN;
UPDATE products SET unit_price = unit_price * 10 WHERE product_id = 1;
ROLLBACK;
\echo '--- Валідація: коректний запис проходить ---'
BEGIN;
INSERT INTO customers (contact_name, email, phone, customer_type) VALUES ('Валідний Клієнт', 'valid.lab5@example.com', '+380501234567', 'individual');
ROLLBACK;

\echo '--- Рівень 2: оновлюване представлення (RULES) ---'
BEGIN;
UPDATE v_customer_contacts SET email = 'rule.test@example.com' WHERE customer_id = 1;
SELECT customer_id, email FROM customers WHERE customer_id = 1;
DELETE FROM v_customer_contacts WHERE customer_id = 1;
SELECT count(*) AS still_exists FROM customers WHERE customer_id = 1;
ROLLBACK;

\echo '--- Рівень 3: каскад «позиція -> лояльність -> сповіщення» та «продаж -> склад -> заявка» ---'
BEGIN;
SELECT tier, lifetime_value FROM customer_loyalty WHERE customer_id = 1;
UPDATE products SET units_in_stock = 12, reorder_level = 10 WHERE product_id = 1;   -- поблизу порога
SELECT create_order(1, 1, 'Нова пошта', 100, jsonb_build_array(jsonb_build_object('product_id', 1, 'quantity', 5)));
SELECT tier, lifetime_value FROM customer_loyalty WHERE customer_id = 1;
SELECT * FROM restock_requests WHERE product_id = 1;
SELECT * FROM customer_notifications WHERE customer_id = 1 ORDER BY notification_id DESC LIMIT 3;
ROLLBACK;

\echo '--- Рівень 3: матеріалізоване представлення оновлюється тригером ---'
BEGIN;
SELECT revenue FROM mv_daily_sales WHERE sale_date = CURRENT_DATE;
SELECT create_order(1, 1, 'Нова пошта', 0, jsonb_build_array(jsonb_build_object('product_id', 21, 'quantity', 1)));
SELECT revenue FROM mv_daily_sales WHERE sale_date = CURRENT_DATE;
ROLLBACK;

\echo '--- Рівень 1: report_viewer (читання дозволене, решта - ні) ---'
SET ROLE report_viewer;
SELECT count(*) AS products_visible FROM products;
SELECT customer_id, contact_name, city FROM customers LIMIT 3;
SELECT email FROM customers LIMIT 1;                        -- має бути: permission denied
UPDATE products SET unit_price = 1 WHERE product_id = 1;    -- має бути: permission denied
SELECT * FROM users;                                        -- має бути: permission denied
RESET ROLE;

\echo '--- Рівень 3: ієрархія ролей ---'
SET ROLE lab5_viewer;
SELECT count(*) FROM orders;
DELETE FROM order_items WHERE order_id = -1;               -- має бути: permission denied
RESET ROLE;
SET ROLE lab5_moderator;
SELECT count(*) FROM audit_log;
UPDATE customers SET city = city WHERE customer_id = 1;    -- дозволено
DELETE FROM customers WHERE customer_id = -1;              -- має бути: permission denied
RESET ROLE;
SET ROLE lab5_admin;
SELECT count(*) FROM customer_notifications;
RESET ROLE;

-- Очищення тестових даних (за потреби повторного seed): перестворіть БД командою
--   docker compose down -v && docker compose up -d
-- і знову виконайте scripts/run_lab5.sh

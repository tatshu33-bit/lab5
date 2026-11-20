-- ЛР №5 / 02: індекси (рівень 1 - три звичайні, рівень 2 - часткові)
\set ON_ERROR_STOP on

-- ===== Рівень 1 =====
-- I1: Q1. Відбір замовлень клієнта вже відсортованих за датою (без окремого сортування).
CREATE INDEX IF NOT EXISTS idx_orders_customer_date ON orders (customer_id, order_date DESC);

-- I2: Q2. Пошук позицій за товаром; INCLUDE дозволяє читати кількість/ціну/знижку без звернення до таблиці
-- (index-only scan, якщо visibility map актуальна - див. VACUUM у 00_seed).
CREATE INDEX IF NOT EXISTS idx_order_items_product_cover
    ON order_items (product_id) INCLUDE (order_id, quantity, unit_price, discount);

-- I3: Q3. Діапазон дат + групування за статусом: статус у складі індексу, щоб не читати таблицю.
CREATE INDEX IF NOT EXISTS idx_orders_date_status ON orders (order_date, order_status);

-- ===== Рівень 2: часткові індекси =====
-- P1: лише відкриті замовлення (~15 % таблиці). Предикат збігається з умовою Q4, тому планувальник його використає.
CREATE INDEX IF NOT EXISTS idx_orders_open_date ON orders (order_date DESC)
    WHERE order_status IN ('pending', 'processing');

-- P2: юридичні особи - крихітна частка таблиці клієнтів.
CREATE INDEX IF NOT EXISTS idx_customers_company_city ON customers (city)
    WHERE customer_type = 'company';

ANALYZE orders; ANALYZE order_items; ANALYZE customers;

-- ===== Ефективність часткових індексів: розмір порівняно з повним індексом на тих самих стовпцях =====
CREATE INDEX idx_tmp_full_orders_date ON orders (order_date DESC);
CREATE INDEX idx_tmp_full_customers_city ON customers (city);

SELECT 'idx_orders_open_date (частковий)'      AS index_name, pg_size_pretty(pg_relation_size('idx_orders_open_date'))       AS size
UNION ALL SELECT 'повний індекс orders(order_date)',   pg_size_pretty(pg_relation_size('idx_tmp_full_orders_date'))
UNION ALL SELECT 'idx_customers_company_city (частковий)', pg_size_pretty(pg_relation_size('idx_customers_company_city'))
UNION ALL SELECT 'повний індекс customers(city)',      pg_size_pretty(pg_relation_size('idx_tmp_full_customers_city'));

DROP INDEX idx_tmp_full_orders_date;
DROP INDEX idx_tmp_full_customers_city;

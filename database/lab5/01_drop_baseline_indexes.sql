-- ЛР №5 / 01: «чистий» стан для вимірювання ДО оптимізації.
-- Скрипт 08_create_indexes.sql із ЛР №4 уже створив частину індексів; видаляємо ті, що перекривають
-- задачі цієї лаби, щоб показати їх вплив. Зовнішні ключі order_items.order_id та PK/UNIQUE лишаються.
DROP INDEX IF EXISTS idx_orders_customer_date;
DROP INDEX IF EXISTS idx_order_items_product;
DROP INDEX IF EXISTS idx_orders_active;
DROP INDEX IF EXISTS idx_products_low_stock;

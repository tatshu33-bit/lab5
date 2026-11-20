-- ЛР №5 / 00: масове наповнення для аналізу продуктивності
-- 50 000 клієнтів, 2 000 товарів, 300 000 замовлень, 900 000 позицій.
-- Запускати від суперкористувача (postgres): session_replication_role = replica вимикає тригери
-- на час завантаження, інакше аудит і склад обробляли б кожен рядок.
\set ON_ERROR_STOP on

SELECT EXISTS (SELECT 1 FROM customers WHERE email LIKE 'perf\_%@example.com') AS seeded \gset
\if :seeded
    \echo 'Тестові дані вже завантажено - пропускаємо (для повторного завантаження перестворіть БД: docker compose down -v)'
\else
    SET session_replication_role = replica;

    SELECT COALESCE(max(order_id), 0)   AS base_order   FROM orders   \gset
    SELECT COALESCE(max(product_id), 0) AS base_product FROM products \gset

    INSERT INTO customers (contact_name, city, region_id, email, phone, registration_date, customer_type)
    SELECT 'Клієнт ' || g,
           (ARRAY['Київ','Львів','Харків','Одеса','Дніпро','Луцьк'])[1 + g % 6],
           1 + g % 25,
           'perf_' || g || '@example.com',
           '+3809' || lpad((g % 100000000)::text, 8, '0'),
           DATE '2023-01-01' + (g % 1000),
           'individual'
    FROM generate_series(1, 50000) AS g;

    INSERT INTO products (product_name, supplier_id, category_id, unit_price, units_in_stock, reorder_level, discontinued)
    SELECT 'Тестовий товар ' || g,
           1 + g % 10,
           1 + g % 10,
           round((100 + random() * 49900)::numeric, 2),
           (random() * 500)::int,
           10,
           (g % 25 = 0)
    FROM generate_series(1, 2000) AS g;

    INSERT INTO orders (customer_id, employee_id, order_date, required_date, shipped_date, ship_city, order_status)
    SELECT cb.first_id + (g % 50000),
           1 + g % 10,
           t.od,
           t.od + 7,
           CASE WHEN t.st IN ('shipped', 'delivered') THEN t.od + 2 END,
           'Київ',
           t.st
    FROM (SELECT min(customer_id) AS first_id FROM customers WHERE email LIKE 'perf\_%@example.com') AS cb,
         generate_series(1, 300000) AS g
    CROSS JOIN LATERAL (
        SELECT DATE '2024-01-01' + (random() * 1050)::int AS od,
               CASE g % 20 WHEN 0 THEN 'cancelled'
                           WHEN 1 THEN 'pending' WHEN 2 THEN 'pending'
                           WHEN 3 THEN 'processing'
                           WHEN 4 THEN 'shipped'
                           ELSE 'delivered' END AS st
    ) AS t;

    -- 3 різні товари на замовлення: крок 101 за модулем 2000 дає різні product_id в межах одного замовлення
    INSERT INTO order_items (order_id, product_id, unit_price, quantity, discount)
    SELECT o.order_id, p.product_id, p.unit_price,
           1 + (o.order_id + k) % 3,
           CASE WHEN (o.order_id + k) % 7 = 0 THEN 0.10 ELSE 0 END
    FROM orders o
    CROSS JOIN generate_series(0, 2) AS k
    JOIN products p ON p.product_id = :base_product + 1 + ((o.order_id * 37 + k * 101) % 2000)
    WHERE o.order_id > :base_order;

    RESET session_replication_role;
\endif

VACUUM (ANALYZE) customers;
VACUUM (ANALYZE) products;
VACUUM (ANALYZE) orders;
VACUUM (ANALYZE) order_items;

SELECT 'customers' AS tbl, count(*) FROM customers
UNION ALL SELECT 'products', count(*) FROM products
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items;

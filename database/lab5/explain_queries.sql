-- ЛР №5: п'ять запитів для EXPLAIN (ANALYZE, BUFFERS).
-- Q1-Q3 - основні (рівень 1), Q4-Q5 - для часткових індексів (рівень 2).
-- Усі запити лише читають дані, тому транзакція з ROLLBACK не потрібна.
\echo '=== Q1: історія замовлень клієнта (JOIN + GROUP BY + ORDER BY) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.order_date, o.order_status,
       count(*) AS lines,
       round(sum(oi.quantity * oi.unit_price * (1 - oi.discount)), 2) AS total
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.customer_id = 4242
GROUP BY o.order_id, o.order_date, o.order_status
ORDER BY o.order_date DESC;

\echo '=== Q2: продажі одного товару (3 таблиці, фільтр по product_id) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.product_name, o.order_status,
       count(*) AS lines,
       sum(oi.quantity) AS qty,
       round(sum(oi.quantity * oi.unit_price * (1 - oi.discount)), 2) AS revenue
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE oi.product_id = 1000 AND o.order_status <> 'cancelled'
GROUP BY p.product_name, o.order_status;

\echo '=== Q3: навантаження менеджерів за місяць (діапазон дат + JOIN + GROUP BY) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.last_name, o.order_status, count(*) AS orders_cnt
FROM orders o
JOIN employees e ON e.employee_id = o.employee_id
WHERE o.order_date BETWEEN DATE '2026-03-01' AND DATE '2026-03-31'
GROUP BY e.employee_id, e.last_name, o.order_status
ORDER BY orders_cnt DESC;

\echo '=== Q4 (частковий індекс): відкриті замовлення цього року ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, order_date
FROM orders
WHERE order_status IN ('pending', 'processing') AND order_date >= DATE '2026-01-01'
ORDER BY order_date DESC;

\echo '=== Q5 (частковий індекс): юридичні особи міста ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, company_name
FROM customers
WHERE customer_type = 'company' AND city = 'Київ';

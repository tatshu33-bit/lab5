-- ЛР №5 / 03: представлення (рівень 1 - два, рівень 2 - оновлюване через RULES)
\set ON_ERROR_STOP on

-- Представлення 1: каталог товарів, доступних до замовлення
CREATE OR REPLACE VIEW v_product_catalog AS
SELECT p.product_id, p.product_name, c.category_name, s.company_name AS supplier_name,
       p.unit_price, p.units_in_stock,
       CASE WHEN p.unit_price >= 30000 THEN 'premium'
            WHEN p.unit_price >= 5000  THEN 'middle'
            ELSE 'budget' END AS price_segment
FROM products p
JOIN categories c ON c.category_id = p.category_id
LEFT JOIN suppliers s ON s.supplier_id = p.supplier_id
WHERE NOT p.discontinued AND p.units_in_stock > 0;

-- Представлення 2: рейтинг клієнтів усередині регіону (віконна функція над існуючим представленням ЛР №4)
CREATE OR REPLACE VIEW v_regional_customer_ranking AS
SELECT s.region_name, s.customer_id, s.contact_name, s.total_orders, s.total_amount,
       RANK() OVER (PARTITION BY s.region_name ORDER BY s.total_amount DESC) AS region_rank
FROM customer_orders_summary s
WHERE s.total_orders > 0;

-- Рівень 2: представлення з JOIN (не оновлюється автоматично) + правила UPDATE / INSERT / DELETE
CREATE OR REPLACE VIEW v_customer_contacts AS
SELECT c.customer_id, c.contact_name, c.company_name, c.email, c.phone, c.city, r.region_name
FROM customers c
LEFT JOIN regions r ON r.region_id = c.region_id;

-- UPDATE: змінюються лише контактні поля; customer_id та region_name через представлення змінити не можна
CREATE OR REPLACE RULE v_customer_contacts_upd AS
ON UPDATE TO v_customer_contacts
DO INSTEAD
    UPDATE customers
    SET contact_name = NEW.contact_name,
        email        = NEW.email,
        phone        = NEW.phone,
        city         = NEW.city
    WHERE customer_id = OLD.customer_id;

-- INSERT: тип клієнта визначається наявністю назви компанії
CREATE OR REPLACE RULE v_customer_contacts_ins AS
ON INSERT TO v_customer_contacts
DO INSTEAD
    INSERT INTO customers (contact_name, company_name, email, phone, city, customer_type)
    VALUES (NEW.contact_name, NEW.company_name, NEW.email, NEW.phone, NEW.city,
            CASE WHEN NEW.company_name IS NULL THEN 'individual' ELSE 'company' END);

-- DELETE: клієнтів з історією замовлень видаляти не можна - правило просто нічого не робить
CREATE OR REPLACE RULE v_customer_contacts_del AS
ON DELETE TO v_customer_contacts
DO INSTEAD NOTHING;

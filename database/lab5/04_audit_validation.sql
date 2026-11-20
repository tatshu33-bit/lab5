-- ЛР №5 / 04: журнал аудиту, тригер логування (рівень 1), повний аудит та валідація (рівень 2)
\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS audit_log (
    audit_id        BIGSERIAL PRIMARY KEY,
    operation       VARCHAR(10)  NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    table_name      VARCHAR(63)  NOT NULL,
    record_id       TEXT,
    old_values      JSONB,
    new_values      JSONB,
    changed_columns TEXT[],
    changed_by      VARCHAR(100) NOT NULL DEFAULT session_user,
    changed_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_log_table_time ON audit_log (table_name, changed_at DESC);
COMMENT ON TABLE audit_log IS 'ЛР5: журнал змін (операція, таблиця, час, користувач, старі/нові значення)';

-- ===== Рівень 1: простий тригер логування INSERT/UPDATE для постачальників =====
-- SECURITY DEFINER: запис у журнал можливий навіть для ролей без прав на audit_log;
-- ім'я користувача беремо з session_user, бо current_user у такій функції - це власник.
CREATE OR REPLACE FUNCTION log_supplier_changes() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (operation, table_name, record_id, new_values)
        VALUES ('INSERT', TG_TABLE_NAME, NEW.supplier_id::text, to_jsonb(NEW));
    ELSE
        INSERT INTO audit_log (operation, table_name, record_id, old_values, new_values)
        VALUES ('UPDATE', TG_TABLE_NAME, NEW.supplier_id::text, to_jsonb(OLD), to_jsonb(NEW));
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_log ON suppliers;
CREATE TRIGGER trg_supplier_log
AFTER INSERT OR UPDATE ON suppliers
FOR EACH ROW EXECUTE FUNCTION log_supplier_changes();

-- ===== Рівень 2: універсальний аудит INSERT / UPDATE / DELETE =====
-- Назва ключового стовпця передається аргументом тригера (TG_ARGV[0]), тому функція підходить для будь-якої таблиці.
CREATE OR REPLACE FUNCTION fn_audit_log() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_pk      TEXT := TG_ARGV[0];
    v_changed TEXT[];
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (operation, table_name, record_id, new_values)
        VALUES ('INSERT', TG_TABLE_NAME, to_jsonb(NEW) ->> v_pk, to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF to_jsonb(NEW) = to_jsonb(OLD) THEN
            RETURN NEW;                                   -- нічого не змінилось - не логуємо
        END IF;
        SELECT array_agg(n.key ORDER BY n.key) INTO v_changed
        FROM jsonb_each(to_jsonb(NEW)) n
        JOIN jsonb_each(to_jsonb(OLD)) o USING (key)
        WHERE n.value IS DISTINCT FROM o.value;
        INSERT INTO audit_log (operation, table_name, record_id, old_values, new_values, changed_columns)
        VALUES ('UPDATE', TG_TABLE_NAME, to_jsonb(NEW) ->> v_pk, to_jsonb(OLD), to_jsonb(NEW), v_changed);
        RETURN NEW;
    ELSE
        INSERT INTO audit_log (operation, table_name, record_id, old_values)
        VALUES ('DELETE', TG_TABLE_NAME, to_jsonb(OLD) ->> v_pk, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_log ON products;
CREATE TRIGGER trg_audit_log AFTER INSERT OR UPDATE OR DELETE ON products
FOR EACH ROW EXECUTE FUNCTION fn_audit_log('product_id');

DROP TRIGGER IF EXISTS trg_audit_log ON categories;
CREATE TRIGGER trg_audit_log AFTER INSERT OR UPDATE OR DELETE ON categories
FOR EACH ROW EXECUTE FUNCTION fn_audit_log('category_id');

DROP TRIGGER IF EXISTS trg_audit_log ON employees;
CREATE TRIGGER trg_audit_log AFTER INSERT OR UPDATE OR DELETE ON employees
FOR EACH ROW EXECUTE FUNCTION fn_audit_log('employee_id');

-- ===== Рівень 2: тригери валідації (BEFORE) =====
CREATE OR REPLACE FUNCTION fn_validate_customer() RETURNS TRIGGER AS $$
BEGIN
    IF btrim(NEW.contact_name) = '' THEN
        RAISE EXCEPTION 'Ім''я контактної особи не може бути порожнім'
            USING ERRCODE = 'check_violation', HINT = 'Вкажіть ПІБ клієнта';
    END IF;
    IF NEW.email IS NOT NULL AND NEW.email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
        RAISE EXCEPTION 'Некоректний формат email: %', NEW.email
            USING ERRCODE = 'check_violation', HINT = 'Приклад: name@example.com';
    END IF;
    IF NEW.phone IS NOT NULL AND NEW.phone !~ '^\+?[0-9 ()-]{7,20}$' THEN
        RAISE EXCEPTION 'Некоректний формат телефону: %', NEW.phone
            USING ERRCODE = 'check_violation', HINT = 'Приклад: +380501234567';
    END IF;
    IF NEW.registration_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Дата реєстрації не може бути в майбутньому: %', NEW.registration_date
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_customer ON customers;
CREATE TRIGGER trg_validate_customer BEFORE INSERT OR UPDATE ON customers
FOR EACH ROW EXECUTE FUNCTION fn_validate_customer();

CREATE OR REPLACE FUNCTION fn_validate_product() RETURNS TRIGGER AS $$
BEGIN
    IF btrim(NEW.product_name) = '' THEN
        RAISE EXCEPTION 'Назва товару не може бути порожньою' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.unit_price <= 0 THEN
        RAISE EXCEPTION 'Ціна товару має бути більшою за 0 (отримано %)', NEW.unit_price
            USING ERRCODE = 'check_violation';
    END IF;
    -- захист від помилки в порядку (наприклад, зайвий нуль): ціна не може зрости більш ніж втричі за одну зміну
    IF TG_OP = 'UPDATE' AND OLD.unit_price > 0 AND NEW.unit_price > OLD.unit_price * 3 THEN
        RAISE EXCEPTION 'Підозріла зміна ціни: % -> % (зростання більш ніж у 3 рази)', OLD.unit_price, NEW.unit_price
            USING ERRCODE = 'check_violation', HINT = 'Змінюйте ціну поетапно або перевірте значення';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_product ON products;
CREATE TRIGGER trg_validate_product BEFORE INSERT OR UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION fn_validate_product();

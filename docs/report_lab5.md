# Звіт з лабораторної роботи №5
**Керування БД, оптимізація продуктивності та автоматизація**

## Загальна інформація
- ПІБ студента: _(вкажіть)_
- Група: _(вкажіть)_
- База даних: інтернет-магазин «ТехноМарт» (ЛР №4), PostgreSQL 17 у Docker
- Рівень виконання: 3

> Усі скрипти лежать у `database/lab5/`, запуск — `./scripts/run_lab5.sh`, бекап — `./scripts/backup_lab5.sh`.
> Місця, позначені **⟨вставте⟩**, заповнюються фактичним виводом після запуску (`lab5_results/`).

## Відповідність вимогам

| Рівень | Вимога | Файл / об'єкт |
|---|---|---|
| 1 | EXPLAIN ANALYZE трьох запитів | `explain_queries.sql` (Q1–Q3) |
| 1 | Три індекси + перевірка покращення | `02_indexes.sql` (I1–I3), `scripts/run_lab5.sh` (порівняння) |
| 1 | Два представлення | `v_product_catalog`, `v_regional_customer_ranking` (`03_views.sql`) |
| 1 | Тригер логування INSERT/UPDATE | `trg_supplier_log` → `audit_log` (`04_audit_validation.sql`) |
| 1 | Користувач з обмеженими правами | `report_viewer` (`06_users_roles.sql`) |
| 2 | Представлення з RULES | `v_customer_contacts` + 3 правила (`03_views.sql`) |
| 2 | Тригер валідації | `trg_validate_customer`, `trg_validate_product` |
| 2 | Система аудиту з `audit_log` | `fn_audit_log()` на `products`, `categories`, `employees` |
| 2 | Часткові індекси з аналізом | `idx_orders_open_date`, `idx_customers_company_city` |
| 2 | pg_dump + відновлення | `scripts/backup_lab5.sh` |
| 3 | Матеріалізоване представлення з автооновленням | `mv_daily_sales` + `trg_mv_refresh_*` |
| 3 | Каскадні тригери | два каскади (розділ 8) |
| 3 | Ієрархія ролей | `role_viewer` < `role_moderator` < `role_admin` |
| 3 | Процедура обслуговування | `maintain_database()` (`07_maintenance.sql`) |
| 3 | Скрипт моніторингу | `08_monitor.sql` |

## 1. Підготовка даних
Таблиці ЛР №4 містять десятки рядків — оптимізатор на них завжди обирає Seq Scan. Тому `00_seed_perf_data.sql` додає
50 000 клієнтів, 2 000 товарів, 300 000 замовлень і 900 000 позицій (тригери на час завантаження вимкнено через
`session_replication_role = replica`, потім `VACUUM ANALYZE`). Перед вимірюванням `01_drop_baseline_indexes.sql` видаляє індекси з
`08_create_indexes.sql` (ЛР №4), що перекривають завдання цієї роботи, — щоб «до» було справжнім «до».

Вивід кількості рядків: **⟨вставте⟩**

## 2. Аналіз продуктивності (EXPLAIN ANALYZE)
Кожен запит виконується двічі: перший прогін — прогрів кешу, другий — вимір (`lab5_results/explain_before.txt`).

| № | Запит | Очікувана проблема до індексу |
|---|---|---|
| Q1 | Історія замовлень клієнта: `orders ⋈ order_items`, `WHERE customer_id = 4242`, `GROUP BY`, `ORDER BY order_date DESC` | Seq Scan по 300 000 замовлень + сортування |
| Q2 | Продажі товару: `order_items ⋈ orders ⋈ products`, `WHERE product_id = 1000` | Seq Scan по 900 000 позицій |
| Q3 | Навантаження менеджерів за місяць: `orders ⋈ employees`, діапазон `order_date`, `GROUP BY` | Seq Scan по `orders` |

Фрагменти планів «до» (ключові рядки: тип сканування, `actual time`, `Buffers`, `Execution Time`): **⟨вставте⟩**

## 3. Індекси
| Індекс | Для | Обґрунтування |
|---|---|---|
| `idx_orders_customer_date (customer_id, order_date DESC)` | Q1 | фільтр за клієнтом і готове сортування за датою; PostgreSQL не створює індекс для FK автоматично |
| `idx_order_items_product_cover (product_id) INCLUDE (order_id, quantity, unit_price, discount)` | Q2 | покриваючий індекс: усі потрібні стовпці в індексі, можливий Index Only Scan |
| `idx_orders_date_status (order_date, order_status)` | Q3 | діапазон за датою; статус у складі індексу, щоб не читати таблицю |

Результат (`lab5_results/comparison.txt`, формат «до / після / % покращення»): **⟨вставте⟩**

Фрагменти планів «після» (мають містити Index Scan / Bitmap Index Scan / Index Only Scan): **⟨вставте⟩**

**Ціна індексів:** кожен індекс сповільнює INSERT/UPDATE/DELETE і займає місце (розміри — `lab5_results/index_sizes.txt`).
Тому індекси створено лише під виміряні запити, а матеріалізоване представлення оновлюється вибірковими тригерами (розділ 8).

## 4. Представлення
```sql
-- v_product_catalog: товари, доступні до замовлення, із сегментом ціни
-- v_regional_customer_ranking: RANK() OVER (PARTITION BY region_name ORDER BY total_amount DESC)
```
Повний код — `03_views.sql`. Перевірка: `SELECT * FROM v_product_catalog LIMIT 10; SELECT * FROM v_regional_customer_ranking WHERE region_rank <= 3;`
Вивід: **⟨вставте⟩**

### Представлення з RULES (рівень 2)
`v_customer_contacts` об'єднує `customers` і `regions`, тому PostgreSQL не робить його оновлюваним автоматично. Правила:
- `UPDATE` → змінює лише `contact_name`, `email`, `phone`, `city` (ключ і регіон через представлення змінити не можна);
- `INSERT` → додає клієнта, тип визначається наявністю `company_name`;
- `DELETE` → `DO INSTEAD NOTHING`: клієнтів з історією замовлень видаляти не можна.

Спрацьовують також тригери валідації та аудиту таблиці `customers`, бо правило переписує запит на базову таблицю.
Примітка з методички: у нових проєктах замість RULES рекомендовано тригери `INSTEAD OF`.

## 5. Тригери
### Логування (рівень 1)
`trg_supplier_log` — `AFTER INSERT OR UPDATE ON suppliers`, пише в `audit_log` повні старі/нові значення (`to_jsonb`).

### Повний аудит (рівень 2)
Таблиця `audit_log`: `operation` (INSERT/UPDATE/DELETE), `table_name`, `record_id`, `old_values`, `new_values`,
`changed_columns`, `changed_by` (**`session_user`**), `changed_at`. Одна універсальна функція `fn_audit_log('<ключ>')`
підключена до `products`, `categories`, `employees`; UPDATE без реальних змін не логується.

**Важлива деталь.** Функції тригерів оголошено `SECURITY DEFINER`, щоб модератор міг змінювати дані, не маючи прав
на `audit_log`. Але в такій функції `current_user` — це власник, а не автор зміни, тому користувач береться з `session_user`.
З тієї ж причини `fn_products_price_audit()` з ЛР №4 перевизначено (інакше `product_price_history.changed_by` завжди був би `postgres`).

### Валідація (рівень 2)
- `customers`: непорожнє ім'я, формат email, формат телефону, дата реєстрації не з майбутнього;
- `products`: непорожня назва, ціна > 0, ціна не може зрости більш ніж утричі за одну зміну (захист від помилки в порядку).
Помилки — `RAISE EXCEPTION ... USING ERRCODE = 'check_violation', HINT = ...`, тому застосунок може відрізнити їх від інших.

Вивід `tests.sql` (розділи «логування», «валідація»): **⟨вставте / скріншот⟩**

## 6. Користувачі й права
### `report_viewer` (рівень 1)
`CONNECT`, `USAGE` на схему, `SELECT` на довідкові таблиці та звітні представлення; на `customers` — лише стовпці
`customer_id, contact_name, city, region_id, customer_type, registration_date` (email, телефон, адреса приховані);
`statement_timeout = 30s`, `CONNECTION LIMIT 5`. Таблиця `users` (хеші паролів) недоступна.
Перевірка (`SET ROLE report_viewer`): читання працює, `SELECT email`, `UPDATE`, `SELECT * FROM users` → `permission denied`. Вивід: **⟨вставте⟩**

### Ієрархія ролей (рівень 3)
| Роль | Успадковує | Права |
|---|---|---|
| `role_viewer` | — | `SELECT` на бізнес-таблиці й представлення; без журналів, `users`, сповіщень |
| `role_moderator` | viewer | `INSERT/UPDATE` на customers, products, orders, order_items; `DELETE` лише orders/order_items; читання `audit_log`/`activity_log`; `USAGE` на послідовності |
| `role_admin` | moderator | усі права на таблиці й послідовності, `EXECUTE` на функції, `pg_monitor`; не суперкористувач |

Користувачі-приклади: `lab5_viewer`, `lab5_moderator`, `lab5_admin` (навчальні паролі в скрипті **змініть**).
`ALTER DEFAULT PRIVILEGES` дає `role_viewer` читання нових таблиць.
Щоб модератор міг оформлювати замовлення, тригерні функції ЛР №4 (`fn_order_items_stock`, `fn_orders_cancel_restock`,
`fn_audit_row`, `log_activity`) переведено на `SECURITY DEFINER` з фіксованим `search_path` — без цього вставка в `order_items`
давала б `permission denied` на `products`/`activity_log`.

## 7. Часткові індекси (рівень 2)
| Індекс | Предикат | Запит |
|---|---|---|
| `idx_orders_open_date (order_date DESC)` | `order_status IN ('pending','processing')` | Q4 |
| `idx_customers_company_city (city)` | `customer_type = 'company'` | Q5 |

Предикати складаються лише з незмінних виразів (без `NOW()`/`CURRENT_DATE`). Порівняння розміру з повним індексом
(`index_sizes.txt`): **⟨вставте⟩**; час Q4/Q5 до/після: **⟨вставте⟩**.
Додатково `ux_restock_open_per_product` — частковий UNIQUE: лише одна відкрита заявка на поповнення на товар.

## 8. Рівень 3
### Матеріалізоване представлення
`mv_daily_sales` (виручка, кількість замовлень і товарів за день, без скасованих) з UNIQUE-індексом — він потрібен для
`REFRESH ... CONCURRENTLY`, що не блокує читання. Оновлюють statement-level тригери: на `order_items` (INSERT/UPDATE/DELETE) та
на `orders` (`UPDATE OF order_status, order_date`). Зміни, що не впливають на суми, оновлення не викликають.
**Обмеження:** повне оновлення після кожного оператора — навчальне рішення; для великих обсягів краще `pg_cron` або інкрементальна таблиця-підсумок.

### Каскадні тригери
1. `order_items` → `trg_cascade_items_loyalty` → перерахунок `customer_loyalty` (сума, кількість, рівень standard/silver/gold) →
   при зміні рівня `trg_loyalty_tier_notify` → запис у `customer_notifications` і `audit_log`. Також `orders.order_status` → перерахунок (скасування зменшує суму).
2. `order_items` → `trg_order_items_stock` (ЛР №4, зменшує залишок) → `trg_products_restock` → заявка в `restock_requests`,
   коли залишок ≤ `reorder_level`; дублікати відкритих заявок відсікає частковий UNIQUE-індекс (`ON CONFLICT DO NOTHING`).

Приклад ланцюга з `tests.sql`: **⟨вставте⟩**

### Процедура обслуговування
`maintain_database(p_reindex, p_dead_ratio)`: `ANALYZE` і `REINDEX` кожної таблиці `public` (з `COMMIT` після кожної, щоб не тримати блокування
всіх таблиць разом), `REFRESH MATERIALIZED VIEW CONCURRENTLY`, перевірка частки мертвих кортежів, журнал у `maintenance_log`.
`VACUUM` у процедурі виконати не можна (не працює в транзакції), тому його виконує autovacuum; процедура лише повідомляє, де він потрібен.
Виклик: `CALL maintain_database();` Вивід журналу: **⟨вставте⟩**

### Моніторинг
`08_monitor.sql`: кеш-хіт, найактивніші індекси, **невикористані індекси**, таблиці з перевагою Seq Scan, мертві кортежі, розміри,
довгі запити, **найповільніші запити з `pg_stat_statements`** (розширення підключено в `docker-compose.yml`). Вивід: `lab5_results/monitor_output.txt` — **⟨вставте⟩**

## 9. Резервне копіювання й відновлення
`scripts/backup_lab5.sh`: `pg_dump -F c -Z 6` (custom) і plain SQL; створення БД `technomart_restore`; `pg_restore --no-owner`;
порівняння кількості рядків у ключових таблицях (`diff`) та кількості тригерів, індексів, представлень, матеріалізованих представлень.
Вивід (має закінчитись рядком «OK: дані … збігаються»): **⟨вставте⟩**

## 10. Висновки
_(Заповніть після запуску: у скільки разів прискорилися Q1–Q5, які плани змінились, скільки місця займають індекси, що показав моніторинг.)_
Рекомендації: індексувати зовнішні ключі й поля фільтрації; використовувати часткові індекси для малих підмножин; регулярно виконувати
`ANALYZE`; періодично переглядати невикористані індекси; обмежувати `SECURITY DEFINER` фіксованим `search_path`; змінити всі навчальні паролі.

## Відповіді на контрольні запитання (стисло)
1. `EXPLAIN` показує план без виконання (оцінки), `EXPLAIN ANALYZE` виконує запит і додає фактичний час та кількість рядків; DML обгортають у `BEGIN … ROLLBACK`.
2. B-tree (порівняння, сортування), Hash (рівність), GIN (масиви, JSONB, повнотекст, trigram), GiST (геометрія, діапазони), BRIN (дуже великі впорядковані таблиці), SP-GiST.
3. Частковий індекс охоплює лише рядки за умовою; виграє, коли запитувана підмножина мала (відкриті замовлення, активні записи).
4. VIEW не зберігає дані й виконується щоразу; MATERIALIZED VIEW зберігає результат і потребує `REFRESH` — для важких агрегатів.
5. BEFORE може змінити/відхилити рядок, AFTER виконується після зміни, INSTEAD OF підміняє операцію над представленням.
6. Принцип мінімальних привілеїв; рівні: БД, схема, таблиця, стовпець, функція, послідовність (+ RLS на рівні рядків).
7. Логічне (`pg_dump`) — переносне, повільніше на великих БД; фізичне (`pg_basebackup`, копія файлів) — швидке, підтримує PITR, але прив'язане до версії/архітектури.
8. Каскадні тригери — коли один тригер своєю дією запускає інші (позиція → склад → заявка на поповнення).
9. Кожен індекс оновлюється при записі, тому INSERT/UPDATE/DELETE сповільнюються, а місце й обслуговування зростають.
10. PITR: базова фізична копія (`pg_basebackup`) + архів WAL (`archive_mode`, `archive_command`); при відновленні — `restore_command`, `recovery_target_time`, файл `recovery.signal`.

-- =============================================================
-- ArcLedger - Portfolio 2: indexes added for the six queries
-- Run AFTER the baseline run of 01_queries.sql:
--   mysql -u root -p arcledger < 02_create_indexes.sql
-- To repeat the experiment, remove them with 04_drop_indexes.sql.
-- =============================================================
USE arcledger;

-- Q1: equality on account_id, then range + ORDER BY on transaction_date.
--     Replaces the single-column FK index for this query: rows come out
--     of the index already in date order, so no sort is needed.
CREATE INDEX ix_txn_account_date ON transactions (account_id, transaction_date);

--     The single-column index on account_id is now REDUNDANT: the composite
--     index starts with account_id, so it serves the foreign key and any
--     account_id lookup. On a fresh database MySQL drops its automatic FK
--     index by itself; if it was created by hand (04_drop_indexes.sql) we
--     drop it here, so we don't pay for maintaining two indexes on every insert.
SET @has = (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = 'arcledger' AND TABLE_NAME = 'transactions' AND INDEX_NAME = 'fk_transactions_account');
SET @ddl = IF(@has > 0, 'DROP INDEX fk_transactions_account ON transactions',
                        'SELECT ''fk_transactions_account already removed by MySQL'' AS note');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Q2: range on transaction_date across all accounts.
CREATE INDEX ix_txn_date ON transactions (transaction_date);

-- Q3: equality on status FIRST, then the range on date.
--     Rule: equality columns before range columns. With (status, date)
--     MySQL jumps straight to FAILED rows in the date window.
CREATE INDEX ix_txn_status_date ON transactions (status, transaction_date);

-- Q4: COVERING index - holds every column the query needs (event, message),
--     so MySQL answers from the index alone and never reads the table rows.
CREATE INDEX ix_logs_event_message ON transaction_logs (event, message);

-- Q5: search by surname.
CREATE INDEX ix_customer_last_name ON customer (last_name);

-- Q6: no new index. The fix is rewriting OR as UNION ALL so each half can
--     use an index that already exists (ix_txn_account_date and the FK
--     index on transaction_transfer.destination_account_id).

ANALYZE TABLE customer, transactions, transaction_logs;

SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'arcledger' AND INDEX_NAME LIKE 'ix\_%'
GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME, INDEX_NAME;

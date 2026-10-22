-- =============================================================
-- ArcLedger - Portfolio 2: remove the added indexes
-- Use this to return to the baseline and repeat the experiment.
--   mysql -u root -p arcledger < 04_drop_indexes.sql
--
-- NOTE: when ix_txn_account_date (account_id, transaction_date) was
-- created, MySQL silently DROPPED its automatic foreign-key index
-- fk_transactions_account, because the new index also starts with
-- account_id and can serve the FK. So ix_txn_account_date cannot be
-- dropped until a plain account_id index exists again
-- (error 1553 "needed in a foreign key constraint").
-- =============================================================
USE arcledger;

-- Restore a plain account_id index for the FK first (only if it is missing)
SET @has = (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = 'arcledger' AND TABLE_NAME = 'transactions' AND INDEX_NAME = 'fk_transactions_account');
SET @ddl = IF(@has = 0, 'CREATE INDEX fk_transactions_account ON transactions (account_id)',
                        'SELECT ''fk_transactions_account already present'' AS note');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

DROP INDEX ix_txn_account_date   ON transactions;
DROP INDEX ix_txn_date           ON transactions;
DROP INDEX ix_txn_status_date    ON transactions;
DROP INDEX ix_logs_event_message ON transaction_logs;
DROP INDEX ix_customer_last_name ON customer;

ANALYZE TABLE customer, transactions, transaction_logs;

SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'arcledger' AND TABLE_NAME IN ('transactions', 'transaction_logs', 'customer')
GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME, INDEX_NAME;

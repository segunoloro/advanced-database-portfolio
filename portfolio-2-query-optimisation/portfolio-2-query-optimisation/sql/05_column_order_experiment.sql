-- =============================================================
-- ArcLedger - Portfolio 2: does column order in an index matter?
-- Q3 filters on status (equality) AND transaction_date (range).
-- Compare two composite indexes with the same columns, different order:
--   ix_txn_status_date (status, transaction_date)   <- created in 02
--   ix_txn_date_status (transaction_date, status)   <- created here, temporarily
-- FORCE INDEX makes MySQL use each one so the plans can be compared.
-- Run AFTER 02_create_indexes.sql:
--   mysql -u root -p -t arcledger < 05_column_order_experiment.sql > ../evidence/05_column_order_output.txt
-- =============================================================
USE arcledger;

CREATE INDEX ix_txn_date_status ON transactions (transaction_date, status);
ANALYZE TABLE transactions;

SELECT '==== A: (status, transaction_date) - equality column first ====' AS experiment;
EXPLAIN ANALYZE
SELECT transaction_id, amount FROM transactions FORCE INDEX (ix_txn_status_date)
WHERE status = 'FAILED' AND transaction_date >= '2026-10-09' AND transaction_date < '2026-10-17';

SELECT '==== B: (transaction_date, status) - range column first ====' AS experiment;
EXPLAIN ANALYZE
SELECT transaction_id, amount FROM transactions FORCE INDEX (ix_txn_date_status)
WHERE status = 'FAILED' AND transaction_date >= '2026-10-09' AND transaction_date < '2026-10-17';

-- How many index entries each version has to walk through
SELECT
  (SELECT COUNT(*) FROM transactions
   WHERE status = 'FAILED' AND transaction_date >= '2026-10-09' AND transaction_date < '2026-10-17') AS A_entries_read,
  (SELECT COUNT(*) FROM transactions
   WHERE transaction_date >= '2026-10-09' AND transaction_date < '2026-10-17') AS B_entries_read;

DROP INDEX ix_txn_date_status ON transactions;

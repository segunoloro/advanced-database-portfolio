-- =============================================================
-- ArcLedger - Portfolio 2: Query Processing and Optimisation
-- The SIX business queries, each with EXPLAIN and EXPLAIN ANALYZE.
--
-- This one file is run TWICE so the queries are identical:
--   BEFORE indexes:  mysql -u root -p -t arcledger < 01_queries.sql > ../evidence/01_baseline_output.txt
--   (then run 02_create_indexes.sql)
--   AFTER indexes:   mysql -u root -p -t arcledger < 01_queries.sql > ../evidence/03_optimised_output.txt
--
-- Data: Portfolio 1 schema + 03_bulk_seed.sql
--       (515,000 transactions, 1,030,000 log rows, 10,000 customers)
--
-- EXPLAIN          = the plan the optimiser CHOOSES (estimated)
-- EXPLAIN ANALYZE  = runs the query and shows ACTUAL rows and time per step
-- =============================================================
USE arcledger;

-- Fresh statistics so the optimiser's estimates are accurate
ANALYZE TABLE customer, account, transactions, transaction_transfer, transaction_logs;

-- Parameters used by the queries
SET @acct      = 1000;                      -- an account (ids 1..15000 exist)
SET @month_on  = '2026-08-01';
SET @month_off = '2026-09-01';
SET @day_on    = '2026-09-15';
SET @day_off   = '2026-09-16';
SET @week_on   = '2026-10-09';              -- "last 7 days" up to the end of the data
SET @week_off  = '2026-10-17';

SELECT 'Indexes on transactions now:' AS info;
SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'arcledger' AND TABLE_NAME IN ('transactions', 'transaction_logs', 'customer')
GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME, INDEX_NAME;


-- =============================================================
-- Q1  Account statement: one account, one month, newest first
--     Who: customer in the mobile app
-- =============================================================
SELECT '==== Q1 Account statement for one month ====' AS query;

SELECT transaction_date, transaction_ref, transaction_type, amount, status
FROM transactions
WHERE account_id = @acct
  AND transaction_date >= @month_on AND transaction_date < @month_off
ORDER BY transaction_date DESC;

EXPLAIN
SELECT transaction_date, transaction_ref, transaction_type, amount, status
FROM transactions
WHERE account_id = @acct
  AND transaction_date >= @month_on AND transaction_date < @month_off
ORDER BY transaction_date DESC;

EXPLAIN ANALYZE
SELECT transaction_date, transaction_ref, transaction_type, amount, status
FROM transactions
WHERE account_id = @acct
  AND transaction_date >= @month_on AND transaction_date < @month_off
ORDER BY transaction_date DESC;


-- =============================================================
-- Q2  Daily report: all transactions on one day, by type and status
--     Who: operations / finance
-- =============================================================
SELECT '==== Q2 Daily transaction report ====' AS query;

SELECT transaction_type, status, COUNT(*) AS txns, SUM(amount) AS total
FROM transactions
WHERE transaction_date >= @day_on AND transaction_date < @day_off
GROUP BY transaction_type, status
ORDER BY transaction_type, status;

EXPLAIN
SELECT transaction_type, status, COUNT(*) AS txns, SUM(amount) AS total
FROM transactions
WHERE transaction_date >= @day_on AND transaction_date < @day_off
GROUP BY transaction_type, status;

EXPLAIN ANALYZE
SELECT transaction_type, status, COUNT(*) AS txns, SUM(amount) AS total
FROM transactions
WHERE transaction_date >= @day_on AND transaction_date < @day_off
GROUP BY transaction_type, status;


-- =============================================================
-- Q3  Failed transactions in the last 7 days
--     Who: operations, investigating failures
-- =============================================================
SELECT '==== Q3 Failed transactions in the last 7 days ====' AS query;

SELECT COUNT(*) AS failed_last_7_days, SUM(amount) AS value
FROM transactions
WHERE status = 'FAILED'
  AND transaction_date >= @week_on AND transaction_date < @week_off;

EXPLAIN
SELECT transaction_id, transaction_ref, account_id, transaction_type, amount, transaction_date
FROM transactions
WHERE status = 'FAILED'
  AND transaction_date >= @week_on AND transaction_date < @week_off;

EXPLAIN ANALYZE
SELECT transaction_id, transaction_ref, account_id, transaction_type, amount, transaction_date
FROM transactions
WHERE status = 'FAILED'
  AND transaction_date >= @week_on AND transaction_date < @week_off;


-- =============================================================
-- Q4  Why do transactions fail? Count FAILED log events by reason
--     Who: operations / product team (1,030,000 log rows)
-- =============================================================
SELECT '==== Q4 Failure reasons from the event log ====' AS query;

SELECT message AS failure_reason, COUNT(*) AS events
FROM transaction_logs
WHERE event = 'FAILED'
GROUP BY message
ORDER BY events DESC;

EXPLAIN
SELECT message, COUNT(*) FROM transaction_logs
WHERE event = 'FAILED'
GROUP BY message;

EXPLAIN ANALYZE
SELECT message, COUNT(*) FROM transaction_logs
WHERE event = 'FAILED'
GROUP BY message;


-- =============================================================
-- Q5  Find a customer by surname
--     Who: customer service desk (10,000 customers - a SMALL table)
-- =============================================================
SELECT '==== Q5 Customer search by surname ====' AS query;

SELECT COUNT(*) AS customers_named_okafor FROM customer WHERE last_name = 'Okafor';

EXPLAIN
SELECT customer_id, first_name, last_name, phone FROM customer WHERE last_name = 'Okafor';

EXPLAIN ANALYZE
SELECT customer_id, first_name, last_name, phone FROM customer WHERE last_name = 'Okafor';


-- =============================================================
-- Q6  Full statement (money out AND money in) - query REWRITE
--     Version A uses OR; version B uses UNION ALL. Same result.
-- =============================================================
SELECT '==== Q6A Full statement using OR ====' AS query;

SELECT COUNT(*) AS rows_version_A FROM transactions t
WHERE t.account_id = @acct
   OR t.transaction_id IN (SELECT transaction_id FROM transaction_transfer
                           WHERE destination_account_id = @acct);

EXPLAIN ANALYZE
SELECT t.transaction_date, t.transaction_ref, t.transaction_type, t.amount
FROM transactions t
WHERE t.account_id = @acct
   OR t.transaction_id IN (SELECT transaction_id FROM transaction_transfer
                           WHERE destination_account_id = @acct)
ORDER BY t.transaction_date;

SELECT '==== Q6B Full statement using UNION ALL ====' AS query;

SELECT COUNT(*) AS rows_version_B FROM (
    SELECT t.transaction_id FROM transactions t WHERE t.account_id = @acct
    UNION ALL
    SELECT t.transaction_id FROM transaction_transfer tt
    JOIN transactions t ON t.transaction_id = tt.transaction_id
    WHERE tt.destination_account_id = @acct
) s;

EXPLAIN ANALYZE
SELECT * FROM (
    SELECT t.transaction_date, t.transaction_ref, t.transaction_type, t.amount
    FROM transactions t WHERE t.account_id = @acct
    UNION ALL
    SELECT t.transaction_date, t.transaction_ref, t.transaction_type, t.amount
    FROM transaction_transfer tt JOIN transactions t ON t.transaction_id = tt.transaction_id
    WHERE tt.destination_account_id = @acct
) s
ORDER BY transaction_date;

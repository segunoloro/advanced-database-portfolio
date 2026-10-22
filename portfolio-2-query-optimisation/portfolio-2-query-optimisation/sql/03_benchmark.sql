-- =============================================================
-- ArcLedger - Portfolio 2: timing benchmark
-- Runs each query 10 times and reports the AVERAGE time in ms.
-- One EXPLAIN ANALYZE run is noisy (cache warm/cold); an average is fairer.
-- Run it twice - once before 02_create_indexes.sql, once after:
--   mysql -u root -p -t arcledger < 03_benchmark.sql > ../evidence/03_benchmark_before.txt
--   mysql -u root -p -t arcledger < 03_benchmark.sql > ../evidence/03_benchmark_after.txt
-- =============================================================
USE arcledger;

DROP PROCEDURE IF EXISTS run_benchmark;
DELIMITER //
CREATE PROCEDURE run_benchmark(IN p_runs INT)
BEGIN
    DECLARE i INT;
    DECLARE t0 DATETIME(6);
    DECLARE v_acct INT DEFAULT 1000;

    DROP TEMPORARY TABLE IF EXISTS bench;
    CREATE TEMPORARY TABLE bench (query_id VARCHAR(4), description VARCHAR(60), avg_ms DECIMAL(10,3), result_rows INT);

    -- Q1 statement for one account, one month
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM (
            SELECT transaction_date FROM transactions
            WHERE account_id = v_acct AND transaction_date >= '2026-08-01' AND transaction_date < '2026-09-01'
            ORDER BY transaction_date DESC) q;
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q1', 'Account statement, one month',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    -- Q2 daily report
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM (
            SELECT transaction_type, status, COUNT(*), SUM(amount) FROM transactions
            WHERE transaction_date >= '2026-09-15' AND transaction_date < '2026-09-16'
            GROUP BY transaction_type, status) q;
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q2', 'Daily report, one day',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    -- Q3 failed in the last 7 days
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM (
            SELECT transaction_id, amount FROM transactions
            WHERE status = 'FAILED' AND transaction_date >= '2026-10-09' AND transaction_date < '2026-10-17') q;
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q3', 'Failed transactions, last 7 days',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    -- Q4 failure reasons from 1M log rows
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM (
            SELECT message, COUNT(*) FROM transaction_logs WHERE event = 'FAILED' GROUP BY message) q;
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q4', 'Failure reasons from event log',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    -- Q5 customer by surname
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM (
            SELECT customer_id, first_name, phone FROM customer WHERE last_name = 'Okafor') q;
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q5', 'Customer search by surname',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    -- Q6A full statement with OR
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM transactions t
        WHERE t.account_id = v_acct
           OR t.transaction_id IN (SELECT transaction_id FROM transaction_transfer WHERE destination_account_id = v_acct);
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q6A', 'Full statement using OR',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    -- Q6B full statement with UNION ALL
    SET i = 0; SET t0 = SYSDATE(6);
    WHILE i < p_runs DO
        SELECT COUNT(*) INTO @n FROM (
            SELECT t.transaction_id FROM transactions t WHERE t.account_id = v_acct
            UNION ALL
            SELECT tt.transaction_id FROM transaction_transfer tt
            JOIN transactions t ON t.transaction_id = tt.transaction_id
            WHERE tt.destination_account_id = v_acct) q;
        SET i = i + 1;
    END WHILE;
    INSERT INTO bench VALUES ('Q6B', 'Full statement using UNION ALL',
        TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000 / p_runs, @n);

    SELECT * FROM bench;
END//
DELIMITER ;

SELECT GROUP_CONCAT(DISTINCT INDEX_NAME ORDER BY INDEX_NAME) AS extra_indexes_present
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'arcledger' AND INDEX_NAME LIKE 'ix\_%';

CALL run_benchmark(1);    -- warm-up run (loads data into memory), not reported
CALL run_benchmark(10);   -- measured: average of 10 runs per query

DROP PROCEDURE run_benchmark;

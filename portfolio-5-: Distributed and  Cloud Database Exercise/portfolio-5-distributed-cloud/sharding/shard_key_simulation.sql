-- =============================================================
-- ArcLedger - Portfolio 5: SHARD KEY SIMULATION
-- Question: if ArcLedger's transactions were spread over 8 shards
-- (8 database servers), which column should decide where each row lives?
--
-- Nothing is moved: each transaction is only TAGGED with the shard it would
-- live on under three candidate shard keys, then we measure the effects.
--   1. hash_account   shard = CRC32(account_id) MOD 8        (hashed sharding)
--   2. range_account  account_id split into 8 equal ranges   (ranged sharding)
--   3. range_date     transaction date split into 8 ranges   (time-based sharding)
--
-- Run on the Portfolio 1 database (with 03_bulk_seed.sql data):
--   mysql -u root -p -t arcledger < shard_key_simulation.sql > ../evidence/09_shard_simulation_output.txt
-- (Workbench: run the whole file with the lightning bolt.)
-- =============================================================
USE arcledger;

SET @n_shards = 8;
SELECT MIN(account_id), MAX(account_id), MIN(DATE(transaction_date)), MAX(DATE(transaction_date))
  INTO @a0, @a1, @d0, @d1 FROM transactions;
SET @span_acc  = @a1 - @a0 + 1;
SET @span_days = DATEDIFF(@d1, @d0) + 1;

-- Test parameters
SET @busy_account = (SELECT account_id FROM transactions GROUP BY account_id ORDER BY COUNT(*) DESC LIMIT 1);
SET @one_day      = '2026-09-15';
-- "New writes" = the last 7 days of normal activity
SET @recent_to    = (SELECT MAX(d) FROM (SELECT DATE(transaction_date) d FROM transactions
                                         GROUP BY d HAVING COUNT(*) > 100) x);
SET @recent_from  = DATE_SUB(@recent_to, INTERVAL 6 DAY);

SELECT @n_shards AS shards, @a0 AS first_account, @a1 AS last_account, @d0 AS first_date, @d1 AS last_date,
       @busy_account AS busy_account, @one_day AS report_day, @recent_from AS new_writes_from, @recent_to AS new_writes_to;

-- -------------------------------------------------------------
-- Tag every transaction with its shard under each strategy
-- (and the shard of the DESTINATION account, for transfers)
-- -------------------------------------------------------------
-- (a normal table: MySQL cannot reference a TEMPORARY table twice in one query)
DROP TABLE IF EXISTS sharded;
CREATE TABLE sharded AS
SELECT t.transaction_id, t.account_id, tt.destination_account_id AS dest_id,
       DATE(t.transaction_date) AS txn_date,
       CRC32(t.account_id) MOD @n_shards                                                    AS hash_account,
       LEAST(@n_shards - 1, FLOOR((t.account_id - @a0) * @n_shards / @span_acc))            AS range_account,
       LEAST(@n_shards - 1, FLOOR(DATEDIFF(DATE(t.transaction_date), @d0) * @n_shards / @span_days)) AS range_date,
       CRC32(tt.destination_account_id) MOD @n_shards                                       AS dest_hash,
       LEAST(@n_shards - 1, FLOOR((tt.destination_account_id - @a0) * @n_shards / @span_acc)) AS dest_range
FROM transactions t
LEFT JOIN transaction_transfer tt ON tt.transaction_id = t.transaction_id;

-- -------------------------------------------------------------
-- 1. How evenly do rows spread? (rows on each of the 8 shards)
-- -------------------------------------------------------------
SELECT s.shard,
       MAX(CASE WHEN s.strategy = 'hash_account'  THEN s.n END)                                        AS hash_account,
       MAX(CASE WHEN s.strategy = 'range_account' THEN s.n END)                                        AS range_account,
       MAX(CASE WHEN s.strategy = 'range_date'    THEN s.n END)                                        AS range_date
FROM (SELECT 'hash_account'  AS strategy, hash_account  AS shard, COUNT(*) AS n FROM sharded GROUP BY hash_account
      UNION ALL SELECT 'range_account', range_account, COUNT(*) FROM sharded GROUP BY range_account
      UNION ALL SELECT 'range_date',    range_date,    COUNT(*) FROM sharded GROUP BY range_date) s
GROUP BY s.shard ORDER BY s.shard;

-- -------------------------------------------------------------
-- 2. Summary: balance, query routing, write hot spots, cross-shard transfers
-- -------------------------------------------------------------
DROP PROCEDURE IF EXISTS shard_summary;
DELIMITER //
CREATE PROCEDURE shard_summary()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE strat VARCHAR(20);
    DECLARE dest_col VARCHAR(20);
    DROP TEMPORARY TABLE IF EXISTS shard_result;
    CREATE TEMPORARY TABLE shard_result (
        strategy VARCHAR(20), min_rows_per_shard BIGINT, max_rows_per_shard BIGINT, skew_max_over_avg DECIMAL(6,2),
        shards_for_one_account_statement INT, shards_for_one_day_report INT,
        pct_new_writes_on_busiest_shard DECIMAL(5,1), pct_transfers_cross_shard VARCHAR(10));

    WHILE i < 3 DO
        SET strat    = ELT(i + 1, 'hash_account', 'range_account', 'range_date');
        SET dest_col = ELT(i + 1, 'dest_hash',    'dest_range',    NULL);
        SET @sql = CONCAT(
          'INSERT INTO shard_result SELECT ''', strat, ''', ',
          '(SELECT MIN(n) FROM (SELECT COUNT(*) n FROM sharded GROUP BY ', strat, ') x), ',
          '(SELECT MAX(n) FROM (SELECT COUNT(*) n FROM sharded GROUP BY ', strat, ') x), ',
          '(SELECT MAX(n) / AVG(n) FROM (SELECT COUNT(*) n FROM sharded GROUP BY ', strat, ') x), ',
          '(SELECT COUNT(DISTINCT ', strat, ') FROM sharded WHERE account_id = @busy_account), ',
          '(SELECT COUNT(DISTINCT ', strat, ') FROM sharded WHERE txn_date = @one_day), ',
          '(SELECT 100 * MAX(n) / SUM(n) FROM (SELECT COUNT(*) n FROM sharded ',
          '   WHERE txn_date BETWEEN @recent_from AND @recent_to GROUP BY ', strat, ') x), ',
          IF(dest_col IS NULL, '''n/a''',
             CONCAT('(SELECT CONCAT(ROUND(100 * SUM(', strat, ' <> ', dest_col, ') / COUNT(*), 1), ''%'') ',
                    'FROM sharded WHERE dest_id IS NOT NULL)')));
        PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        SET i = i + 1;
    END WHILE;
    SELECT * FROM shard_result;
END//
DELIMITER ;
CALL shard_summary();
DROP PROCEDURE shard_summary;

-- -------------------------------------------------------------
-- 3. Why date ranges are lopsided: transactions per date shard and the dates each covers
-- -------------------------------------------------------------
SELECT range_date AS date_shard, MIN(txn_date) AS from_date, MAX(txn_date) AS to_date, COUNT(*) AS transactions
FROM sharded GROUP BY range_date ORDER BY range_date;

DROP TABLE sharded;   -- clean up the working table

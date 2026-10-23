-- =============================================================
-- DEMO 6: CONCURRENCY PROBLEM - LOST UPDATE - SESSION 1
-- Two withdrawals from Alice at the same moment, done the naive way: read balance, calculate, write.
--
-- HOW TO RUN (MySQL Workbench):
--   * Open this file in the connection tab you are using as "Session 1".
--   * Session 2 must be a SEPARATE connection tab (open the connection a
--     second time), not just another query tab in the same connection.
--   * Run ONE step at a time, in step-number order, switching tabs when
--     the next step belongs to the other session: select the lines of the
--     step and press Ctrl+Shift+Enter (Execute selection).
-- =============================================================

-- STEP 1 (Session 1) ----------------------------------------
-- Reset (Alice = 100,000). Withdrawal 1 (N30,000) reads the balance
-- into the application.
USE arcledger;
CALL sp_reset_demo();
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
SELECT balance INTO @bal FROM account WHERE account_id = @A;
SELECT @bal AS balance_read_by_withdrawal_1;          -- 100,000


-- STEP 3 (Session 1) ----------------------------------------
-- Withdrawal 1 writes its result: 100,000 - 30,000 = 70,000, and
-- commits.
UPDATE account SET balance = @bal - 30000 WHERE account_id = @A;
COMMIT;


-- STEP 5 (Session 1) ----------------------------------------
-- Check: N80,000 was withdrawn in total, so Alice should have
-- 20,000. She has 50,000 - Withdrawal 1 was LOST. The bank paid out
-- N30,000 that the balance does not show.
SELECT balance AS alice_actual, 100000 - 30000 - 50000 AS alice_expected FROM account WHERE account_id = @A;


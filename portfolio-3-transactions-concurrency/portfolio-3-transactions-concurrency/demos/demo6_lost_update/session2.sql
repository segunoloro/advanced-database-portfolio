-- =============================================================
-- DEMO 6: CONCURRENCY PROBLEM - LOST UPDATE - SESSION 2
-- Two withdrawals from Alice at the same moment, done the naive way: read balance, calculate, write.
--
-- HOW TO RUN (MySQL Workbench):
--   * Open this file in the connection tab you are using as "Session 2".
--   * Session 1 must be a SEPARATE connection tab (open the connection a
--     second time), not just another query tab in the same connection.
--   * Run ONE step at a time, in step-number order, switching tabs when
--     the next step belongs to the other session: select the lines of the
--     step and press Ctrl+Shift+Enter (Execute selection).
-- =============================================================

-- STEP 2 (Session 2) ----------------------------------------
-- Withdrawal 2 (N50,000) reads the balance at the same moment - also
-- 100,000.
USE arcledger;
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
SELECT balance INTO @bal FROM account WHERE account_id = @A;
SELECT @bal AS balance_read_by_withdrawal_2;          -- 100,000


-- STEP 4 (Session 2) ----------------------------------------
-- Withdrawal 2 writes ITS result: 100,000 - 50,000 = 50,000,
-- overwriting Withdrawal 1's 70,000.
UPDATE account SET balance = @bal - 50000 WHERE account_id = @A;
COMMIT;


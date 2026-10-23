-- =============================================================
-- DEMO 7: CONTROL MECHANISM - PESSIMISTIC LOCKING (SELECT ... FOR UPDATE) - SESSION 2
-- The same two withdrawals as Demo 6, but each reads the balance WITH A LOCK.
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
-- Withdrawal 2 reads with a lock. It WAITS (Workbench keeps the
-- query running) because Session 1 holds the lock. Leave it running
-- and go to Session 1, step 3.
USE arcledger;
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
SELECT balance INTO @bal FROM account WHERE account_id = @A FOR UPDATE;   -- waits here
SELECT @bal AS balance_read_by_withdrawal_2;          -- 70,000 once Session 1 commits


-- STEP 4 (Session 2) ----------------------------------------
-- Withdrawal 2 now calculates from the CORRECT balance: 70,000 -
-- 50,000 = 20,000.
UPDATE account SET balance = @bal - 50000 WHERE account_id = @A;
COMMIT;


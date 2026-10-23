-- =============================================================
-- DEMO 7: CONTROL MECHANISM - PESSIMISTIC LOCKING (SELECT ... FOR UPDATE) - SESSION 1
-- The same two withdrawals as Demo 6, but each reads the balance WITH A LOCK.
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
-- Reset (Alice = 100,000). Withdrawal 1 reads AND LOCKS Alice's row.
USE arcledger;
CALL sp_reset_demo();
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
SELECT balance INTO @bal FROM account WHERE account_id = @A FOR UPDATE;
SELECT @bal AS balance_read_by_withdrawal_1;          -- 100,000, row now locked


-- STEP 3 (Session 1) ----------------------------------------
-- Withdrawal 1 writes 70,000 and COMMITS, releasing the lock. Switch
-- to Session 2: its step 2 finishes by itself and shows 70,000.
UPDATE account SET balance = @bal - 30000 WHERE account_id = @A;
COMMIT;


-- STEP 5 (Session 1) ----------------------------------------
-- Check: Alice has 20,000 = 100,000 - 30,000 - 50,000. Both
-- withdrawals counted, nothing lost.
SELECT balance AS alice_actual, 100000 - 30000 - 50000 AS alice_expected FROM account WHERE account_id = @A;


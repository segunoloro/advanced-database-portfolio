-- =============================================================
-- DEMO 4: ISOLATION - DIRTY READ - SESSION 1
-- Can one session see another session's UNCOMMITTED change? It depends on the isolation level.
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
-- Reset. Start a transaction and take N70,000 from Alice, but do NOT
-- commit.
USE arcledger;
CALL sp_reset_demo();
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
UPDATE account SET balance = balance - 70000 WHERE account_id = @A;
SELECT balance AS alice_balance_in_session1 FROM account WHERE account_id = @A;   -- 30,000 (uncommitted)


-- STEP 4 (Session 1) ----------------------------------------
-- Change of mind: ROLLBACK. The N30,000 balance never officially
-- existed - yet Session 2 saw it in step 2.
ROLLBACK;
SELECT balance AS alice_balance_final FROM account WHERE account_id = @A;          -- 100,000


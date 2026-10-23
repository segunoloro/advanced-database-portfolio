-- =============================================================
-- DEMO 8: DEADLOCK - and how consistent lock ordering prevents it - SESSION 1
-- Alice sends Bola N10,000 while Bola sends Alice N20,000, locking accounts in opposite order.
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
-- Part A. Reset. Transfer 1 (Alice -> Bola) debits Alice: this LOCKS
-- Alice's row.
USE arcledger;
CALL sp_reset_demo();
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
UPDATE account SET balance = balance - 10000 WHERE account_id = @A;


-- STEP 3 (Session 1) ----------------------------------------
-- Transfer 1 now credits Bola - but Bola's row is locked by Session
-- 2, so Session 1 WAITS. Leave it running and go to Session 2, step
-- 4.
UPDATE account SET balance = balance + 10000 WHERE account_id = @B;   -- waits


-- STEP 5 (Session 1) ----------------------------------------
-- Session 1's step 3 has completed: Session 2 was chosen as the
-- deadlock victim. Commit. Only Transfer 1 happened: Alice 90,000,
-- Bola 110,000. The application must retry Transfer 2.
COMMIT;
SELECT * FROM v_demo_balances;


-- STEP 7 (Session 1) ----------------------------------------
-- Part B - THE FIX. Reset. Both transfers lock the two accounts in
-- the SAME order (lowest account_id first), exactly as sp_transfer
-- does.
CALL sp_reset_demo();
START TRANSACTION;
SELECT account_id FROM account WHERE account_id IN (@A, @B) ORDER BY account_id FOR UPDATE;


-- STEP 9 (Session 1) ----------------------------------------
-- Transfer 1 completes and commits. Session 2's step 8 then finishes
-- by itself. No deadlock - the second transfer simply waited its
-- turn.
UPDATE account SET balance = balance - 10000 WHERE account_id = @A;
UPDATE account SET balance = balance + 10000 WHERE account_id = @B;
COMMIT;


-- STEP 11 (Session 1) ----------------------------------------
-- Both transfers succeeded: Alice 100,000 - 10,000 + 20,000 =
-- 110,000; Bola 100,000 + 10,000 - 20,000 = 90,000.
SELECT * FROM v_demo_balances;


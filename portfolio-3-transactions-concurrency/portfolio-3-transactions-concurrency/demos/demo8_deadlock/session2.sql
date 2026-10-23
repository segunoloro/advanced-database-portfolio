-- =============================================================
-- DEMO 8: DEADLOCK - and how consistent lock ordering prevents it - SESSION 2
-- Alice sends Bola N10,000 while Bola sends Alice N20,000, locking accounts in opposite order.
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
-- Transfer 2 (Bola -> Alice) debits Bola: this LOCKS Bola's row.
USE arcledger;
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
UPDATE account SET balance = balance - 20000 WHERE account_id = @B;


-- STEP 4 (Session 2) ----------------------------------------
-- Transfer 2 now credits Alice - but Alice is locked by Session 1,
-- which is waiting for Session 2. Neither can ever continue: a
-- DEADLOCK. MySQL detects it immediately and rolls this transaction
-- back. ERROR 1213 here is EXPECTED.
UPDATE account SET balance = balance + 20000 WHERE account_id = @A;


-- STEP 6 (Session 2) ----------------------------------------
-- Evidence: InnoDB's own deadlock report. In Workbench, right-click
-- the Status cell, choose Open Value in Viewer, and find 'LATEST
-- DETECTED DEADLOCK'.
SHOW ENGINE INNODB STATUS;


-- STEP 8 (Session 2) ----------------------------------------
-- Transfer 2 locks in the SAME order (lowest account_id first).
-- Alice's row is already locked by Session 1, so it WAITS - but
-- waiting is not a deadlock. Leave it running and go to Session 1,
-- step 9.
START TRANSACTION;
SELECT account_id FROM account WHERE account_id IN (@A, @B) ORDER BY account_id FOR UPDATE;   -- waits


-- STEP 10 (Session 2) ----------------------------------------
-- Transfer 2 now runs and commits.
UPDATE account SET balance = balance - 20000 WHERE account_id = @B;
UPDATE account SET balance = balance + 20000 WHERE account_id = @A;
COMMIT;


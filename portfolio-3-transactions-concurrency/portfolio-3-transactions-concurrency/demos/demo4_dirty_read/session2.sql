-- =============================================================
-- DEMO 4: ISOLATION - DIRTY READ - SESSION 2
-- Can one session see another session's UNCOMMITTED change? It depends on the isolation level.
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
-- READ UNCOMMITTED: Session 2 sees Session 1's uncommitted N30,000.
-- This is a DIRTY READ.
USE arcledger;
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT @@transaction_isolation AS level, balance AS alice_balance_seen FROM account WHERE account_id = @A;


-- STEP 3 (Session 2) ----------------------------------------
-- READ COMMITTED: the same read returns only committed data -
-- N100,000. No dirty read.
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT @@transaction_isolation AS level, balance AS alice_balance_seen FROM account WHERE account_id = @A;
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;   -- back to the MySQL default


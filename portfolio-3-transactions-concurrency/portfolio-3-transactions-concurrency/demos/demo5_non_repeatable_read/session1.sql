-- =============================================================
-- DEMO 5: ISOLATION - NON-REPEATABLE READ - SESSION 1
-- Inside ONE transaction, does reading the same balance twice give the same answer?
--
-- HOW TO RUN (MySQL Workbench):
--   * Open this file in the connection tab you are using as "Session 1".
--   * Session 2 must be a SEPARATE connection tab (open the connection a
--     second time), not just another query tab in the same connection.
--   * Run ONE step at a time, in step-number order, switching tabs when
--     the next step belongs to the other session: select the lines of the
--     step and press Ctrl+Shift+Enter (Execute selection).
-- =============================================================

-- STEP 2 (Session 1) ----------------------------------------
-- Alice sends Bola N25,000 and it COMMITS.
USE arcledger;
CALL sp_transfer('9000000001', '9000000002', 25000.00);


-- STEP 5 (Session 1) ----------------------------------------
-- Alice sends Bola N25,000 again (Session 2 reset the accounts) and
-- it COMMITS.
CALL sp_transfer('9000000001', '9000000002', 25000.00);


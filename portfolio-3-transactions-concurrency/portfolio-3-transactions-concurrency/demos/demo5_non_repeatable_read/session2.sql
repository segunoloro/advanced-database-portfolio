-- =============================================================
-- DEMO 5: ISOLATION - NON-REPEATABLE READ - SESSION 2
-- Inside ONE transaction, does reading the same balance twice give the same answer?
--
-- HOW TO RUN (MySQL Workbench):
--   * Open this file in the connection tab you are using as "Session 2".
--   * Session 1 must be a SEPARATE connection tab (open the connection a
--     second time), not just another query tab in the same connection.
--   * Run ONE step at a time, in step-number order, switching tabs when
--     the next step belongs to the other session: select the lines of the
--     step and press Ctrl+Shift+Enter (Execute selection).
-- =============================================================

-- STEP 1 (Session 2) ----------------------------------------
-- Part A - READ COMMITTED. Reset, start a transaction, read Alice's
-- balance: 100,000.
USE arcledger;
CALL sp_reset_demo();
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;
SELECT @@transaction_isolation AS level, balance AS first_read FROM account WHERE account_id = @A;


-- STEP 3 (Session 2) ----------------------------------------
-- Same transaction, same query: now 75,000. The value changed under
-- us - a NON-REPEATABLE READ.
SELECT balance AS second_read FROM account WHERE account_id = @A;
COMMIT;


-- STEP 4 (Session 2) ----------------------------------------
-- Part B - REPEATABLE READ (MySQL's default). Reset, start a
-- transaction, read: 100,000.
CALL sp_reset_demo();
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT @@transaction_isolation AS level, balance AS first_read FROM account WHERE account_id = @A;


-- STEP 6 (Session 2) ----------------------------------------
-- Same query: STILL 100,000, although Session 1 committed.
-- REPEATABLE READ gives the transaction a consistent snapshot. After
-- COMMIT a new read sees 75,000.
SELECT balance AS second_read_same_transaction FROM account WHERE account_id = @A;
COMMIT;
SELECT balance AS read_after_commit FROM account WHERE account_id = @A;


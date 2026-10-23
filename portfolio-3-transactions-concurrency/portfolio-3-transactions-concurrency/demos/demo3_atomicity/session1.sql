-- =============================================================
-- DEMO 3: ROLLBACK after a failure halfway - ATOMICITY - SESSION 1
-- A transfer done by hand: the debit succeeds, then the next step fails.
--
-- HOW TO RUN (MySQL Workbench):
--   * Open this file in the connection tab you are using as "Session 1".
--   * This demo needs only one session.
--   * Run ONE step at a time, in step-number order, switching tabs when
--     the next step belongs to the other session: select the lines of the
--     step and press Ctrl+Shift+Enter (Execute selection).
-- =============================================================

-- STEP 1 (Session 1) ----------------------------------------
-- Reset, then start a transaction, DEBIT Alice N40,000 and record
-- the transaction.
USE arcledger;
CALL sp_reset_demo();
SET @A = (SELECT account_id FROM account WHERE account_number = '9000000001');   -- Alice
SET @B = (SELECT account_id FROM account WHERE account_number = '9000000002');   -- Bola
START TRANSACTION;
UPDATE account SET balance = balance - 40000 WHERE account_id = @A;
INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
VALUES ('ATOMICDEMO0001', @A, 'TRANSFER', 40000, 'SUCCESSFUL');
SET @t = LAST_INSERT_ID();
SELECT * FROM v_demo_balances;   -- inside this transaction Alice already shows 60,000


-- STEP 2 (Session 1) ----------------------------------------
-- Now record the destination - but account_id 0 does not exist, so
-- the INSERT fails with a foreign key error (1452). A red error here
-- is EXPECTED.
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@t, 0);


-- STEP 3 (Session 1) ----------------------------------------
-- IMPORTANT: MySQL only undid the FAILED STATEMENT. The debit and
-- the transaction row from step 1 are still pending - Alice still
-- shows 60,000. The transaction is half done.
SELECT * FROM v_demo_balances;
SELECT COUNT(*) AS pending_transaction_rows FROM transactions WHERE transaction_ref = 'ATOMICDEMO0001';


-- STEP 4 (Session 1) ----------------------------------------
-- So the WHOLE transaction must be rolled back. Everything from step
-- 1 is undone: Alice is back to 100,000 and the transaction row is
-- gone. All or nothing.
ROLLBACK;
SELECT * FROM v_demo_balances;
SELECT COUNT(*) AS transaction_rows_after_rollback FROM transactions WHERE transaction_ref = 'ATOMICDEMO0001';


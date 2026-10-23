-- =============================================================
-- ArcLedger - Portfolio 3: the Portfolio 1 limitations, now enforced
-- In Portfolio 1 (04_constraint_tests.sql, L1 and L2) these two inserts
-- were ACCEPTED because a CHECK constraint cannot look at another table.
-- The trigger trg_transfer_rules now rejects both.
-- Both statements SHOULD FAIL. Run with --force:
--   mysql -u root -p --force -vvv arcledger < 03_trigger_tests.sql > ../evidence/03_trigger_tests_output.txt 2>&1
-- (In Workbench: run each statement separately with Ctrl+Enter.)
-- =============================================================
USE arcledger;
CALL sp_reset_demo();

SET @deposit = (SELECT MIN(t.transaction_id) FROM transactions t
                JOIN account a ON a.account_id = t.account_id
                WHERE a.account_number = '9000000001' AND t.transaction_type = 'DEPOSIT');
SET @alice   = (SELECT account_id FROM account WHERE account_number = '9000000001');
SET @bola    = (SELECT account_id FROM account WHERE account_number = '9000000002');

-- A transfer from Alice that we create by hand, to test rule 2
INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
VALUES ('TRIGGERTEST0001', @alice, 'TRANSFER', 100.00, 'FAILED');
SET @manual_transfer = LAST_INSERT_ID();

-- L1: transfer details attached to a DEPOSIT  -> must be rejected
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@deposit, @bola);

-- L2: a transfer back to the account it came from  -> must be rejected
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@manual_transfer, @alice);

-- Control: a valid transfer row IS accepted
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@manual_transfer, @bola);
SELECT 'valid transfer row accepted' AS control_test, COUNT(*) AS rows_found
FROM transaction_transfer WHERE transaction_id = @manual_transfer;

-- clean up
DELETE FROM transaction_transfer WHERE transaction_id = @manual_transfer;
DELETE FROM transactions WHERE transaction_id = @manual_transfer;

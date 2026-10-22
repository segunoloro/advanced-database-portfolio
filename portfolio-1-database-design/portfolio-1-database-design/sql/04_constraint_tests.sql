-- =============================================================
-- ArcLedger - Constraint tests (each T-statement SHOULD FAIL)
-- Works with EITHER data load (02_seed.sql or 03_bulk_seed.sql):
-- the values used are looked up from rows that already exist.
-- Run with --force so MySQL continues after each error:
--   mysql -u root -p --force -vvv arcledger < 04_constraint_tests.sql > ../evidence/04_constraint_tests_output.txt 2>&1
-- =============================================================
USE arcledger;

-- Pick real rows from whatever data is loaded --------------------
SET @cust      = (SELECT MIN(customer_id) FROM customer);
SET @bvn       = (SELECT bvn   FROM customer WHERE customer_id = @cust);
SET @phone     = (SELECT phone FROM customer WHERE customer_id = @cust);
SET @branch    = (SELECT MIN(branch_id) FROM branch);
SET @acct      = (SELECT MIN(account_id) FROM account WHERE customer_id = @cust);
SET @acct_no   = (SELECT account_number FROM account WHERE account_id = @acct);
SET @deposit   = (SELECT MIN(transaction_id) FROM transactions WHERE transaction_type = 'DEPOSIT');
SET @withdraw  = (SELECT MIN(transaction_id) FROM transactions WHERE transaction_type = 'WITHDRAWAL');
SET @wd_acct   = (SELECT account_id FROM transactions WHERE transaction_id = @withdraw);
SET @transfer  = (SELECT MIN(transaction_id) FROM transaction_transfer);
SET @trf_ref   = (SELECT transaction_ref FROM transactions WHERE transaction_id = @transfer);
SET @other_acc = (SELECT MIN(account_id) FROM account WHERE account_id <> @acct);
SET @missing   = 0;    -- no row has id 0 (AUTO_INCREMENT starts at 1)

SELECT @cust AS customer_used, @bvn AS bvn_used, @acct_no AS account_used,
       @deposit AS deposit_txn, @withdraw AS withdrawal_txn, @transfer AS transfer_txn, @trf_ref AS transfer_ref;

-- T01 PRIMARY KEY: duplicate branch_id
INSERT INTO branch (branch_id, branch_name, city, state) VALUES (@branch, 'Duplicate', 'Ikeja', 'Lagos');

-- T02 UNIQUE: a second customer with an existing BVN
INSERT INTO customer (first_name, last_name, bvn, phone, date_of_birth)
VALUES ('Fake', 'Person', @bvn, '+2340000000001', '1990-01-01');

-- T03 UNIQUE: a second customer with an existing phone number
INSERT INTO customer (first_name, last_name, bvn, phone, date_of_birth)
VALUES ('Fake', 'Person', '99999999999', @phone, '1990-01-01');

-- T04 CHECK: BVN must be exactly 11 digits
INSERT INTO customer (first_name, last_name, bvn, phone, date_of_birth)
VALUES ('Bad', 'Bvn', '22100A', '+2340000000002', '1990-01-01');

-- T05 NOT NULL: customer without a phone number
INSERT INTO customer (first_name, last_name, bvn, phone, date_of_birth)
VALUES ('No', 'Phone', '99999999998', NULL, '1990-01-01');

-- T06 FOREIGN KEY: account for a customer that does not exist
INSERT INTO account (account_number, customer_id, branch_id, account_type, opened_date)
VALUES ('9999999999', @missing, @branch, 'SAVINGS', '2026-10-01');

-- T07 FOREIGN KEY: account at a branch that does not exist
INSERT INTO account (account_number, customer_id, branch_id, account_type, opened_date)
VALUES ('9999999999', @cust, @missing, 'SAVINGS', '2026-10-01');

-- T08 FOREIGN KEY: cannot delete a customer who still owns accounts
DELETE FROM customer WHERE customer_id = @cust;

-- T09 UNIQUE: duplicate account number
INSERT INTO account (account_number, customer_id, branch_id, account_type, opened_date)
VALUES (@acct_no, @cust, @branch, 'SAVINGS', '2026-10-01');

-- T10 CHECK: account number must be exactly 10 digits
INSERT INTO account (account_number, customer_id, branch_id, account_type, opened_date)
VALUES ('12345', @cust, @branch, 'SAVINGS', '2026-10-01');

-- T11 CHECK: balance cannot go negative
UPDATE account SET balance = -1.00 WHERE account_id = @acct;

-- T12 ENUM: account type outside the allowed list
INSERT INTO account (account_number, customer_id, branch_id, account_type, opened_date)
VALUES ('9999999998', @cust, @branch, 'CRYPTO', '2026-10-01');

-- T13 CHECK: transaction amount must be positive
INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
VALUES ('TEST0013', @acct, 'DEPOSIT', -500.00, 'SUCCESSFUL');

-- T14 UNIQUE: reused transaction reference (stops a retried request posting twice)
INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
VALUES (@trf_ref, @acct, 'TRANSFER', 100.00, 'SUCCESSFUL');

-- T15 FOREIGN KEY: transaction on an account that does not exist
INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
VALUES ('TEST0015', @missing, 'DEPOSIT', 100.00, 'SUCCESSFUL');

-- T16 PRIMARY KEY (1:1): a second transfer row for the same transaction
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@transfer, @other_acc);

-- T17 FOREIGN KEY: transfer to a destination account that does not exist
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@withdraw, @missing);

-- T18 FOREIGN KEY: log entry for a transaction that does not exist
INSERT INTO transaction_logs (transaction_id, event, message) VALUES (@missing, 'INITIATED', 'orphan');

-- T19 ENUM: log event outside the allowed list
INSERT INTO transaction_logs (transaction_id, event, message) VALUES (@deposit, 'APPROVED', 'bad event');

-- -------------------------------------------------------------
-- KNOWN LIMITATIONS: these SHOULD fail but are ACCEPTED, because
-- each rule needs data from another table, which a CHECK cannot see.
-- (To be enforced by triggers / the transfer procedure in Portfolio 3.)
-- They are removed again straight away.
-- -------------------------------------------------------------
-- L1: transfer details attached to a DEPOSIT
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@deposit, @other_acc);
-- L2: a "transfer" back to the same account the money came from
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (@withdraw, @wd_acct);
SELECT 'L1 and L2 were accepted - see limitations in normalisation.md' AS note;
DELETE FROM transaction_transfer WHERE transaction_id IN (@deposit, @withdraw);

-- Final check: no test row was left behind
SELECT (SELECT COUNT(*) FROM customer WHERE bvn IN ('99999999999', '99999999998', '22100A')) AS test_customers,
       (SELECT COUNT(*) FROM account WHERE account_number IN ('9999999999', '9999999998', '12345')) AS test_accounts,
       (SELECT COUNT(*) FROM transactions WHERE transaction_ref LIKE 'TEST%') AS test_transactions,
       (SELECT COUNT(*) FROM transaction_transfer WHERE transaction_id IN (@deposit, @withdraw)) AS test_transfers,
       (SELECT COUNT(*) FROM account WHERE balance < 0) AS negative_balances;

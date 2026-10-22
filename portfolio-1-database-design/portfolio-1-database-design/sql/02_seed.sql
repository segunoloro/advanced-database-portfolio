-- =============================================================
-- ArcLedger Digital Bank - Sample data
-- MIT 8103 Portfolio 1
-- Run AFTER 01_schema.sql. All names, BVNs and numbers are fictitious.
--
-- Load order follows the foreign keys (parents before children):
--   1. branch, customer          (no FKs)
--   2. account                   (needs customer, branch)
--   3. transactions              (needs account)
--   4. transaction_transfer      (needs transactions, account)
--   5. transaction_logs          (needs transactions)
--   6. recalculate account.balance from the transactions
-- =============================================================
USE arcledger;

-- 1a. Branches ------------------------------------------------
INSERT INTO branch (branch_name, city, state) VALUES
 ('Ikeja Allen Avenue', 'Ikeja', 'Lagos'),     -- branch_id 1
 ('Victoria Island',    'Lagos', 'Lagos'),     -- branch_id 2
 ('Abuja Wuse II',      'Abuja', 'FCT');       -- branch_id 3

-- 1b. Customers -----------------------------------------------
INSERT INTO customer (first_name, last_name, bvn, phone, email, date_of_birth) VALUES
 ('Adaeze',  'Nwosu',    '22100000001', '+2348030000001', 'adaeze.nwosu@mail.example',  '1990-04-12'),  -- 1
 ('Tunde',   'Afolabi',  '22100000002', '+2348030000002', 'tunde.afolabi@mail.example', '1985-11-30'),  -- 2
 ('Ibrahim', 'Bello',    '22100000003', '+2348030000003', NULL,                         '1998-01-22'),  -- 3
 ('Chioma',  'Okeke',    '22100000004', '+2348030000004', 'chioma.okeke@mail.example',  '1993-07-08'),  -- 4
 ('Bayo',    'Ogunleye', '22100000005', '+2348030000005', NULL,                         '1979-02-14');  -- 5

-- 2. Accounts -------------------------------------------------
-- Balances start at 0; step 6 calculates them from the transactions.
INSERT INTO account (account_number, customer_id, branch_id, account_type, opened_date) VALUES
 ('0123456781', 1, 1, 'SAVINGS', '2026-01-15'),  -- 1 Adaeze
 ('0123456782', 1, 1, 'CURRENT', '2026-03-02'),  -- 2 Adaeze (second account: 1 customer -> many accounts)
 ('0123456783', 2, 2, 'CURRENT', '2026-02-10'),  -- 3 Tunde
 ('0123456784', 3, 3, 'SAVINGS', '2026-05-20'),  -- 4 Ibrahim
 ('0123456785', 4, 1, 'SAVINGS', '2026-06-01'),  -- 5 Chioma
 ('0123456786', 5, 2, 'CURRENT', '2026-07-07');  -- 6 Bayo

-- 3. Transactions ---------------------------------------------
-- account_id = account credited (DEPOSIT) or debited (WITHDRAWAL, TRANSFER)
INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status, transaction_date) VALUES
 ('TXN20261001001', 1, 'DEPOSIT',    500000.00, 'SUCCESSFUL', '2026-10-01 09:15:00'),  -- 1
 ('TXN20261001002', 3, 'DEPOSIT',    250000.00, 'SUCCESSFUL', '2026-10-01 10:02:00'),  -- 2
 ('TXN20261001003', 4, 'DEPOSIT',     40000.00, 'SUCCESSFUL', '2026-10-01 11:30:00'),  -- 3
 ('TXN20261001004', 5, 'DEPOSIT',     80000.00, 'SUCCESSFUL', '2026-10-01 12:45:00'),  -- 4
 ('TXN20261001005', 6, 'DEPOSIT',   1200000.00, 'SUCCESSFUL', '2026-10-01 14:00:00'),  -- 5
 ('TXN20261002006', 1, 'TRANSFER',    75000.00, 'SUCCESSFUL', '2026-10-02 08:20:00'),  -- 6 Adaeze -> Tunde
 ('TXN20261002007', 1, 'TRANSFER',   100000.00, 'SUCCESSFUL', '2026-10-02 08:25:00'),  -- 7 Adaeze savings -> her current
 ('TXN20261002008', 3, 'WITHDRAWAL',  20000.00, 'SUCCESSFUL', '2026-10-02 17:40:00'),  -- 8 Tunde ATM
 ('TXN20261003009', 4, 'TRANSFER',    60000.00, 'FAILED',     '2026-10-03 13:05:00'),  -- 9 Ibrahim: insufficient funds
 ('TXN20261003010', 6, 'TRANSFER',   150000.00, 'SUCCESSFUL', '2026-10-03 15:10:00'),  -- 10 Bayo -> Chioma
 ('TXN20261004011', 5, 'WITHDRAWAL',  30000.00, 'SUCCESSFUL', '2026-10-04 09:00:00');  -- 11 Chioma branch withdrawal

-- 4. Transfer details (one row per TRANSFER transaction) -------
INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES
 (6,  3),   -- Adaeze -> Tunde
 (7,  2),   -- Adaeze savings -> Adaeze current
 (9,  5),   -- Ibrahim -> Chioma (failed)
 (10, 5);   -- Bayo -> Chioma

-- 5. Logs: every transaction gets an INITIATED event, then its outcome
INSERT INTO transaction_logs (transaction_id, event, message, log_time)
SELECT transaction_id, 'INITIATED', CONCAT(transaction_type, ' request received'), transaction_date
FROM transactions;

INSERT INTO transaction_logs (transaction_id, event, message, log_time)
SELECT transaction_id,
       status,
       CASE WHEN status = 'FAILED' THEN 'Insufficient funds' ELSE 'Completed' END,
       transaction_date + INTERVAL 2 SECOND
FROM transactions;

-- 6. Balances = what the successful transactions add up to -----
--    + deposits and incoming transfers, - withdrawals and outgoing transfers
UPDATE account a
SET a.balance =
      COALESCE((SELECT SUM(CASE WHEN t.transaction_type = 'DEPOSIT' THEN t.amount ELSE -t.amount END)
                FROM transactions t
                WHERE t.account_id = a.account_id AND t.status = 'SUCCESSFUL'), 0)
    + COALESCE((SELECT SUM(t.amount)
                FROM transactions t
                JOIN transaction_transfer tt ON tt.transaction_id = t.transaction_id
                WHERE tt.destination_account_id = a.account_id AND t.status = 'SUCCESSFUL'), 0);

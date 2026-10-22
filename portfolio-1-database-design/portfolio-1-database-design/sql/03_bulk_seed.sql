-- =============================================================
-- ArcLedger Digital Bank - Bulk data generator
-- MIT 8103 Portfolio 1 (data volume needed for Portfolio 2)
--
-- Run AFTER 01_schema.sql (and optionally 02_seed.sql - it adds on top).
-- Pure SQL, no extra tools. All constraints stay ON, so every generated
-- row is proven to satisfy the schema.
--
-- Default volume (about 1-3 minutes on a laptop):
--   20 branches, 10,000 customers, 15,000 accounts,
--   ~515,000 transactions, ~150,000 transfers, ~1,030,000 logs
-- Change the four numbers below to scale up or down.
-- Keep @n_txns / @n_accounts <= 40 so no account is overdrawn.
-- =============================================================
USE arcledger;

SET @n_branches  = 20;
SET @n_customers = 10000;
SET @n_accounts  = 15000;
SET @n_txns      = 500000;

-- Start after whatever is already loaded, so this can run on top of 02_seed.sql
SET @b0 = (SELECT COALESCE(MAX(branch_id), 0)      FROM branch);
SET @c0 = (SELECT COALESCE(MAX(customer_id), 0)    FROM customer);
SET @a0 = (SELECT COALESCE(MAX(account_id), 0)     FROM account);
SET @t0 = (SELECT COALESCE(MAX(transaction_id), 0) FROM transactions);

-- -------------------------------------------------------------
-- Helper: a numbers table 1 .. 1,000,000 (dropped at the end)
-- -------------------------------------------------------------
DROP TABLE IF EXISTS seq;
CREATE TABLE seq (n INT NOT NULL PRIMARY KEY);
INSERT INTO seq (n)
SELECT 1 + d1.d + d2.d*10 + d3.d*100 + d4.d*1000 + d5.d*10000 + d6.d*100000
FROM (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
      UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d1,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
      UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d2,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
      UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d3,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
      UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d4,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
      UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d5,
     (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
      UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d6;

-- -------------------------------------------------------------
-- 1. Branches
-- -------------------------------------------------------------
INSERT INTO branch (branch_id, branch_name, city, state)
SELECT @b0 + n,
       CONCAT(ELT(1 + MOD(n, 6), 'Lagos', 'Abuja', 'Port Harcourt', 'Ibadan', 'Kano', 'Enugu'),
              ' Branch ', LPAD(n, 3, '0')),
       ELT(1 + MOD(n, 6), 'Lagos', 'Abuja', 'Port Harcourt', 'Ibadan', 'Kano', 'Enugu'),
       ELT(1 + MOD(n, 6), 'Lagos', 'FCT',   'Rivers',        'Oyo',    'Kano', 'Enugu')
FROM seq WHERE n <= @n_branches;

-- -------------------------------------------------------------
-- 2. Customers  (BVNs start with 23, phones with +234807, so they
--    never clash with the hand-written seed data)
-- -------------------------------------------------------------
INSERT INTO customer (customer_id, first_name, last_name, bvn, phone, email, date_of_birth)
SELECT @c0 + n,
       ELT(1 + FLOOR(RAND() * 15), 'Adaeze','Tunde','Ibrahim','Chioma','Bayo','Ngozi','Emeka',
           'Fatima','Segun','Aisha','Kunle','Amaka','Musa','Funmi','Obinna'),
       ELT(1 + FLOOR(RAND() * 15), 'Nwosu','Afolabi','Bello','Okeke','Ogunleye','Eze','Okafor',
           'Abubakar','Lawal','Mohammed','Adeyemi','Obi','Danjuma','Balogun','Uche'),
       CONCAT('23', LPAD(n, 9, '0')),
       CONCAT('+234807', LPAD(n, 7, '0')),
       IF(RAND() < 0.8, CONCAT('customer', n, '@mail.example'), NULL),   -- ~20% have no email
       DATE('1960-01-01') + INTERVAL FLOOR(RAND() * 15000) DAY             -- born 1960-2001
FROM seq WHERE n <= @n_customers;

-- -------------------------------------------------------------
-- 3. Accounts: the first @n_customers accounts give every customer one
--    account; the rest go to customers again, so many have 2 (1:N).
--    All opened before 2026-07-01.
-- -------------------------------------------------------------
INSERT INTO account (account_id, account_number, customer_id, branch_id, account_type, opened_date)
SELECT @a0 + n,
       CONCAT('1', LPAD(n, 9, '0')),
       @c0 + 1 + MOD(n - 1, @n_customers),
       1 + FLOOR(RAND() * (@b0 + @n_branches)),
       IF(RAND() < 0.7, 'SAVINGS', 'CURRENT'),
       DATE('2023-01-01') + INTERVAL FLOOR(RAND() * 1277) DAY
FROM seq WHERE n <= @n_accounts;

-- -------------------------------------------------------------
-- 4a. Opening deposit for every new account (N1,000,000 - N5,000,000),
--     dated on the day the account was opened.
-- -------------------------------------------------------------
INSERT INTO transactions (transaction_id, transaction_ref, account_id, transaction_type, amount, status, transaction_date)
SELECT @t0 + n,
       CONCAT('BLK', LPAD(n, 12, '0')),
       a.account_id,
       'DEPOSIT',
       ROUND(1000000 + RAND() * 4000000, 2),
       'SUCCESSFUL',
       TIMESTAMP(a.opened_date, '09:00:00')
FROM seq
JOIN account a ON a.account_id = @a0 + seq.n
WHERE seq.n <= @n_accounts;

-- -------------------------------------------------------------
-- 4b. Day-to-day transactions between 2026-07-01 and 2026-10-16
--     Mix: 30% deposits, 25% withdrawals, 45% transfers; ~3% fail.
--     Deposits N1,000 - N200,000; withdrawals/transfers N100 - N10,000.
--     The type comes from MOD(n, 20), not RAND(): MySQL can evaluate
--     RAND() more than once per row, which would give a WITHDRAWAL a
--     deposit-sized amount.
-- -------------------------------------------------------------
INSERT INTO transactions (transaction_id, transaction_ref, account_id, transaction_type, amount, status, transaction_date)
SELECT @t0 + @n_accounts + n,
       CONCAT('BLK', LPAD(@n_accounts + n, 12, '0')),
       @a0 + 1 + FLOOR(RAND() * @n_accounts),
       CASE WHEN MOD(n, 20) < 6  THEN 'DEPOSIT'        -- 6/20 = 30%
            WHEN MOD(n, 20) < 11 THEN 'WITHDRAWAL'     -- 5/20 = 25%
            ELSE 'TRANSFER' END,                       -- 9/20 = 45%
       IF(MOD(n, 20) < 6, ROUND(1000 + RAND() * 199000, 2), ROUND(100 + RAND() * 9900, 2)),
       IF(RAND() < 0.03, 'FAILED', 'SUCCESSFUL'),
       TIMESTAMP('2026-07-01') + INTERVAL FLOOR(RAND() * 108 * 86400) SECOND
FROM seq
WHERE n <= @n_txns;

-- -------------------------------------------------------------
-- 5. Transfer details: destination is a random account that is never
--    the source account.  MOD(src - 1 + k, N) + 1 with k in 1..N-1
-- -------------------------------------------------------------
INSERT INTO transaction_transfer (transaction_id, destination_account_id)
SELECT t.transaction_id,
       @a0 + 1 + MOD(t.account_id - @a0 - 1 + 1 + FLOOR(RAND() * (@n_accounts - 1)), @n_accounts)
FROM transactions t
WHERE t.transaction_type = 'TRANSFER'
  AND t.transaction_id > @t0;

-- -------------------------------------------------------------
-- 6. Logs: INITIATED + outcome for every new transaction
-- -------------------------------------------------------------
INSERT INTO transaction_logs (transaction_id, event, message, log_time)
SELECT transaction_id, 'INITIATED', CONCAT(transaction_type, ' request received'), transaction_date
FROM transactions WHERE transaction_id > @t0;

INSERT INTO transaction_logs (transaction_id, event, message, log_time)
SELECT transaction_id, status,
       IF(status = 'FAILED',
          ELT(1 + FLOOR(RAND() * 3), 'Insufficient funds', 'Daily limit exceeded', 'Network timeout'),
          'Completed'),
       transaction_date + INTERVAL 2 SECOND
FROM transactions WHERE transaction_id > @t0;

-- -------------------------------------------------------------
-- 7. Recalculate every balance from its successful transactions
--    (same rule as 02_seed.sql: + deposits & incoming transfers,
--     - withdrawals & outgoing transfers)
-- -------------------------------------------------------------
UPDATE account a
LEFT JOIN (
    SELECT account_id,
           SUM(CASE WHEN transaction_type = 'DEPOSIT' THEN amount ELSE -amount END) AS own_net
    FROM transactions
    WHERE status = 'SUCCESSFUL'
    GROUP BY account_id
) o ON o.account_id = a.account_id
LEFT JOIN (
    SELECT tt.destination_account_id AS account_id, SUM(t.amount) AS incoming
    FROM transaction_transfer tt
    JOIN transactions t ON t.transaction_id = tt.transaction_id
    WHERE t.status = 'SUCCESSFUL'
    GROUP BY tt.destination_account_id
) i ON i.account_id = a.account_id
SET a.balance = COALESCE(o.own_net, 0) + COALESCE(i.incoming, 0);

DROP TABLE seq;

-- -------------------------------------------------------------
-- Summary
-- -------------------------------------------------------------
SELECT 'branch' AS table_name, COUNT(*) AS row_count FROM branch
UNION ALL SELECT 'customer',             COUNT(*) FROM customer
UNION ALL SELECT 'account',              COUNT(*) FROM account
UNION ALL SELECT 'transactions',         COUNT(*) FROM transactions
UNION ALL SELECT 'transaction_transfer', COUNT(*) FROM transaction_transfer
UNION ALL SELECT 'transaction_logs',     COUNT(*) FROM transaction_logs;

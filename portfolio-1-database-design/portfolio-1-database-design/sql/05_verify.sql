-- =============================================================
-- ArcLedger - Verification queries (each SHOULD succeed)
-- Works with EITHER data load (02_seed.sql or 03_bulk_seed.sql).
-- Proves the design answers the bank's key questions and that
-- stored balances agree with the transactions.
--   mysql -u root -p -t arcledger < 05_verify.sql > ../evidence/05_verify_output.txt
-- =============================================================
USE arcledger;

-- V1 Row counts
SELECT 'branch' AS table_name, COUNT(*) AS row_count FROM branch
UNION ALL SELECT 'customer',             COUNT(*) FROM customer
UNION ALL SELECT 'account',              COUNT(*) FROM account
UNION ALL SELECT 'transactions',         COUNT(*) FROM transactions
UNION ALL SELECT 'transaction_transfer', COUNT(*) FROM transaction_transfer
UNION ALL SELECT 'transaction_logs',     COUNT(*) FROM transaction_logs;

-- V2 1:N in action: customers who own more than one account
SELECT c.customer_id, c.first_name, c.last_name, a.account_number, a.account_type, b.branch_name, a.balance
FROM customer c
JOIN account a ON a.customer_id = c.customer_id
JOIN branch  b ON b.branch_id   = a.branch_id
WHERE c.customer_id IN (SELECT customer_id FROM (
          SELECT customer_id FROM account GROUP BY customer_id HAVING COUNT(*) > 1
          ORDER BY customer_id LIMIT 3) x)
ORDER BY c.customer_id, a.account_number;

-- V3 Account statement (money out AND money in) for an account that has received a transfer
SET @acct = (SELECT destination_account_id FROM transaction_transfer ORDER BY transaction_id LIMIT 1);
SELECT @acct AS statement_for_account_id, (SELECT account_number FROM account WHERE account_id = @acct) AS account_number;
SELECT * FROM (
    -- money in or out on this account (deposits, withdrawals, transfers sent)
    SELECT t.transaction_date, t.transaction_ref, t.transaction_type,
           IF(t.transaction_type = 'DEPOSIT', 'CREDIT', 'DEBIT') AS direction, t.amount, t.status
    FROM transactions t WHERE t.account_id = @acct
    UNION ALL
    -- transfers received by this account
    SELECT t.transaction_date, t.transaction_ref, t.transaction_type, 'CREDIT', t.amount, t.status
    FROM transaction_transfer tt JOIN transactions t ON t.transaction_id = tt.transaction_id
    WHERE tt.destination_account_id = @acct
) s
ORDER BY transaction_date
LIMIT 15;

-- V4 Transfers with sender and receiver (supertype + subtype join)
SELECT t.transaction_ref, src.account_number AS from_account, dst.account_number AS to_account,
       t.amount, t.status
FROM transactions t
JOIN transaction_transfer tt ON tt.transaction_id = t.transaction_id
JOIN account src ON src.account_id = t.account_id
JOIN account dst ON dst.account_id = tt.destination_account_id
ORDER BY t.transaction_id
LIMIT 10;

-- V5 Full event history of a failed transfer
SET @failed = (SELECT MIN(transaction_id) FROM transactions WHERE transaction_type = 'TRANSFER' AND status = 'FAILED');
SELECT t.transaction_ref, t.status, l.event, l.message, l.log_time
FROM transactions t
JOIN transaction_logs l ON l.transaction_id = t.transaction_id
WHERE t.transaction_id = @failed
ORDER BY l.log_id;

-- V6 Every TRANSFER has exactly one transfer row, and no other type has one
SELECT t.transaction_type,
       COUNT(*)                 AS transactions,
       COUNT(tt.transaction_id) AS with_transfer_row
FROM transactions t
LEFT JOIN transaction_transfer tt ON tt.transaction_id = t.transaction_id
GROUP BY t.transaction_type
ORDER BY t.transaction_type;

-- V7 Reconciliation over ALL accounts: stored balance = balance rebuilt from successful transactions
WITH rebuilt AS (
    SELECT a.account_id, a.account_number, a.balance AS stored_balance,
           COALESCE(o.own_net, 0) + COALESCE(i.incoming, 0) AS from_transactions
    FROM account a
    LEFT JOIN (SELECT account_id,
                      SUM(CASE WHEN transaction_type = 'DEPOSIT' THEN amount ELSE -amount END) AS own_net
               FROM transactions WHERE status = 'SUCCESSFUL' GROUP BY account_id) o ON o.account_id = a.account_id
    LEFT JOIN (SELECT tt.destination_account_id AS account_id, SUM(t.amount) AS incoming
               FROM transaction_transfer tt JOIN transactions t ON t.transaction_id = tt.transaction_id
               WHERE t.status = 'SUCCESSFUL' GROUP BY tt.destination_account_id) i ON i.account_id = a.account_id
)
SELECT IF(stored_balance = from_transactions, 'OK', 'MISMATCH') AS result,
       COUNT(*) AS accounts
FROM rebuilt
GROUP BY result;

-- V8 Data dictionary: every declared constraint, by table and type
SELECT TABLE_NAME, CONSTRAINT_TYPE, COUNT(*) AS n,
       GROUP_CONCAT(CONSTRAINT_NAME ORDER BY CONSTRAINT_NAME SEPARATOR ', ') AS constraint_names
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'arcledger'
GROUP BY TABLE_NAME, CONSTRAINT_TYPE
ORDER BY TABLE_NAME, CONSTRAINT_TYPE;

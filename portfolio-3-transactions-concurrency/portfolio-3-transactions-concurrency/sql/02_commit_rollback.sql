-- =============================================================
-- ArcLedger - Portfolio 3: Demos 1 and 2 (single session)
--   Demo 1  COMMIT   - a successful transfer
--   Demo 2  ROLLBACK - transfers that break a business rule
-- Run after 01_setup.sql:
--   mysql -u root -p -t arcledger < 02_commit_rollback.sql > ../evidence/02_commit_rollback_output.txt
-- (In Workbench: run the whole file with the lightning bolt.)
-- =============================================================
USE arcledger;
CALL sp_reset_demo();

SELECT '---- Starting balances ----' AS step;
SELECT * FROM v_demo_balances;

-- =============================================================
-- DEMO 1: COMMIT
-- Alice sends Bola N25,000. Inside ONE transaction sp_transfer:
-- locks both accounts, inserts the transaction, the transfer row and
-- two log rows, debits Alice, credits Bola, then COMMITs.
-- =============================================================
SELECT '==== DEMO 1: COMMIT - Alice sends Bola N25,000 ====' AS step;
CALL sp_transfer('9000000001', '9000000002', 25000.00);

SELECT * FROM v_demo_balances;          -- Alice 75,000  Bola 125,000

-- Everything the transaction wrote, now permanent
SELECT t.transaction_ref, t.transaction_type, t.amount, t.status,
       src.account_number AS from_account, dst.account_number AS to_account
FROM transactions t
JOIN transaction_transfer tt ON tt.transaction_id = t.transaction_id
JOIN account src ON src.account_id = t.account_id
JOIN account dst ON dst.account_id = tt.destination_account_id
WHERE src.account_number = '9000000001' AND t.transaction_type = 'TRANSFER';

SELECT l.event, l.message
FROM transaction_logs l JOIN transactions t ON t.transaction_id = l.transaction_id
JOIN account a ON a.account_id = t.account_id
WHERE a.account_number = '9000000001' AND t.transaction_type = 'TRANSFER'
ORDER BY l.log_id;

-- =============================================================
-- DEMO 2: ROLLBACK on business rules
-- Each call is refused. The handler ROLLs BACK, so no balance changes;
-- the failed attempt is still recorded (status FAILED + reason) for audit.
-- =============================================================
SELECT '==== DEMO 2a: ROLLBACK - Alice tries to send N500,000 (she has N75,000) ====' AS step;
CALL sp_transfer('9000000001', '9000000002', 500000.00);

SELECT '==== DEMO 2b: ROLLBACK - transfer to her own account ====' AS step;
CALL sp_transfer('9000000001', '9000000001', 1000.00);

SELECT '==== DEMO 2c: ROLLBACK - destination account does not exist ====' AS step;
CALL sp_transfer('9000000001', '1234567890', 1000.00);

SELECT '==== DEMO 2d: ROLLBACK - destination account is CLOSED ====' AS step;
UPDATE account SET status = 'CLOSED' WHERE account_number = '9000000002';
CALL sp_transfer('9000000001', '9000000002', 1000.00);
UPDATE account SET status = 'ACTIVE' WHERE account_number = '9000000002';

SELECT '---- Balances after all four failures: unchanged ----' AS step;
SELECT * FROM v_demo_balances;          -- still Alice 75,000  Bola 125,000

SELECT '---- Audit trail: every attempt, successful or not ----' AS step;
SELECT t.transaction_ref, t.amount, t.status,
       (SELECT message FROM transaction_logs l WHERE l.transaction_id = t.transaction_id
        ORDER BY log_id DESC LIMIT 1) AS final_log_message
FROM transactions t JOIN account a ON a.account_id = t.account_id
WHERE a.account_number = '9000000001' AND t.transaction_type = 'TRANSFER'
ORDER BY t.transaction_id;

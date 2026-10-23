-- =============================================================
-- ArcLedger - Portfolio 3: Transactions and Concurrency - SETUP
-- Run once, on the Portfolio 1 database:
--   mysql -u root -p arcledger < 01_setup.sql
-- (In Workbench: open the file and click the lightning bolt.)
--
-- Creates:
--   1. Two triggers that close the Portfolio 1 limitations
--   2. sp_transfer       - a safe, atomic funds transfer
--   3. sp_reset_demo     - puts the two demo accounts back to N100,000 each
--   4. Two demo customers / accounts used by every demo:
--        Alice  9000000001   and   Bola  9000000002
-- =============================================================
USE arcledger;

-- -------------------------------------------------------------
-- 1. Triggers: rules a CHECK constraint could not enforce (Portfolio 1, L1/L2)
-- -------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_transfer_rules;
DELIMITER //
CREATE TRIGGER trg_transfer_rules
BEFORE INSERT ON transaction_transfer
FOR EACH ROW
BEGIN
    DECLARE v_type    VARCHAR(20);
    DECLARE v_source  INT;
    SELECT transaction_type, account_id INTO v_type, v_source
    FROM transactions WHERE transaction_id = NEW.transaction_id;

    IF v_type <> 'TRANSFER' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'transaction_transfer rows are only allowed for TRANSFER transactions';
    END IF;
    IF NEW.destination_account_id = v_source THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A transfer cannot go to the account it comes from';
    END IF;
END//
DELIMITER ;

-- -------------------------------------------------------------
-- 2. sp_transfer: move money between two accounts, all or nothing.
--
--    CALL sp_transfer('9000000001', '9000000002', 25000.00);
--
--    - Locks BOTH accounts (SELECT ... FOR UPDATE) so no other session
--      can change them until this transaction ends.
--    - Always locks the LOWER account_id first. Two opposite transfers
--      (A->B and B->A) then queue instead of deadlocking (demo 8).
--    - Checks every rule before touching any balance.
--    - On ANY error: ROLLBACK, then records the failed attempt with
--      its reason in a separate, small transaction.
-- -------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_transfer;
DELIMITER //
CREATE PROCEDURE sp_transfer(IN p_from_account_number CHAR(10),
                             IN p_to_account_number   CHAR(10),
                             IN p_amount              DECIMAL(15,2))
BEGIN
    DECLARE v_from_id, v_to_id, v_txn_id INT;
    DECLARE v_from_balance DECIMAL(15,2);
    DECLARE v_from_status, v_to_status VARCHAR(10);
    DECLARE v_ref VARCHAR(20) DEFAULT CONCAT('TRF', LPAD(UUID_SHORT() MOD 100000000000000000, 17, '0'));
    DECLARE v_error TEXT;

    -- Runs if ANY statement below fails (our own SIGNALs or a database error)
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error = MESSAGE_TEXT;
        ROLLBACK;                                   -- undo everything done so far

        -- Keep an audit record of the failed attempt (only possible if the source account exists)
        IF v_from_id IS NOT NULL THEN
            START TRANSACTION;
            -- The INSERTs below take foreign-key (shared) locks on the source and
            -- destination account rows. Take them in the SAME order as the transfer
            -- path (lowest account_id first), or a failed B->A attempt can deadlock
            -- with a successful A->B transfer. (Found by tools/stress_test.py.)
            SELECT COUNT(*) INTO @ignore FROM account
            WHERE account_id IN (v_from_id, IFNULL(v_to_id, v_from_id))
            ORDER BY account_id FOR SHARE;
            INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
            VALUES (v_ref, v_from_id, 'TRANSFER', GREATEST(ABS(p_amount), 0.01), 'FAILED');
            SET v_txn_id = LAST_INSERT_ID();
            IF v_to_id IS NOT NULL AND v_to_id <> v_from_id THEN
                INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (v_txn_id, v_to_id);
            END IF;
            INSERT INTO transaction_logs (transaction_id, event, message) VALUES
                (v_txn_id, 'INITIATED', 'TRANSFER request received'),
                (v_txn_id, 'FAILED', LEFT(v_error, 200));
            COMMIT;
        END IF;

        SELECT 'ROLLED BACK' AS outcome, v_ref AS transaction_ref, v_error AS reason;
    END;

    -- Look up the two accounts (no lock yet)
    SELECT account_id INTO v_from_id FROM account WHERE account_number = p_from_account_number;
    SELECT account_id INTO v_to_id   FROM account WHERE account_number = p_to_account_number;

    IF v_from_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source account not found'; END IF;
    IF v_to_id   IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Destination account not found'; END IF;
    IF v_from_id = v_to_id THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot transfer to the same account'; END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Amount must be greater than zero'; END IF;

    START TRANSACTION;

    -- Lock both rows, LOWER id first (consistent lock order prevents deadlocks)
    SELECT account_id INTO @ignore FROM account WHERE account_id = LEAST(v_from_id, v_to_id)    FOR UPDATE;
    SELECT account_id INTO @ignore FROM account WHERE account_id = GREATEST(v_from_id, v_to_id) FOR UPDATE;

    -- Read the LOCKED, current values
    SELECT balance, status INTO v_from_balance, v_from_status FROM account WHERE account_id = v_from_id;
    SELECT status          INTO v_to_status                   FROM account WHERE account_id = v_to_id;

    IF v_from_status <> 'ACTIVE' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source account is not active'; END IF;
    IF v_to_status   <> 'ACTIVE' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Destination account is not active'; END IF;
    IF v_from_balance < p_amount THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds'; END IF;

    -- Record the transaction
    INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status)
    VALUES (v_ref, v_from_id, 'TRANSFER', p_amount, 'SUCCESSFUL');
    SET v_txn_id = LAST_INSERT_ID();
    INSERT INTO transaction_transfer (transaction_id, destination_account_id) VALUES (v_txn_id, v_to_id);

    -- Move the money
    UPDATE account SET balance = balance - p_amount WHERE account_id = v_from_id;
    UPDATE account SET balance = balance + p_amount WHERE account_id = v_to_id;

    INSERT INTO transaction_logs (transaction_id, event, message) VALUES
        (v_txn_id, 'INITIATED',  'TRANSFER request received'),
        (v_txn_id, 'SUCCESSFUL', 'Completed');

    COMMIT;

    SELECT 'COMMITTED' AS outcome, v_ref AS transaction_ref, p_amount AS amount,
           (SELECT balance FROM account WHERE account_id = v_from_id) AS from_balance,
           (SELECT balance FROM account WHERE account_id = v_to_id)   AS to_balance;
END//
DELIMITER ;

-- -------------------------------------------------------------
-- 3. Demo customers and accounts (fixed numbers so every demo can find them)
-- -------------------------------------------------------------
INSERT IGNORE INTO customer (first_name, last_name, bvn, phone, email, date_of_birth) VALUES
 ('Alice', 'Demo', '90000000001', '+2349000000001', 'alice.demo@mail.example', '1990-01-01'),
 ('Bola',  'Demo', '90000000002', '+2349000000002', 'bola.demo@mail.example',  '1991-02-02');

INSERT IGNORE INTO account (account_number, customer_id, branch_id, account_type, opened_date)
SELECT '9000000001', customer_id, (SELECT MIN(branch_id) FROM branch), 'CURRENT', CURDATE()
FROM customer WHERE bvn = '90000000001';
INSERT IGNORE INTO account (account_number, customer_id, branch_id, account_type, opened_date)
SELECT '9000000002', customer_id, (SELECT MIN(branch_id) FROM branch), 'CURRENT', CURDATE()
FROM customer WHERE bvn = '90000000002';

-- -------------------------------------------------------------
-- 4. sp_reset_demo: clear the demo accounts' history and give each
--    a fresh N100,000 opening deposit. Run at the start of every demo.
-- -------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_reset_demo;
DELIMITER //
CREATE PROCEDURE sp_reset_demo()
BEGIN
    DECLARE v_a, v_b INT;
    SELECT account_id INTO v_a FROM account WHERE account_number = '9000000001';
    SELECT account_id INTO v_b FROM account WHERE account_number = '9000000002';

    START TRANSACTION;
    DROP TEMPORARY TABLE IF EXISTS demo_txns;
    CREATE TEMPORARY TABLE demo_txns AS
        SELECT transaction_id FROM transactions WHERE account_id IN (v_a, v_b)
        UNION
        SELECT transaction_id FROM transaction_transfer WHERE destination_account_id IN (v_a, v_b);
    DELETE FROM transaction_logs     WHERE transaction_id IN (SELECT transaction_id FROM demo_txns);
    DELETE FROM transaction_transfer WHERE transaction_id IN (SELECT transaction_id FROM demo_txns);
    DELETE FROM transactions         WHERE transaction_id IN (SELECT transaction_id FROM demo_txns);
    DROP TEMPORARY TABLE demo_txns;

    -- Opening deposits, so the balances agree with the transaction history
    INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status) VALUES
        (CONCAT('DEP', LPAD(UUID_SHORT() MOD 100000000000000000, 17, '0')), v_a, 'DEPOSIT', 100000.00, 'SUCCESSFUL');
    INSERT INTO transaction_logs (transaction_id, event, message) VALUES
        (LAST_INSERT_ID(), 'INITIATED', 'DEPOSIT request received'), (LAST_INSERT_ID(), 'SUCCESSFUL', 'Completed');
    INSERT INTO transactions (transaction_ref, account_id, transaction_type, amount, status) VALUES
        (CONCAT('DEP', LPAD(UUID_SHORT() MOD 100000000000000000, 17, '0')), v_b, 'DEPOSIT', 100000.00, 'SUCCESSFUL');
    INSERT INTO transaction_logs (transaction_id, event, message) VALUES
        (LAST_INSERT_ID(), 'INITIATED', 'DEPOSIT request received'), (LAST_INSERT_ID(), 'SUCCESSFUL', 'Completed');

    UPDATE account SET balance = 100000.00, status = 'ACTIVE' WHERE account_id IN (v_a, v_b);
    COMMIT;
END//
DELIMITER ;

-- A small view used by every demo to show the two balances
CREATE OR REPLACE VIEW v_demo_balances AS
SELECT a.account_number, c.first_name AS owner, a.balance, a.status
FROM account a JOIN customer c ON c.customer_id = a.customer_id
WHERE a.account_number IN ('9000000001', '9000000002')
ORDER BY a.account_number;

CALL sp_reset_demo();
SELECT * FROM v_demo_balances;

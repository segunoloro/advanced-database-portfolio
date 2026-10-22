-- =============================================================
-- ArcLedger Digital Bank - Core schema
-- MIT 8103 Portfolio 1: Database Design and Modelling
-- MySQL 8.0.16+ (needed for CHECK constraints)
-- =============================================================

DROP DATABASE IF EXISTS arcledger;
CREATE DATABASE arcledger;
USE arcledger;

-- -------------------------------------------------------------
-- Customer: one row per customer
-- -------------------------------------------------------------
CREATE TABLE customer (
    customer_id    INT           NOT NULL AUTO_INCREMENT,
    first_name     VARCHAR(50)   NOT NULL,
    last_name      VARCHAR(50)   NOT NULL,
    bvn            CHAR(11)      NOT NULL,
    phone          VARCHAR(15)   NOT NULL,
    email          VARCHAR(100)  NULL,
    date_of_birth  DATE          NOT NULL,
    CONSTRAINT pk_customer        PRIMARY KEY (customer_id),
    CONSTRAINT uq_customer_bvn    UNIQUE (bvn),
    CONSTRAINT uq_customer_phone  UNIQUE (phone),
    CONSTRAINT ck_customer_bvn    CHECK (bvn REGEXP '^[0-9]{11}$')
);

-- -------------------------------------------------------------
-- Branch: one row per branch
-- -------------------------------------------------------------
CREATE TABLE branch (
    branch_id    INT          NOT NULL AUTO_INCREMENT,
    branch_name  VARCHAR(80)  NOT NULL,
    city         VARCHAR(50)  NOT NULL,
    state        VARCHAR(50)  NOT NULL,
    CONSTRAINT pk_branch  PRIMARY KEY (branch_id)
);

-- -------------------------------------------------------------
-- Account: one row per account
-- Each account belongs to ONE customer (no joint accounts)
-- and is opened at ONE branch.
-- -------------------------------------------------------------
CREATE TABLE account (
    account_id      INT            NOT NULL AUTO_INCREMENT,
    account_number  CHAR(10)       NOT NULL,
    customer_id     INT            NOT NULL,
    branch_id       INT            NOT NULL,
    account_type    ENUM('SAVINGS','CURRENT') NOT NULL,
    balance         DECIMAL(15,2)  NOT NULL DEFAULT 0.00,
    status          ENUM('ACTIVE','CLOSED')   NOT NULL DEFAULT 'ACTIVE',
    opened_date     DATE           NOT NULL,
    CONSTRAINT pk_account           PRIMARY KEY (account_id),
    CONSTRAINT uq_account_number    UNIQUE (account_number),
    CONSTRAINT fk_account_customer  FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
    CONSTRAINT fk_account_branch    FOREIGN KEY (branch_id)   REFERENCES branch (branch_id),
    CONSTRAINT ck_account_number    CHECK (account_number REGEXP '^[0-9]{10}$'),
    CONSTRAINT ck_account_balance   CHECK (balance >= 0)
);

-- -------------------------------------------------------------
-- Transactions: one row per transaction (any type)
-- account_id = the account debited (withdrawal, transfer)
--              or credited (deposit)
-- -------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id    INT            NOT NULL AUTO_INCREMENT,
    transaction_ref   VARCHAR(20)    NOT NULL,
    account_id        INT            NOT NULL,
    transaction_type  ENUM('DEPOSIT','WITHDRAWAL','TRANSFER') NOT NULL,
    amount            DECIMAL(15,2)  NOT NULL,
    status            ENUM('SUCCESSFUL','FAILED') NOT NULL,
    transaction_date  DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_transactions        PRIMARY KEY (transaction_id),
    CONSTRAINT uq_transactions_ref    UNIQUE (transaction_ref),
    CONSTRAINT fk_transactions_account FOREIGN KEY (account_id) REFERENCES account (account_id),
    CONSTRAINT ck_transactions_amount CHECK (amount > 0)
);

-- -------------------------------------------------------------
-- Transaction_Transfer: one row per transfer (subtype of transactions)
-- 1:1 with transactions - the PK is also the FK.
-- -------------------------------------------------------------
CREATE TABLE transaction_transfer (
    transaction_id          INT  NOT NULL,
    destination_account_id  INT  NOT NULL,
    CONSTRAINT pk_transaction_transfer  PRIMARY KEY (transaction_id),
    CONSTRAINT fk_transfer_transaction  FOREIGN KEY (transaction_id)         REFERENCES transactions (transaction_id),
    CONSTRAINT fk_transfer_destination  FOREIGN KEY (destination_account_id) REFERENCES account (account_id)
);

-- -------------------------------------------------------------
-- Transaction_Logs: one row per event in a transaction's life
-- -------------------------------------------------------------
CREATE TABLE transaction_logs (
    log_id          INT           NOT NULL AUTO_INCREMENT,
    transaction_id  INT           NOT NULL,
    event           ENUM('INITIATED','SUCCESSFUL','FAILED','REVERSED') NOT NULL,
    message         VARCHAR(200)  NULL,
    log_time        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_transaction_logs  PRIMARY KEY (log_id),
    CONSTRAINT fk_logs_transaction  FOREIGN KEY (transaction_id) REFERENCES transactions (transaction_id)
);

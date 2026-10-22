# Normalisation: ArcLedger Digital Bank

This shows how the six tables were reached by normalising a single flat record step by step. At each stage it names the dependency causing the problem and the anomaly it would create.

## Step 0: Unnormalised form (UNF)
Imagine a branch keeping one spreadsheet row per account, like a printed statement:

| account_number | customer_name | bvn | phone | branch_name | branch_city | account_type | balance | transactions |
|---|---|---|---|---|---|---|---|---|
| 0123456781 | Adaeze Nwosu | 22100000001 | +2348030000001 | Ikeja Allen Avenue | Ikeja | SAVINGS | 325,000 | {TXN..001, DEPOSIT, 500000, SUCCESSFUL, [INITIATED, SUCCESSFUL]}, {TXN..006, TRANSFER, 75000, to 0123456783, [INITIATED, SUCCESSFUL]}, … |

**Problems**
- `transactions` is a **repeating group**: many transactions packed into one cell, each with its own nested list of log events.
- You can't query "all failed transfers" or "all transactions over ₦50,000" without parsing text.

## Step 1: First Normal Form (1NF)
**Rule:** every cell holds one atomic value, there are no repeating groups, and each row is identified by a key.

Unpack the repeating groups so there is **one row per log event**:

```
ACCOUNT_ACTIVITY(account_number, transaction_ref, log_event,
                 customer_name, bvn, phone, date_of_birth,
                 branch_name, branch_city, branch_state,
                 account_type, balance, opened_date,
                 transaction_type, amount, status, transaction_date,
                 destination_account_number,
                 log_message, log_time)
```
Composite key: **(transaction_ref, log_event)**. Every value is now atomic, but the data is extremely repetitive. Adaeze's name, BVN and branch are repeated on every log row of every transaction.

## Step 2: Second Normal Form (2NF)
**Rule:** be in 1NF, and every non-key attribute must depend on the **whole** key, not just part of it.

Partial dependencies on part of the key `(transaction_ref, log_event)`:

| Determinant | Depends on it |
|---|---|
| `transaction_ref` | account_number, transaction_type, amount, status, transaction_date, destination_account_number, and through the account, all customer and branch fields |
| `(transaction_ref, log_event)` | log_message, log_time |

**Anomalies if left as is**
- **Update:** changing Adaeze's phone number means editing hundreds of rows. Missing one leaves her with two phone numbers.
- **Insert:** a new customer can't be recorded until they make a transaction.
- **Delete:** deleting a customer's only transaction loses the record of the customer and their account.

**Decomposition** (intermediate relations, not yet the final tables)
```
TXN_2NF(transaction_ref, transaction_type, amount, status, transaction_date,
        destination_account_number,
        account_number, account_type, balance, opened_date,     <- account fields
        customer_name, bvn, phone, date_of_birth,               <- customer fields
        branch_name, branch_city, branch_state)                 <- branch fields
LOG_2NF(transaction_ref, log_event, log_message, log_time)
```
`TXN_2NF` still carries the account, customer and branch fields, including the account's `balance`, because they haven't been separated yet. That separation happens in 3NF. In the **final** design, `balance` belongs only to `account`, and the `transactions` table has no balance column.

## Step 3: Third Normal Form (3NF)
**Rule:** be in 2NF, with no **transitive** dependencies, where a non-key attribute depends on another non-key attribute.

Transitive chains still inside `TXN_2NF`:

| Chain | Anomaly if kept |
|---|---|
| `transaction_ref → account_number → account_type, balance, opened_date` | The account's details, including its balance, are repeated on every transaction, and must all be updated whenever the balance changes |
| `account_number → bvn → customer_name, phone, date_of_birth` | A customer with two accounts has their details stored twice |
| `account_number → branch_name → branch_city, branch_state` | Renaming a branch means updating every account opened there |

Each chain is removed by moving the dependent attributes into a table of their own. `balance` moves to `ACCOUNT`, where it is stored **once per account**:

```
CUSTOMER(customer_id, first_name, last_name, bvn, phone, email, date_of_birth)
BRANCH(branch_id, branch_name, city, state)
ACCOUNT(account_id, account_number, customer_id → CUSTOMER, branch_id → BRANCH,
        account_type, balance, status, opened_date)
TRANSACTIONS(transaction_id, transaction_ref, account_id → ACCOUNT,
             transaction_type, amount, status, transaction_date, destination_account_id)
TRANSACTION_LOGS(log_id, transaction_id → TRANSACTIONS, event, message, log_time)
```

### Removing NULLs: the transfer subtype
`destination_account_id` only has a value when `transaction_type = 'TRANSFER'`. For every deposit and withdrawal it would be NULL. That column describes only a **subset** of transactions, so it moves into a subtype table linked 1:1 to its parent:

```
TRANSACTIONS(transaction_id, transaction_ref, account_id, transaction_type, amount, status, transaction_date)
TRANSACTION_TRANSFER(transaction_id → TRANSACTIONS, destination_account_id → ACCOUNT)
```
This is **specialisation** (a supertype/subtype design). `TRANSACTIONS` holds what every transaction has in common, and `TRANSACTION_TRANSFER` holds what only transfers have. A new transaction kind with its own details, such as bill payments, can later get its own subtype table without changing `TRANSACTIONS`.

These six tables are the final schema in `sql/01_schema.sql`.

## Step 4: Boyce–Codd Normal Form (BCNF)
**Rule:** for every non-trivial functional dependency X → Y, X must be a **candidate key**.

| Table | Candidate keys | Any other determinant? | BCNF? |
|---|---|---|---|
| customer | customer_id, bvn, phone | No | ✅ |
| branch | branch_id | No | ✅ |
| account | account_id, account_number | No | ✅ |
| transactions | transaction_id, transaction_ref | No | ✅ |
| transaction_transfer | transaction_id | No | ✅ |
| transaction_logs | log_id | No | ✅ |

Every determinant is a candidate key, and each is enforced by a `PRIMARY KEY` or `UNIQUE` constraint. So the schema is in **BCNF**, apart from the deliberate choice below.

### Why surrogate keys?
Natural identifiers (`bvn`, `account_number`, `transaction_ref`) are kept as **UNIQUE candidate keys**, but the primary keys are integer surrogates (`customer_id`, `account_id`, …):
- Integers are small and fast to join on. InnoDB stores the primary key in every secondary index, so a small key keeps all indexes smaller.
- Natural values can change (an account renumbered during a system migration), while a surrogate never does, so foreign keys stay stable.

## Step 5: Deliberate denormalisation
`account.balance` is a **derived value**: it can be calculated from the successful transactions (deposits and incoming transfers minus withdrawals and outgoing transfers). Storing a derived value is technically redundant.

**Why it is kept**
1. **Performance.** Every withdrawal and transfer must check the balance first. Reading one row is instant. Summing a customer's entire transaction history on every request would get slower as the table grows (Portfolio 2).
2. **Concurrency.** The balance row is what gets locked when two withdrawals hit the same account at the same moment (Portfolio 3).

**How the risk is controlled**
- The balance must only change in the same database transaction that records the money movement, so the two can't drift apart (Portfolio 3).
- The reconciliation query **V7** in `sql/05_verify.sql` rebuilds every balance from the transactions and compares. All accounts show **OK**.

## Limitations: rules the schema cannot enforce
MySQL `CHECK` constraints can only look at **one row of one table**. Two business rules need information from another table, so the DDL can't enforce them. They are shown as accepted in `sql/04_constraint_tests.sql` (L1, L2):

| Rule | Why CHECK can't do it | Where it will be enforced |
|---|---|---|
| A `transaction_transfer` row may only exist for a transaction whose type is `TRANSFER` | Needs `transaction_type`, which is in another table | Trigger or transfer procedure (Portfolio 3) |
| A transfer's destination must differ from its source account | The source `account_id` is in `transactions`, the destination is in `transaction_transfer` | Trigger or transfer procedure (Portfolio 3) |

The MongoDB model (Portfolio 4) can enforce both, because there the transfer details are stored inside the transaction document.

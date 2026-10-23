# Portfolio 4: NoSQL and Advanced Data Models (MongoDB)

**Case study:** ArcLedger Digital Bank, the **same data** as Portfolios 1–3, migrated from MySQL into a **document model**.
**Database:** MongoDB 8 (single-node replica set), mongosh / MongoDB Compass. Migration in Python (`pymysql` + `pymongo`).
**Tested on:** MongoDB 8.3 and MySQL 8.0.46.

## Files
| File | Purpose |
|---|---|
| [mongodb/01_setup.js](mongodb/01_setup.js) | Creates 3 collections with `$jsonSchema` validators and indexes |
| [migration/migrate_mysql_to_mongo.py](migration/migrate_mysql_to_mongo.py) | **Main data load:** reads the ArcLedger MySQL database and reshapes 6 tables into 3 collections |
| [mongodb/02_seed.js](mongodb/02_seed.js) | *Optional:* a small hand-written sample (5 customers, 11 transactions) instead of the migration |
| [mongodb/03_queries.js](mongodb/03_queries.js) | 8 queries: single-document reads, statement, `$unwind`, `$group`, `$lookup`, reconciliation |
| [mongodb/04_validation_tests.js](mongodb/04_validation_tests.js) | 16 invalid writes that must be rejected, plus the missing-foreign-key gap |
| [mongodb/05_transfer_transaction.js](mongodb/05_transfer_transaction.js) | Funds transfer as a multi-document ACID transaction (commit and rollback) |
| [mongodb/06_performance_at_scale.js](mongodb/06_performance_at_scale.js) | Portfolio 2-style queries on 515,000 documents: plans, timings before and after indexing, storage |
| [evidence/](evidence/) | Output of every step |

## How to run
**1. MongoDB as a replica set** (needed for multi-document transactions in script 05). On Windows, add this to `mongod.cfg` and restart the MongoDB service, then run `rs.initiate()` once in the shell:
```yaml
replication:
  replSetName: rs0
```

**2. Run the scripts.**
```bash
mongosh "mongodb://localhost:27017/arcledger?directConnection=true" mongodb/01_setup.js

# if you ran Portfolio 3, first put the demo accounts back in a consistent state (in MySQL):
#   CALL sp_reset_demo();
pip install pymysql pymongo
python migration/migrate_mysql_to_mongo.py --mysql-user root --mysql-password <password>

mongosh "mongodb://localhost:27017/arcledger?directConnection=true" mongodb/03_queries.js
mongosh "mongodb://localhost:27017/arcledger?directConnection=true" mongodb/04_validation_tests.js
mongosh "mongodb://localhost:27017/arcledger?directConnection=true" mongodb/05_transfer_transaction.js
mongosh "mongodb://localhost:27017/arcledger?directConnection=true" mongodb/06_performance_at_scale.js
```

**In MongoDB Compass,** hover over the connection, click **`>_`** to open the shell, type `use arcledger`, then paste a script's contents. Scripts that declare `const` can't be pasted twice in the same shell tab, so open a new tab to re-run one. The Compass GUI is best for screenshots of the **Documents** (embedded accounts), **Validation**, **Indexes** and **Explain Plan** tabs.

## The model: 6 tables become 3 collections
In MySQL the data is **normalised** and joined at query time. In MongoDB it's shaped around **how it is read**, and each relationship is either **embedded** or **referenced**.

| MySQL table | MongoDB | Decision | Reason |
|---|---|---|---|
| `customer` | `customers` | root document | |
| `account` | `customers.accounts[]` | **embed** | 1:few (1–2 per customer), always shown with the customer |
| `branch` | `branches` + copy of name/city in each account | **reference + extended reference** | Rarely changes; the copy avoids a lookup when listing accounts |
| `transactions` | `transactions` | **separate collection** | Unbounded growth: hundreds per account would break the 16 MB document limit if embedded in the customer |
| `transaction_transfer` | `transactions.transfer` | **embed** | 1:1 and only on transfers. Documents don't need identical fields, so the subtype table disappears |
| `transaction_logs` | `transactions.events[]` | **embed** | 2–3 events per transaction, always read with it |

**A customer document** (shape; names and values come from the generated data)
```javascript
{ _id: 1, first_name: "...", last_name: "...", bvn: "23000000001", phone: "+2348070000001",
  date_of_birth: ISODate("..."),
  accounts: [
    { account_number: "1000000001", account_type: "CURRENT", balance: NumberDecimal("..."), status: "ACTIVE",
      opened_date: ISODate("..."), branch: { branch_id: 11, branch_name: "...", city: "..." } },
    { account_number: "1000010001", account_type: "SAVINGS", ... } ] }
```
**A transaction document (transfer)**, taken from the evidence run
```javascript
{ _id: 15011, transaction_ref: "BLK000000015011", account_number: "1000010880", type: "TRANSFER",
  amount: NumberDecimal("..."), status: "SUCCESSFUL", transaction_date: ISODate("..."),
  transfer: { destination_account_number: "1000000071" },          // only on transfers
  events: [ { event: "INITIATED",  message: "TRANSFER request received", at: ISODate("...") },
            { event: "SUCCESSFUL", message: "Completed",                 at: ISODate("...") } ] }
```
Money is stored as **Decimal128** (`NumberDecimal`), the equivalent of MySQL `DECIMAL`. A validator rejects floats (test T08).

## Results

### Migration ([evidence](evidence/02_migration_output.txt))
| MySQL | Rows | MongoDB | Count |
|---|---|---|---|
| branch | 20 | `branches` documents | 20 ✅ |
| customer | 10,002 | `customers` documents | 10,002 ✅ |
| account | 15,002 | embedded `accounts[]` | 15,002 ✅ |
| transactions | 515,002 | `transactions` documents | 515,002 ✅ |
| transaction_transfer | 225,000 | embedded `transfer` | 225,000 ✅ |
| transaction_logs | 1,030,004 | embedded `events[]` | 1,030,004 ✅ |

About **1.8 million rows in 6 tables became 525,024 documents in 3 collections** in about 45 seconds. The sum of all balances is identical (₦58,924,538,819.10), and 0 documents were rejected by the validators.

**Finding during migration:** the first run showed 2 accounts whose balance didn't match their transaction history. They were the Portfolio 3 demo accounts (Alice and Bola), whose balances the concurrency demos change directly, so they don't reconcile in MySQL either. The migration had copied them faithfully. After `CALL sp_reset_demo()` in MySQL and a re-run, **all 15,002 accounts reconcile** (Q8). The migration is a faithful copy, so it carries over data problems as well as good data.

### Queries ([evidence](evidence/03_queries_output.txt))
- **Q1** Customer + all accounts + branch: **one document read**. MySQL needs `customer ⋈ account ⋈ branch`.
- **Q2** Transfer + destination + full event history: **one document read**. MySQL needs `transactions ⋈ transaction_transfer ⋈ transaction_logs`.
- **Q3** Statement, money out and in, using both indexes.
- **Q4** Failure reasons: `$unwind` on the embedded `events` array, then `$group`.
- **Q5–Q6** `$group` aggregations, including total balances per branch from the embedded branch copy.
- **Q7** A join is still possible when needed: `$lookup` the receiver's name.
- **Q8** Reconciliation: **15,002 / 15,002 accounts OK.**

### Validation ([evidence](evidence/04_validation_output.txt)): 16/16 invalid writes rejected
BVN format, duplicate BVN / phone / account number / reference (unique indexes), missing phone, negative balance, invalid account type, float instead of Decimal128, zero and negative amount, unknown type, and an empty `events` array. Two of the tests are rules that **MySQL CHECK couldn't enforce** (Portfolio 1, L1/L2) but a MongoDB validator can, because it can compare fields inside one document:
- T13/T14: a `TRANSFER` must have transfer details, and other types must not.
- T15: a transfer can't go to its own source account.

**The gap:** a transaction for account `0000000000`, which doesn't exist, is **accepted**. MongoDB has **no foreign keys**.

### Multi-document transaction ([evidence](evidence/05_transfer_output.txt))
A transfer between two customers changes **two customer documents** and inserts **one transaction document** inside a session transaction:
1. Enough funds: **COMMITTED**, and both balances changed together.
2. More than the balance: **ROLLED BACK**, nothing changed.
3. Destination doesn't exist: the debit had **already been applied** when the credit failed, and **`abortTransaction()` undid it**.

The script then reverses its own transfer and removes the demo records, so re-runs and reconciliation stay clean.

### Performance at scale ([evidence](evidence/06_performance_output.txt))
515,000 transaction documents, average of 10 runs after a warm-up, measured from mongosh.

| # | Query | Plan | Documents examined | Time |
|---|---|---|---|---|
| S1 | Customer profile with accounts (by BVN) | `EXPRESS_IXSCAN` on `uq_customer_bvn` | 1 | 1.4 ms |
| S2 | Full statement (`$or`: out + in) | `IXSCAN` × 2 + `SORT_MERGE` | 54 | 6.6 ms |
| S3a | Daily report, no date index | **`COLLSCAN`** | 515,002 | 501 ms |
| S3b | Daily report with `ix_txn_date` | `IXSCAN` | 4,544 | 85 ms (**5.9×**) |
| S4a | Failed in last 7 days by reason, no index | **`COLLSCAN`** | 515,002 | 337 ms |
| S4b | Same, with `ix_txn_status_date` (status, date) | `IXSCAN` | 1,114 | 11 ms (**30×**) |

**Same pattern as MySQL.** Without an index both databases scan everything, and the same composite index `(status, date)`, equality first and range last, cuts examined documents from 515,002 to 1,114 in both.

**One difference:** for the statement, MongoDB used **both** indexes for the `$or` automatically (index union, then `SORT_MERGE`). In Portfolio 2, MySQL's `OR … IN (subquery)` fell back to a **full scan** (117 ms) and had to be rewritten by hand as `UNION ALL`.

**Absolute times aren't directly comparable** with Portfolio 2. The MySQL times were measured *inside* the server by a stored procedure. These are measured from the mongosh client and include returning the documents to the shell, and each `FETCH` reads a whole document (~357 bytes including its embedded events).

### Storage: the same data in both models
| | MySQL (InnoDB) | MongoDB (WiredTiger) |
|---|---|---|
| Customer side | `customer` + `account` + `branch`: 3.0 MB data, 1.8 MB indexes | `customers`: 4.7 MB uncompressed, **1.1 MB on disk**, 2.2 MB indexes |
| Transaction side | `transactions` + `transaction_transfer` + `transaction_logs`: 92.7 MB data, 113.8 MB indexes* | `transactions`: 175.7 MB uncompressed, **39 MB on disk**, 93.2 MB indexes* |

\* Includes the indexes added for Portfolio 2 (MySQL) and in script 06 (MongoDB).

Uncompressed, the documents are almost **twice** the size of the rows, because every document repeats its field names (`"transaction_date"`, `"events"`, …) and branch details are copied into each account. WiredTiger's block compression (snappy by default) more than makes up for it on disk.

## Suitability: MongoDB vs MySQL for ArcLedger
| Aspect | MySQL (Portfolios 1–3) | MongoDB (this portfolio) |
|---|---|---|
| Referential integrity | Foreign keys enforced by the engine | **None.** An orphan transaction is accepted |
| Cross-field rules in one record | CHECK can't reach another table, so a trigger is needed (Portfolio 3) | The validator enforces them directly (T13–T15) |
| Customer profile / transfer with history | Joins across 3 tables | **One document read** |
| New transaction type with extra fields | `ALTER TABLE` or a new subtype table | Add fields to new documents, old ones unaffected |
| Transfer between two customers | Row-level ACID transactions, natural | Supported, but needs a replica set and an explicit session |
| Duplication | None (3NF/BCNF) | Branch copied into accounts: a rename must update every copy |
| `OR` across two access paths | Full scan unless rewritten | Index union automatically |
| Storage | Smaller uncompressed | Larger uncompressed, smaller on disk with compression |
| Horizontal scaling | Harder (Portfolio 5) | Built-in sharding, e.g. on `account_number` |

**Conclusion.** For the **core ledger**, where every naira must reconcile and every transaction must point to a real account, **MySQL is the better fit**: foreign keys, normalisation and simple row-level ACID transactions protect correctness by default. MongoDB suits the **read-heavy, customer-facing side**, such as the mobile app's profile screen, transaction history with full event detail, and new product types with their own fields. There, single-document reads, flexible schema and easy horizontal scaling matter more than joins.

A realistic architecture uses **both**: MySQL as the system of record, with changes streamed into MongoDB for the app's read views. `migrate_mysql_to_mongo.py` is a one-off version of that pipeline. In production it would run continuously through change-data-capture.

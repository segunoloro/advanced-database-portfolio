# Portfolio 2: Query Processing and Optimisation

**Case study:** ArcLedger Digital Bank (same database as Portfolio 1)
**DBMS:** MySQL 8.0 (InnoDB). Tested on MySQL 8.0.46.
**Data:** Portfolio 1 schema + `03_bulk_seed.sql`: 515,000 transactions, 225,000 transfers, 1,030,000 log events, 15,000 accounts, 10,000 customers.

## Files
| File | Purpose |
|---|---|
| [sql/01_queries.sql](sql/01_queries.sql) | The six business queries with results, `EXPLAIN` and `EXPLAIN ANALYZE`. Run **before** and **after** indexing, so the queries are identical |
| [sql/02_create_indexes.sql](sql/02_create_indexes.sql) | The five indexes added, with the reason for each |
| [sql/03_benchmark.sql](sql/03_benchmark.sql) | Runs each query 10× (after a warm-up) and reports the average time |
| [sql/04_drop_indexes.sql](sql/04_drop_indexes.sql) | Removes the indexes to return to the baseline |
| [sql/05_column_order_experiment.sql](sql/05_column_order_experiment.sql) | Same columns, different order: does it matter? |
| [evidence/](evidence/) | Plans before (`01_baseline_output.txt`) and after (`03_optimised_output.txt`), 3 benchmark runs on each side, column-order experiment |

## How to run
```bash
# on the Portfolio 1 database with 03_bulk_seed.sql loaded
mysql -u root -p -t arcledger < sql/01_queries.sql   > evidence/01_baseline_output.txt
mysql -u root -p -t arcledger < sql/03_benchmark.sql > evidence/03_benchmark_before.txt
mysql -u root -p    arcledger < sql/02_create_indexes.sql
mysql -u root -p -t arcledger < sql/01_queries.sql   > evidence/03_optimised_output.txt
mysql -u root -p -t arcledger < sql/03_benchmark.sql > evidence/03_benchmark_after.txt
mysql -u root -p -t arcledger < sql/05_column_order_experiment.sql > evidence/05_column_order_output.txt
```

## The six queries
| # | Business question | Who asks it |
|---|---|---|
| Q1 | Statement for one account for one month, newest first | Customer, mobile app |
| Q2 | Totals of all transactions on one day, by type and status | Finance / operations |
| Q3 | Failed transactions in the last 7 days | Operations |
| Q4 | Why do transactions fail? FAILED log events grouped by reason | Operations / product |
| Q5 | Find customers by surname | Customer service desk |
| Q6 | Full statement, money out **and** money in: `OR` (A) vs `UNION ALL` (B) | Customer, mobile app |

## Results

### Execution plans
`type = ALL` is a full table scan. `rows` is the optimiser's estimate of rows it must examine.

| Query | Before: access | Before: rows examined | After: access (index) | After: rows examined |
|---|---|---|---|---|
| Q1 | `ref` (FK index on account_id) + **filesort** | 34 | `range` (`ix_txn_account_date`), **backward index scan, no sort** | 8 |
| Q2 | **`ALL`** | 515,000 | `range` (`ix_txn_date`) | 4,544 |
| Q3 | **`ALL`** | 515,000 | `range` (`ix_txn_status_date`) | 1,114 |
| Q4 | **`ALL`** + temporary table | 1,030,000 | `ref` (`ix_logs_event_message`), **Using index** (covering) | 14,930 |
| Q5 | **`ALL`** | 10,000 | `ref` (`ix_customer_last_name`) | 712 |
| Q6A (`OR`) | **`ALL`** + dependent subquery run 514,966 times | 515,000 | unchanged: still a full scan | 515,000 |
| Q6B (`UNION ALL`) | two index lookups | 58 | two index lookups | 58 |

### Timing: average of 10 runs, median of 3 benchmark runs
| Query | Before (ms) | After (ms) | Speed-up |
|---|---|---|---|
| Q1 Account statement, one month | 0.090 | 0.052 | 1.7× |
| Q2 Daily report | 103.7 | 15.0 | **6.9×** |
| Q3 Failed, last 7 days | 57.2 | 0.36 | **160×** |
| Q4 Failure reasons (1M log rows) | 173.5 | 4.8 | **36×** |
| Q5 Customer by surname | 1.60 | 0.14 | 11× |
| Q6A Statement with `OR` | 116.6 | 125.8 | none |
| Q6B Statement with `UNION ALL` | 0.099 | 0.110 | none needed |
| **Q6: rewriting `OR` → `UNION ALL`** | **116.6** | **0.099** | **≈1,180×** |

Raw numbers: `evidence/03_benchmark_before_run1-3.txt` and `evidence/03_benchmark_after_run1-3.txt`.

### Column-order experiment (Q3)
Both indexes contain `status` and `transaction_date`. Only the order differs.

| Index | Index entries read | Why |
|---|---|---|
| `(status, transaction_date)` | **1,114** | Jumps to `status = 'FAILED'`, then reads only the 7-day range inside it |
| `(transaction_date, status)` | **36,928** | Must read **every** transaction in the 7 days, then discard the 97% that aren't failed |

That's 33× more work for the same columns in the wrong order. Rule: **equality columns first, range columns last.**

### Cost of the indexes
| Index | Size |
|---|---|
| `ix_txn_account_date` | 10.5 MB |
| `ix_txn_date` | 8.5 MB |
| `ix_txn_status_date` | 9.5 MB |
| `ix_logs_event_message` | 34.6 MB |
| `ix_customer_last_name` | 0.2 MB |
| **Total** | **≈63 MB** |

The transactions table's clustered primary key is 30.6 MB, so the three new indexes on it (28.5 MB) almost double its storage. Every `INSERT` into `transactions` now updates four secondary indexes instead of two.

## Performance analysis
**1. Full table scans were the main problem.** Before indexing, Q2–Q5 read every row: 515,000 transactions or 1,030,000 log events, to return a few thousand or fewer. The only indexes were the ones created by primary keys, unique keys and foreign keys, and none of them cover dates, status or event type. An index turns the scan into a range or lookup that reads only the matching entries. That's why the gain is largest where the filter is most **selective**: Q3 returns 0.2% of the table (160× faster), while Q2 returns about 0.9% and still has to fetch each row to sum `amount` (6.9×).

**2. Covering indexes avoid the table entirely.** Q4 needs only `event` and `message`, and the index `(event, message)` holds both. The plan shows **"Using index"**: MySQL counted the 14,930 FAILED events from the index alone and never read a table row. That made it 36× faster on the largest table.

**3. Column order matters as much as the columns.** The experiment above shows that putting the range column (`transaction_date`) first makes MySQL read 33× more index entries. The composite index has to match how the query filters.

**4. Composite indexes can remove sorting.** Q1 was already fast, because the FK index found the account's ~34 rows. But the plan showed **"Using filesort"**: MySQL sorted the rows itself. With `(account_id, transaction_date)`, the rows come out of the index already in date order ("Backward index scan" for `DESC`), so the sort step disappears. At 34 rows the saving is small. For an account with thousands of transactions it would matter more.

**5. Small tables gain less in absolute terms.** Q5 improved 11×, but from 1.6 ms to 0.14 ms. On 10,000 rows a full scan is already cheap. The surname is also not very selective here (712 of 10,000 customers are "Okafor", 7%), because the generator draws from 15 surnames.

**6. Some problems need a rewrite, not an index (Q6).** `WHERE account_id = ? OR transaction_id IN (subquery)` can't use an index for both sides of the `OR`. MySQL scanned all 515,000 transactions and ran the subquery 514,966 times. Adding indexes changed nothing (116.6 → 125.8 ms, within noise). Rewriting the query as two indexed lookups joined with `UNION ALL` returns the same 58 rows in 0.1 ms, about **1,180× faster**, with no new index.

**7. Indexes have a cost.** The five indexes use about 63 MB, and every insert into `transactions` and `transaction_logs` must update them. ArcLedger writes a transaction and two log rows for every payment, so indexes should be added only for frequent queries. In a real deployment, the daily report (Q2) could run on a read replica instead (Portfolio 5).

**8. A side effect worth knowing.** When `ix_txn_account_date` was created, MySQL **silently dropped** its automatic foreign-key index on `account_id`, because the new composite index starts with `account_id` and can serve the foreign key. As a result, `ix_txn_account_date` can't be dropped until a plain `account_id` index exists again (error 1553). `04_drop_indexes.sql` handles this. The first version of that script didn't, so the first "before" benchmark was invalid and was redone. It's a reminder to check the actual index list (`SHOW INDEX`) before and after every change.

## Measurement notes
- Timings come from a stored procedure that runs each query 10 times after a warm-up run, so data is already in the buffer pool. The table reports the median of three such runs.
- Single `EXPLAIN ANALYZE` timings vary a lot between runs (e.g. Q6B: 0.28 ms vs 1.07 ms), and instrumentation adds overhead to queries with many loops (Q6A shows ~810 ms there vs ~120 ms in the benchmark). So `EXPLAIN ANALYZE` is used for **row counts and plan shape**, and the benchmark for **time**.
- `ANALYZE TABLE` refreshes statistics before each run so the optimiser's estimates are current.

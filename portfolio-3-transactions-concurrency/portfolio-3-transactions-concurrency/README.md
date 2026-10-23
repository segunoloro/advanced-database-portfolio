# Portfolio 3: Transactions and Concurrency

**Case study:** ArcLedger Digital Bank (same database as Portfolios 1–2)
**DBMS:** MySQL 8.0, InnoDB. Default isolation level `REPEATABLE READ`. Tested on MySQL 8.0.46.

A funds transfer changes **two** balances, writes **three** kinds of rows, and many customers do it at the same time. That makes it the natural example of why a bank needs ACID transactions and concurrency control.

## Files
| File | Purpose |
|---|---|
| [sql/01_setup.sql](sql/01_setup.sql) | `sp_transfer` (safe atomic transfer), trigger `trg_transfer_rules`, `sp_reset_demo`, two demo accounts (Alice `9000000001`, Bola `9000000002`, ₦100,000 each) |
| [sql/02_commit_rollback.sql](sql/02_commit_rollback.sql) | Demos 1–2: COMMIT, and ROLLBACK on four business-rule failures |
| [sql/03_trigger_tests.sql](sql/03_trigger_tests.sql) | The two Portfolio 1 limitations (L1, L2), now rejected |
| `demos/demo3_atomicity/` … `demos/demo8_deadlock/` | Step-by-step scripts: `session1.sql` / `session2.sql` |
| [tools/run_demo.py](tools/run_demo.py) | Replays a demo with two real concurrent connections and prints a transcript |
| [tools/stress_test.py](tools/stress_test.py) | 10 sessions × 50 simultaneous transfers in both directions |
| [evidence/](evidence/) | Output of every script, every demo transcript, both stress-test runs |

## How to run in MySQL Workbench
1. Run `sql/01_setup.sql` once, on the Portfolio 1 database.
2. Run `sql/02_commit_rollback.sql` (whole file) and `sql/03_trigger_tests.sql` (one statement at a time with **Ctrl+Enter**, since two are meant to fail).
3. **Two-session demos (4–8):** you need two separate connections.
   - Go to the Workbench **Home** tab and click your connection **again**. A second connection tab opens. ⚠️ Two *query tabs* inside one connection share **one** session and won't show any of these effects.
   - Open `session1.sql` in the first connection tab and `session2.sql` in the second.
   - Run the steps **in number order**, switching tabs as the step numbers say: select a step's lines, then **Ctrl+Shift+Enter**.
   - When a step **waits** (the query keeps running), leave it and run the next step in the other tab. The waiting step finishes by itself.
   - If a wait lasts more than 30 s, Workbench may drop the connection. Avoid this by raising **Edit → Preferences → SQL Editor → DBMS connection read timeout**.
4. Each demo starts with `CALL sp_reset_demo();`, so they can be repeated in any order.

Without Workbench: `python tools/run_demo.py demos/demo7_locking_fix --user root --password …` replays a demo automatically.

## The transfer procedure
`CALL sp_transfer('9000000001', '9000000002', 25000.00);`

1. Validates the inputs: accounts exist, different accounts, amount > 0.
2. `START TRANSACTION`
3. **Locks both accounts** with `SELECT … FOR UPDATE`, always the **lower `account_id` first**.
4. Re-reads the locked balance and status: active accounts, sufficient funds.
5. Inserts into `transactions`, `transaction_transfer` and `transaction_logs`, debits one account and credits the other.
6. `COMMIT`.
7. On any error, an `EXIT HANDLER` runs `ROLLBACK`, then records the failed attempt (status FAILED, with the reason in the log) in a separate small transaction, so failures stay auditable.

The trigger `trg_transfer_rules` enforces the two rules that Portfolio 1 showed a CHECK constraint can't: transfer details only on a `TRANSFER`, and never to the source account. See `evidence/03_trigger_tests_output.txt`: both are now **ERROR 1644**, and a valid row is still accepted.

## Results

### Demo 1: COMMIT ([evidence](evidence/02_commit_rollback_output.txt))
Alice sends Bola ₦25,000. Both balances change together (75,000 / 125,000), and the transaction, transfer and both log rows are permanent.

### Demo 2: ROLLBACK on business rules ([evidence](evidence/02_commit_rollback_output.txt))
| Attempt | Outcome |
|---|---|
| ₦500,000 when Alice has ₦75,000 | ROLLED BACK: *Insufficient funds* |
| Transfer to her own account | ROLLED BACK: *Cannot transfer to the same account* |
| Destination doesn't exist | ROLLED BACK: *Destination account not found* |
| Destination account CLOSED | ROLLED BACK: *Destination account is not active* |

Balances afterwards: **unchanged**. All five attempts appear in the audit trail with status and reason.

### Demo 3: Atomicity, failure halfway ([transcript](evidence/demo3_atomicity_transcript.txt))
| Step | What happens | Alice |
|---|---|---|
| 1 | `START TRANSACTION`, debit ₦40,000, insert the transaction row | 60,000 (pending) |
| 2 | Insert transfer row to a non-existent account: **ERROR 1452** | n/a |
| 3 | Debit and transaction row **still pending** | 60,000 |
| 4 | `ROLLBACK` | **100,000**, transaction row gone |

**Key point:** a failed statement in MySQL undoes **only that statement**, not the transaction. The application must issue `ROLLBACK` to restore atomicity. `sp_transfer` does this in its exit handler.

### Demo 4: Isolation, dirty read ([transcript](evidence/demo4_dirty_read_transcript.txt))
Session 1 debits Alice ₦70,000 but doesn't commit, then later rolls back.

| Session 2 isolation level | Session 2 reads | |
|---|---|---|
| `READ UNCOMMITTED` | **30,000** | **Dirty read**: a value that was never committed |
| `READ COMMITTED` | 100,000 | Only committed data |

### Demo 5: Isolation, non-repeatable read ([transcript](evidence/demo5_non_repeatable_read_transcript.txt))
Session 2 reads Alice's balance twice inside one transaction, and Session 1 commits a ₦25,000 transfer in between.

| Session 2 isolation level | 1st read | 2nd read (same transaction) | |
|---|---|---|---|
| `READ COMMITTED` | 100,000 | **75,000** | **Non-repeatable read** |
| `REPEATABLE READ` (default) | 100,000 | **100,000** | Consistent snapshot. 75,000 is visible only after COMMIT |

### Demo 6: Concurrency problem, lost update ([transcript](evidence/demo6_lost_update_transcript.txt))
Two withdrawals (₦30,000 and ₦50,000) each **read** the balance, **calculate** the new value, then **write** it.

| Step | Session 1 | Session 2 |
|---|---|---|
| 1 | reads 100,000 | |
| 2 | | reads 100,000 |
| 3 | writes 70,000, commits | |
| 4 | | writes **50,000**, commits (overwrites 70,000) |

**Final balance 50,000. Correct balance 20,000.** The ₦30,000 withdrawal was **lost**: cash was paid out but the balance doesn't show it. `REPEATABLE READ` doesn't prevent this, because a plain `SELECT` doesn't lock.

### Demo 7: Control mechanism, pessimistic locking ([transcript](evidence/demo7_locking_fix_transcript.txt))
The same two withdrawals, but each reads with `SELECT … FOR UPDATE`.

| Step | Session 1 | Session 2 |
|---|---|---|
| 1 | reads 100,000 **and locks the row** | |
| 2 | | tries to read with lock: **WAITS** |
| 3 | writes 70,000, commits, releasing the lock | resumes and reads **70,000** |
| 4 | | writes 20,000, commits |

**Final balance 20,000: correct.** The lock turns the race into a queue.

### Demo 8: Deadlock and prevention ([transcript](evidence/demo8_deadlock_transcript.txt))
**Part A, the problem:** Alice→Bola (₦10,000) locks Alice first. Bola→Alice (₦20,000) locks Bola first. Each then needs the other's row:
```
Session 1 holds Alice, waits for Bola
Session 2 holds Bola,  waits for Alice   -> cycle
ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
*** WE ROLL BACK TRANSACTION (2)          <- InnoDB's own report
```
InnoDB detects the cycle **immediately** and rolls back one transaction (the "victim"). The other completes: Alice 90,000, Bola 110,000. The application must **retry** the victim.

**Part B, the fix:** both transfers lock the two accounts **in the same order** (lowest `account_id` first). The second transfer **waits** but never deadlocks. Both complete: Alice 110,000, Bola 90,000. `sp_transfer` always locks this way.

### Stress test: does it hold under real load?
10 sessions × 50 transfers at the same time, random direction, ₦1,000–₦30,000 each.

| | First version of `sp_transfer` | Final version |
|---|---|---|
| Committed | 340 | 478 |
| Rolled back: insufficient funds | 48 | 22 |
| **Rolled back: deadlock** | **112** | **0** (in 3 runs × 500) |
| Alice + Bola | 200,000 ✅ | 200,000 ✅ |
| Balances = transaction history | ✅ | ✅ |
| Any negative balance | no | no |

([before](evidence/stress_test_1_before_fix.txt), [after](evidence/stress_test_2_after_fix.txt))

**What the stress test found:** the transfer path locked accounts in a consistent order, but the **error handler did not**. After a rollback it writes an audit record, and those inserts take foreign-key locks on the source account first and the destination second, in **transfer** order. A failed B→A attempt could hold Bola and wait for Alice, while a successful A→B transfer held Alice and waited for Bola. `SHOW ENGINE INNODB STATUS` showed exactly this. The fix: the handler now takes `FOR SHARE` locks on both accounts in `account_id` order before inserting.

Even the first version **never corrupted any money**: every deadlock victim was rolled back cleanly and recorded as FAILED. Deadlocks are a performance and retry problem, not a correctness problem, as long as transactions are atomic.

## Discussion
**ACID in this design**
- **Atomicity:** all of a transfer's changes commit together or are rolled back together (Demos 1–3).
- **Consistency:** constraints, the trigger and the procedure's checks mean a committed transfer can't break a rule (no negative balance, no self-transfer, no orphan rows). Money is conserved under load.
- **Isolation:** controlled by the isolation level (Demos 4–5) and by row locks (Demos 7–8).
- **Durability:** InnoDB writes committed changes to its redo log before `COMMIT` returns, so committed transfers survive a crash. This wasn't demonstrated by crashing the server.

**Choosing an isolation level for ArcLedger**
- `READ UNCOMMITTED` must never be used for money: it shows balances that may be rolled back (Demo 4).
- `REPEATABLE READ` (MySQL's default) gives each transaction a stable snapshot, which suits statements and reports (Demo 5).
- **No isolation level alone prevents the lost update** in Demo 6. Any read-then-write on a balance needs an explicit lock (`FOR UPDATE`) or an atomic update such as `UPDATE account SET balance = balance - 30000 WHERE account_id = ? AND balance >= 30000`.

**Pessimistic vs optimistic control.** ArcLedger uses **pessimistic** locking (`FOR UPDATE`) because transfers on the same account conflict often and a conflict means money. The alternative, **optimistic** control (a version column, with the update rejected and retried if someone else changed the row), avoids holding locks. It fits better where conflicts are rare, such as a customer editing their profile.

**Deadlocks can't be fully eliminated, only made rare.** Consistent lock ordering removed them from the stress test. Production code should still **catch error 1213 and retry** the transaction, because other code paths may lock in different orders.

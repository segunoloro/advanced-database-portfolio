# Portfolio 5: Distributed and Cloud Database Exercise

**Case study:** ArcLedger Digital Bank, the same data as Portfolios 1–4.
**What this portfolio covers:**

| Brief topic | How it is covered |
|---|---|
| **Replication** | Hands-on: MongoDB replica set grown from 1 to 3 members; a write traced from primary to secondaries through the oplog |
| **Availability** | Hands-on: primary stopped gracefully and crashed while a probe writes every second; automatic election; recovery |
| **Consistency** | Hands-on: no-majority behaviour, write concern `w:1` vs `w:majority`, a stale read from a lagging secondary |
| **Sharding** | Design, backed by a simulation of 3 shard keys over 8 shards on the real 515,005 transactions |
| **Deployment** | Design: MySQL primary with read replicas, CAP/PACELC per component, managed-cloud deployment, Nigerian data residency |

**Tested on:** MongoDB 8.3 (3 members on one machine) and MySQL 8.0.46. Your machine runs MongoDB 9.0 as a Windows service; the scripts work the same way.

## Files
| File | Purpose |
|---|---|
| [replication/windows/start_member.bat](replication/windows/start_member.bat) | Starts an extra replica-set member on a given port (Windows) |
| [replication/01_add_members.js](replication/01_add_members.js) | Adds members 27018 and 27019 to `rs0` and waits for initial sync |
| [replication/02_replication_demo.js](replication/02_replication_demo.js) | Demo 1: full copy on every member; one write traced to the secondaries |
| [replication/03_failover_probe.js](replication/03_failover_probe.js) | Demo 2: writes once a second while you stop the primary |
| [replication/04_member_status.js](replication/04_member_status.js) | Who is primary, who is down, same data everywhere? (Demos 2–3) |
| [replication/05_no_majority.js](replication/05_no_majority.js) | Demo 4: the last member standing refuses writes |
| [replication/06_consistency_demo.js](replication/06_consistency_demo.js) | Demo 5: write concern and a stale read |
| [replication/07_back_to_single_member.js](replication/07_back_to_single_member.js) | Puts `rs0` back to one member afterwards (**important**, see step 8) |
| [sharding/shard_key_simulation.sql](sharding/shard_key_simulation.sql) | Shard key comparison on the MySQL data |
| [evidence/](evidence/) | Output of every step |

## How to run (Windows)
You need MongoDB Compass (already installed) and the **MongoDB Shell, `mongosh`**, as a separate download from mongodb.com/try/download/shell. The failover probe runs for 90 seconds and prints a line every second, which works better in a terminal than in Compass' shell tab.

The replica-set address used from step 2 onwards:
```
mongodb://localhost:27017,localhost:27018,localhost:27019/arcledger?replicaSet=rs0
```

1. **Start two extra members.** Open two Command Prompt windows in `replication\windows`:
   ```
   start_member.bat 27018          (window 1)
   start_member.bat 27019          (window 2)
   ```
   Leave both open. If Windows Firewall asks, allow *private networks*.
2. **Add them to `rs0`.** In a third window, in the `replication` folder:
   ```
   mongosh "mongodb://localhost:27017/?directConnection=true" 01_add_members.js
   ```
   It waits until both members show **SECONDARY**, about 20 s for the ArcLedger data. If your member was registered under the computer's name, the script switches it to `localhost` first, because MongoDB requires all members to use the same style of name.
3. **Demo 1, replication:**
   `mongosh "<replica-set address>" 02_replication_demo.js`
4. **Demo 2, failover.** Start the probe:
   `mongosh "<replica-set address>&serverSelectionTimeoutMS=3000" 03_failover_probe.js`
   After about 10 seconds, stop **whichever member is primary** (the probe prints it):
   - **Graceful stop.** If the primary is 27017: in an **admin** PowerShell, `Stop-Service MongoDB`. If it's 27018 or 27019: press **Ctrl+C** in that window.
   - **Crash** (run the probe again): in an admin PowerShell, find the process and kill it. Use the primary's port:
     ```powershell
     Stop-Process -Id (Get-NetTCPConnection -LocalPort 27018 -State Listen).OwningProcess -Force
     ```
5. **Demo 3, recovery.** Run `mongosh "mongodb://localhost:27019/?directConnection=true" 04_member_status.js` (any running member). Restart the stopped member with `Start-Service MongoDB`, or rerun its `.bat`. Run `04_member_status.js` again: the old primary is back as a **SECONDARY**, with the same record count.
6. **Demo 4, no majority.** Stop two members, then connect to the survivor:
   `mongosh "mongodb://localhost:<survivor port>/?directConnection=true" 05_no_majority.js`
   Restart both members afterwards.
7. **Demo 5, consistency** (all 3 running):
   `mongosh "<replica-set address>" 06_consistency_demo.js`
   This takes about 1 minute. It temporarily makes 27019 a 20-second-delayed member and restores it at the end.
8. **Return to one member** (all 3 running):
   `mongosh "mongodb://localhost:27017,localhost:27018,localhost:27019/?replicaSet=rs0" 07_back_to_single_member.js`
   Then press Ctrl+C in the two member windows. ⚠️ **Don't skip this.** With 3 members configured, your MongoDB service alone has only 1 of 3 votes. It could never become primary again, and Compass and the Portfolio 4 scripts would stop accepting writes.
9. **Sharding simulation** (MySQL Workbench, run the whole file): `sharding/shard_key_simulation.sql`. It takes about 10 s.

**Screenshots worth taking:**
- Compass connected to the replica-set address, showing 3 members.
- The probe output at the moment the primary changes.
- `04_member_status.js` while a member is down.
- The "WRITE: REFUSED" line in Demo 4.
- The stale balance in Demo 5.
- The summary table from the sharding simulation.

## Part A: replication and availability (results)

### Demo 1: replication ([evidence](evidence/02_replication_output.txt))
- After `01_add_members.js`, **every member holds a full copy**: 10,002 customers and 515,002 transactions on each of the three. The new members copied everything by **initial sync** in about 20 s ([evidence](evidence/01_add_members_output.txt)).
- A record written on the primary was found on both secondaries **within a few milliseconds**.
- The write travelled as an **oplog** entry (`op: 'i'`, an insert into `arcledger.rs_demo`). Secondaries continuously copy the primary's oplog and replay it. Replication lag after fresh heartbeats was **0 s**.

### Demo 2: failover while the "bank app" keeps writing
The probe writes once a second with `w: "majority"` and records which member is primary.

| | Graceful stop (service stop / Ctrl+C) ([evidence](evidence/03a_failover_graceful_output.txt)) | Crash (process killed) ([evidence](evidence/03b_failover_crash_output.txt)) |
|---|---|---|
| Primary | 27017 → **27018** | 27018 → **27017** |
| Writes attempted / succeeded / failed | 40 / **40** / 0 | 34 / 31 / **3** |
| Longest gap with no successful write | **1.4 s** | **10.8 s** |
| Acknowledged writes lost | **0** | **0** |

**Why the difference:** a graceful shutdown makes the primary **step down and hand over** before exiting, so a secondary is elected almost immediately. After a crash, nobody announces anything. The others only notice when the primary stops answering heartbeats, and they call an election after the **election timeout (10 s by default)**. In both cases the application recovered **without any change on its side**: the driver found the new primary by itself. And every acknowledged write survived, because each one had already been copied to a majority.

### Demo 3: recovery ([while down](evidence/04_status_after_failover.txt), [after restart](evidence/05_status_after_recovery.txt))
While 27017 was down, the other two continued (`27018 PRIMARY`, `27019 SECONDARY`, 42 records each). After restart, **27017 rejoined as a SECONDARY**, not as primary, and replayed the writes it had missed. All three showed **42 records** and the same optime.

### Demo 4: no majority, no writes ([evidence](evidence/06_no_majority_output.txt))
With 27017 and 27018 stopped, the survivor 27019 sees **1 of 3 votes, and needs 2**:
- **WRITE: REFUSED (not primary).**
- **READ: allowed**, but possibly **stale**: this member can't know whether newer writes exist elsewhere.

This is the **CAP** choice in action. In a network partition, a minority side doesn't elect its own primary, because two primaries accepting different transfers would split the ledger. MongoDB gives up **write availability** on the minority side to keep **consistency**.

### Demo 5: consistency settings ([evidence](evidence/07_consistency_output.txt))
**Write concern**
| Setting | Acknowledged after | Average latency here | Survives loss of the primary? |
|---|---|---|---|
| `w: 1` | the primary has the write | 5.7 ms | **No.** It's rolled back if the primary dies before replicating it |
| `w: "majority"` | 2 of 3 members have it | 6.7 ms | **Yes** |

On one machine the cost of `majority` is about 1 ms. Across real data centres it's at least one network round trip, which is the latency side of the trade-off.

**Stale read.** Member 27019 was made a 20-second-delayed secondary to make replication lag visible. After a ₦30,000 withdrawal committed with `w: majority`:

| Read from | Balance |
|---|---|
| Primary, `readConcern: local` | 70,000 ✅ |
| Primary, `readConcern: majority` | 70,000 ✅ |
| Lagging secondary, just after the write | **100,000 ❌ stale** |
| Lagging secondary, 22 s later | 70,000 |

**Rule for ArcLedger:** balances that decide whether money can move are read from the **primary**. Secondaries are fine for statements and history, where a few seconds of delay is acceptable.

## Part B: sharding design ([simulation](sharding/shard_key_simulation.sql), [evidence](evidence/09_shard_simulation_output.txt))
**Question:** if ArcLedger outgrew one server and its 515,005 transactions were spread over **8 shards**, which column should decide where each row lives? Each transaction was tagged with the shard it would land on under three candidate keys, and the effects were measured.

| | Hash on `account_id` | Range on `account_id` | Range on transaction date |
|---|---|---|---|
| Rows per shard (min–max) | 64,067 – 64,716 | 63,835 – 64,731 | **1,996 – 500,700** |
| Skew (largest shard ÷ average) | **1.01** | **1.01** | **7.78** |
| Shards one account's statement must visit | **1** | **1** | 2 |
| Shards a one-day report must visit | 8 (all) | 8 (all) | **1** |
| Share of the last 7 days' writes on the busiest shard | **12.8%** (even) | 12.8% | **100%** |
| Transfers whose two accounts sit on different shards | **87.4%** | 87.4% | n/a |

**Findings**
1. **Date makes a bad shard key.** New transactions always carry *today's* date, so **100% of new writes hit the newest shard** while the other seven sit idle: a write **hot spot**. Here it also left one shard with 500,700 of 515,005 rows. The generated data puts almost all activity in the last few months, which exaggerates the effect, but the hot spot follows from any ever-increasing key.
2. **Account-based keys spread both data and writes evenly** (skew 1.01, 12.8% ≈ 1/8 of new writes per shard). They send an account's statement, the most frequent query, to **one shard**. The cost is that reports across all accounts, such as the daily report, become **scatter-gather** queries over all 8 shards. Those belong on a reporting replica or the analytics platform, not the ledger.
3. **Hash vs range on account:** both balance well *here* because account ids are dense. With ranges, though, every *new* account would land on the last range, a smaller version of the date problem. **Hashed** keys avoid that, so the recommendation is **hashed `account_id`** (in MongoDB: `sh.shardCollection("arcledger.transactions", {account_number: "hashed"})`).
4. **The real obstacle: 87.4% of transfers would cross shards.** Close to the 7/8 expected by chance, almost every transfer debits an account on one shard and credits one on another. Keeping that atomic needs a **distributed transaction (two-phase commit)** across shards: slower, and more failure modes. That's the main reason core-banking ledgers are rarely sharded early.

**Recommendation for ArcLedger**
- **Ledger (MySQL):** don't shard yet. Scale up the primary, add read replicas for reads (Part C), and archive old transactions. If sharding ever becomes necessary, shard by **hashed customer or account id**, and design transfers as distributed transactions, or as a two-step debit/credit with a reliable outbox.
- **Read model (MongoDB, Portfolio 4):** shard `transactions` on **hashed `account_number`**. It's read-heavy, statements route to one shard, and MongoDB supports cross-shard transactions when needed.

## Part C: architecture and deployment (design)

### MySQL replication for the ledger
```
            writes (transfers, sp_transfer)               reads (statements, reports)
 Mobile/Web ─────────────────────────────►  PRIMARY  ──binlog──►  REPLICA 1  ◄── daily report (Portfolio 2, Q2)
 app / USSD                              (source)    ──binlog──►  REPLICA 2  ◄── statements, BI, exports
                                            ▲
                                  semi-synchronous ack from ≥1 replica before COMMIT returns
```
- **How it works:** the primary writes every committed change to its **binary log**. Replicas fetch it into a relay log and apply it, much like MongoDB's oplog in Demo 1. With **GTIDs** (global transaction identifiers), each transaction has an ID, so a replica can be promoted and the others re-pointed without working out log positions by hand.
- **Asynchronous replication (default)** returns `COMMIT` before any replica has the change. If the primary crashes, the last transfers can be **lost** on promotion. That's the MySQL equivalent of `w:1`. For a bank, use **semi-synchronous** replication (`AFTER_SYNC`): `COMMIT` returns only after at least one replica has received the change, the equivalent of `w:majority`.
- **Read replicas take the reporting load** away from the primary. The Portfolio 2 daily report (a 515k-row scan before indexing) is exactly that kind of query. But replicas lag, so they give **stale reads** (Demo 5). Anything that checks a balance before moving money, like `sp_transfer`, must run on the primary. Portfolio 3's row locks only exist on the primary anyway.
- **Automatic failover:** plain replication doesn't promote a replica by itself. **MySQL InnoDB Cluster (Group Replication)** adds majority-based agreement and automatic primary election, the same model as the MongoDB replica set: 3 members, a majority is required, and the minority side stops accepting writes.

### CAP / PACELC per component
CAP: during a network **P**artition, choose **C**onsistency or **A**vailability. PACELC adds: **E**lse, in normal operation, choose **L**atency or **C**onsistency.

| Component | Partition (P) → | Normal operation (E) → | Why |
|---|---|---|---|
| Ledger: balances, transfers | **C**: refuse writes without a majority (Demo 4) | **C**: `w:majority` / semi-sync, read from the primary | A wrong balance or a lost transfer is worse than a few seconds of downtime |
| App history and statements (read model) | **A**: serve reads from any reachable member | **L**: read from the nearest secondary, accept seconds of lag | Slightly old history is acceptable; an unavailable app isn't |
| Reporting and analytics | **A** | **L**: reports run on replicas or a separate platform | Yesterday's totals don't need to be up to the millisecond |

### Cloud deployment
- **Managed services** handle replication, backups and patching: for example a managed MySQL with **zone-redundant high availability** (primary and standby in different availability zones of one region), and **MongoDB Atlas**, whose clusters are replica sets (spread across availability zones where the region has them).
- **Availability zones:** the three members in this exercise all ran on **one laptop**, so they share one power supply and one disk. In production, each member goes in a **different availability zone** (separate buildings and power), so a data-centre failure removes one member, not the majority.
- **Recovery targets from the demos:** **RTO** (time to resume writes) ≈ 1.4 s for a planned switchover and ≈ 11 s for a crash. **RPO** (data that may be lost) = **0** for acknowledged writes with `w:majority` / semi-sync.
- **Backups are still required:** replication copies mistakes too. An accidental `DELETE` replicates to every member within milliseconds. Point-in-time backups (or Delta/time travel in an analytics copy) are what undo human error.

### Nigerian data residency
A Central Bank of Nigeria circular of **15 June 2026** requires **payment transaction data generated in Nigeria** to be **stored and managed in Nigeria**, with effect from **1 January 2027**. It covers deposit money banks, microfinance banks, mobile money operators and payment service providers. Transfers out of Nigeria must also meet the adequacy and safeguard rules of the **Nigeria Data Protection Act 2023**. For ArcLedger, that means:
- All replica-set members, replicas and backups holding transaction data must be in **Nigerian data centres**: on-premises, local providers, or in-country cloud infrastructure. A cloud deployment must choose its region and backup location with this in mind, not only for latency and cost.
- Availability zones for the three members must all be **within Nigeria**. Cross-border disaster-recovery copies need a legal basis under the NDPA.

## Limitations
- All three members ran on **one machine**. The demos show the *logic* of replication, elections and consistency, but not real network latency, real partitions or independent hardware failure.
- Sharding was **designed and simulated**, not deployed. A real sharded cluster (config servers, `mongos` routers, shards) would also show chunk balancing and routed vs scatter-gather queries live.
- MySQL replication is **designed**, not deployed. The behaviour described (binlog, semi-sync, lag) mirrors what Demos 1–5 showed in MongoDB.

## Sources
- [The Central Bank of Nigeria's Localisation Directive: Data Protection Compliance Implications (Mondaq)](https://www.mondaq.com/nigeria/financial-services/1823206/the-central-bank-of-nigerias-localisation-directive-data-protection-compliance-implications-for-financial-institutions-and-participants-in-nigerias-payments-ecosystem)
- [Nigeria's payment data must stay onshore by January 2027 (Capacity)](https://capacityglobal.com/news/nigerias-payment-data-must-stay-onshore/)
- [How Nigeria's overlapping data rules affect fintechs and banks (TechCabal)](https://techcabal.com/2026/09/28/how-nigerias-overlapping-data-rules-affect-fintechs-and-banks/)
- MongoDB Manual: Replication, Replica Set Elections, Write Concern, Read Concern, Delayed Replica Set Members, Sharding / Choose a Shard Key: https://www.mongodb.com/docs/manual/
- MySQL 8.0 Reference Manual: Replication, Semisynchronous Replication, GTIDs, Group Replication: https://dev.mysql.com/doc/refman/8.0/en/replication.html

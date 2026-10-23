#!/usr/bin/env python3
"""
ArcLedger - Portfolio 4: migrate the relational data (MySQL) into the
document model (MongoDB).

Reads the SAME ArcLedger database used in Portfolios 1-3 and reshapes it:

  MySQL (6 tables)                       MongoDB (3 collections)
  ---------------------------------      --------------------------------------
  branch                            ->   branches
  customer + account (+ branch copy) ->  customers   (accounts EMBEDDED)
  transactions + transaction_transfer
     + transaction_logs              ->  transactions (transfer + events EMBEDDED)

Run 01_setup.js FIRST (it creates the collections, validators and indexes),
then this script. Every document passes the MongoDB validators on insert;
any MySQL row that breaks a document rule is reported, not silently loaded.

Usage:
  pip install pymysql pymongo
  python migrate_mysql_to_mongo.py --mysql-user root --mysql-password secret
  python migrate_mysql_to_mongo.py --mysql-socket /var/run/mysqld/mysqld.sock --mysql-user root
Options:
  --mongo-uri  (default mongodb://localhost:27017/?directConnection=true)
"""
import argparse, time
from collections import defaultdict
from datetime import datetime, date
from decimal import Decimal

import pymysql
import pymysql.cursors
from bson.decimal128 import Decimal128
from pymongo import MongoClient
from pymongo.errors import BulkWriteError

BATCH = 5000


def dt(v):
    """MySQL DATE -> datetime (BSON has no date-only type)."""
    return datetime(v.year, v.month, v.day) if isinstance(v, date) and not isinstance(v, datetime) else v


def money(v):
    return Decimal128(Decimal(v).quantize(Decimal("0.01")))


def insert(coll, docs, report):
    """insert_many that keeps going past invalid documents and records why they failed."""
    if not docs:
        return
    try:
        coll.insert_many(docs, ordered=False)
        report["inserted"] += len(docs)
    except BulkWriteError as e:
        bad = e.details["writeErrors"]
        report["inserted"] += e.details["nInserted"]
        report["rejected"] += len(bad)
        for err in bad[:5 - len(report["examples"])]:
            report["examples"].append(f"_id={docs[err['index']]['_id']}: {err['errmsg'][:160]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mysql-host", default="localhost")
    ap.add_argument("--mysql-port", type=int, default=3306)
    ap.add_argument("--mysql-user", default="root")
    ap.add_argument("--mysql-password", default="")
    ap.add_argument("--mysql-socket")
    ap.add_argument("--mongo-uri", default="mongodb://localhost:27017/?directConnection=true")
    a = ap.parse_args()

    kw = dict(user=a.mysql_user, password=a.mysql_password, database="arcledger")
    kw.update(unix_socket=a.mysql_socket) if a.mysql_socket else kw.update(host=a.mysql_host, port=a.mysql_port)
    my = pymysql.connect(**kw)
    mdb = MongoClient(a.mongo_uri)["arcledger"]

    if not set(["branches", "customers", "transactions"]) <= set(mdb.list_collection_names()):
        raise SystemExit("Run 01_setup.js first - the collections and validators do not exist yet.")
    for c in ("branches", "customers", "transactions"):
        mdb[c].delete_many({})                    # keep validators and indexes, replace the data

    t_start = time.time()
    reports = {c: {"inserted": 0, "rejected": 0, "examples": []} for c in ("branches", "customers", "transactions")}

    # ---------- 1. branches ----------
    cur = my.cursor()
    cur.execute("SELECT branch_id, branch_name, city, state FROM branch ORDER BY branch_id")
    branches = {r[0]: r for r in cur.fetchall()}
    insert(mdb.branches, [{"_id": b[0], "branch_name": b[1], "city": b[2], "state": b[3]}
                          for b in branches.values()], reports["branches"])

    # ---------- 2. customers with embedded accounts ----------
    cur.execute("""SELECT customer_id, account_number, account_type, balance, status, opened_date, branch_id
                   FROM account ORDER BY customer_id, account_id""")
    accounts = defaultdict(list)
    for cid, num, typ, bal, status, opened, bid in cur.fetchall():
        b = branches[bid]
        accounts[cid].append({
            "account_number": num, "account_type": typ, "balance": money(bal), "status": status,
            "opened_date": dt(opened),
            "branch": {"branch_id": b[0], "branch_name": b[1], "city": b[2]}   # extended reference (copy)
        })
    cur.execute("""SELECT customer_id, first_name, last_name, bvn, phone, email, date_of_birth
                   FROM customer ORDER BY customer_id""")
    batch = []
    for cid, fn, ln, bvn, phone, email, dob in cur.fetchall():
        doc = {"_id": cid, "first_name": fn, "last_name": ln, "bvn": bvn, "phone": phone,
               "date_of_birth": dt(dob), "accounts": accounts.get(cid, [])}
        if email is not None:
            doc["email"] = email                  # absent rather than null
        batch.append(doc)
        if len(batch) == BATCH:
            insert(mdb.customers, batch, reports["customers"]); batch = []
    insert(mdb.customers, batch, reports["customers"])

    # ---------- 3. transactions with embedded transfer + events ----------
    # Two ordered streams (transactions and logs) merged on transaction_id,
    # using server-side cursors so 1.5M rows never sit in memory at once.
    tx = my.cursor(pymysql.cursors.SSCursor)
    tx.execute("""SELECT t.transaction_id, t.transaction_ref, src.account_number, t.transaction_type,
                         t.amount, t.status, t.transaction_date, dst.account_number
                  FROM transactions t
                  JOIN account src ON src.account_id = t.account_id
                  LEFT JOIN transaction_transfer tt ON tt.transaction_id = t.transaction_id
                  LEFT JOIN account dst ON dst.account_id = tt.destination_account_id
                  ORDER BY t.transaction_id""")
    my2 = pymysql.connect(**kw)
    lg = my2.cursor(pymysql.cursors.SSCursor)
    lg.execute("""SELECT transaction_id, event, message, log_time
                  FROM transaction_logs ORDER BY transaction_id, log_id""")
    pending_log = lg.fetchone()

    batch = []
    for tid, ref, acc, typ, amt, status, when, dest in tx:
        events = []
        while pending_log is not None and pending_log[0] < tid:
            pending_log = lg.fetchone()           # orphan log (cannot happen with the FK)
        while pending_log is not None and pending_log[0] == tid:
            ev = {"event": pending_log[1], "at": pending_log[3]}
            if pending_log[2] is not None:
                ev["message"] = pending_log[2]
            events.append(ev)
            pending_log = lg.fetchone()
        doc = {"_id": tid, "transaction_ref": ref, "account_number": acc, "type": typ,
               "amount": money(amt), "status": status, "transaction_date": when, "events": events}
        if dest is not None:
            doc["transfer"] = {"destination_account_number": dest}
        batch.append(doc)
        if len(batch) == BATCH:
            insert(mdb.transactions, batch, reports["transactions"]); batch = []
    insert(mdb.transactions, batch, reports["transactions"])

    # ---------- 4. report ----------
    took = time.time() - t_start
    cur.execute("SELECT (SELECT COUNT(*) FROM branch), (SELECT COUNT(*) FROM customer), (SELECT COUNT(*) FROM account),"
                " (SELECT COUNT(*) FROM transactions), (SELECT COUNT(*) FROM transaction_transfer),"
                " (SELECT COUNT(*) FROM transaction_logs), (SELECT SUM(balance) FROM account)")
    nb, nc, na, nt, ntt, nl, total_mysql = cur.fetchone()

    m_accounts = next(mdb.customers.aggregate([{"$project": {"n": {"$size": "$accounts"}}},
                                               {"$group": {"_id": None, "n": {"$sum": "$n"}}}]), {"n": 0})["n"]
    m_transfers = mdb.transactions.count_documents({"transfer": {"$exists": True}})
    m_events = next(mdb.transactions.aggregate([{"$project": {"n": {"$size": "$events"}}},
                                                {"$group": {"_id": None, "n": {"$sum": "$n"}}}]), {"n": 0})["n"]
    total_mongo = next(mdb.customers.aggregate([{"$unwind": "$accounts"},
                                                {"$group": {"_id": None, "t": {"$sum": "$accounts.balance"}}}]))["t"]

    print(f"Migration finished in {took:.1f} s\n")
    print(f"{'MySQL table(s)':38} {'MySQL rows':>11}   {'MongoDB':>11}  where")
    rows = [("branch", nb, mdb.branches.count_documents({}), "branches documents"),
            ("customer", nc, mdb.customers.count_documents({}), "customers documents"),
            ("account", na, m_accounts, "embedded in customers.accounts[]"),
            ("transactions", nt, mdb.transactions.count_documents({}), "transactions documents"),
            ("transaction_transfer", ntt, m_transfers, "embedded transactions.transfer"),
            ("transaction_logs", nl, m_events, "embedded transactions.events[]")]
    for name, x, y, where in rows:
        print(f"{name:38} {x:>11,}   {y:>11,}  {where}  {'OK' if x == y else 'DIFFERENT'}")
    print(f"\nSum of all balances  MySQL: {total_mysql:,.2f}   MongoDB: {Decimal(str(total_mongo)):,.2f}"
          f"   {'OK' if Decimal(str(total_mongo)) == total_mysql else 'DIFFERENT'}")
    print("\nDocuments rejected by the MongoDB validators:")
    for c, r in reports.items():
        print(f"  {c:13} {r['rejected']}")
        for ex in r["examples"]:
            print(f"      {ex}")


if __name__ == "__main__":
    main()

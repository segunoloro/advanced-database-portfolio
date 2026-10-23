#!/usr/bin/env python3
"""
Stress test for sp_transfer: many sessions transferring money between
Alice and Bola in BOTH directions at the same time.

If sp_transfer's locking is correct:
  * no deadlocks (it always locks the lower account_id first)
  * no lost updates (both rows are locked with SELECT ... FOR UPDATE)
  * total money is conserved: Alice + Bola = N200,000 at the end
  * each balance equals what its transaction history says
  * no balance ever goes negative ("Insufficient funds" instead)

Usage:
  python stress_test.py --user root --password secret
  python stress_test.py --socket /var/run/mysqld/mysqld.sock --user root
"""
import argparse, random, threading, time
from collections import Counter
import pymysql

A, B = "9000000001", "9000000002"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="")
    ap.add_argument("--socket")
    ap.add_argument("--threads", type=int, default=10)
    ap.add_argument("--transfers", type=int, default=50, help="per thread")
    a = ap.parse_args()
    kw = dict(user=a.user, password=a.password, database="arcledger", autocommit=True)
    kw.update(unix_socket=a.socket) if a.socket else kw.update(host=a.host, port=a.port)

    admin = pymysql.connect(**kw)
    cur = admin.cursor()
    cur.execute("CALL sp_reset_demo()")
    print(f"Start: Alice 100,000 + Bola 100,000 = 200,000")
    print(f"{a.threads} sessions x {a.transfers} transfers each, random direction, N1,000-N30,000\n")

    outcomes, errors, lock = Counter(), Counter(), threading.Lock()

    def worker(seed):
        rnd = random.Random(seed)
        conn = pymysql.connect(**kw)
        c = conn.cursor()
        for _ in range(a.transfers):
            src, dst = (A, B) if rnd.random() < 0.5 else (B, A)
            amount = rnd.randint(1, 30) * 1000
            try:
                c.callproc("sp_transfer", (src, dst, amount))
                row = c.fetchone()
                while c.nextset():
                    pass
                with lock:
                    outcomes[row[0] if row[0] == "COMMITTED" else f"ROLLED BACK: {row[2]}"] += 1
            except pymysql.err.MySQLError as e:
                with lock:
                    errors[f"{e.args[0]}: {e.args[1]}"] += 1
        conn.close()

    t0 = time.time()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(a.threads)]
    for t in threads: t.start()
    for t in threads: t.join()
    took = time.time() - t0

    cur.execute("SELECT account_number, balance FROM account WHERE account_number IN (%s, %s) ORDER BY account_number", (A, B))
    bal = dict(cur.fetchall())
    cur.execute("""
        SELECT a.account_number,
               COALESCE((SELECT SUM(CASE WHEN t.transaction_type = 'DEPOSIT' THEN t.amount ELSE -t.amount END)
                         FROM transactions t WHERE t.account_id = a.account_id AND t.status = 'SUCCESSFUL'), 0)
             + COALESCE((SELECT SUM(t.amount) FROM transaction_transfer tt JOIN transactions t ON t.transaction_id = tt.transaction_id
                         WHERE tt.destination_account_id = a.account_id AND t.status = 'SUCCESSFUL'), 0)
        FROM account a WHERE a.account_number IN (%s, %s) ORDER BY a.account_number""", (A, B))
    rebuilt = dict(cur.fetchall())

    total = a.threads * a.transfers
    print(f"Finished {total} transfer attempts in {took:.1f} s\n")
    print("Outcomes:")
    for k, v in outcomes.most_common():
        print(f"  {v:5d}  {k}")
    print(f"Database errors (deadlocks, lock timeouts): {sum(errors.values())}")
    for k, v in errors.items():
        print(f"  {v:5d}  {k}")
    print()
    print(f"Alice: {bal[A]:>12,.2f}   rebuilt from history: {rebuilt[A]:>12,.2f}   {'OK' if bal[A] == rebuilt[A] else 'MISMATCH'}")
    print(f"Bola:  {bal[B]:>12,.2f}   rebuilt from history: {rebuilt[B]:>12,.2f}   {'OK' if bal[B] == rebuilt[B] else 'MISMATCH'}")
    print(f"Total: {bal[A] + bal[B]:>12,.2f}   (must be 200,000.00)  {'OK' if bal[A] + bal[B] == 200000 else 'MONEY CREATED OR LOST'}")
    print(f"Any negative balance: {'YES' if min(bal.values()) < 0 else 'no'}")


if __name__ == "__main__":
    main()

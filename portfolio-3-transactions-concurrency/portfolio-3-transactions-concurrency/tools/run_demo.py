#!/usr/bin/env python3
"""
Replay a two-session demo with REAL concurrent connections and print a
transcript (the evidence files in ../evidence were produced with this).

It reads demos/<demo>/session1.sql and session2.sql, splits them on the
"-- STEP n" markers and runs the steps in number order, each on its own
connection. A step that blocks on a lock runs in a background thread; the
transcript shows it WAITING and then RESUMING when the other session
releases the lock - exactly what you see in two Workbench tabs.

Usage:
  pip install pymysql
  python run_demo.py ../demos/demo7_locking_fix --user root --password secret
  python run_demo.py ../demos/demo7_locking_fix --socket /var/run/mysqld/mysqld.sock --user root
"""
import argparse, os, re, threading, time
import pymysql

STEP_RE = re.compile(r"^-- STEP (\d+) \(Session (\d)\)", re.M)


def parse_steps(folder):
    steps = {}
    for fname in sorted(os.listdir(folder)):
        m = re.match(r"session(\d)\.sql$", fname)
        if not m:
            continue
        text = open(os.path.join(folder, fname)).read()
        marks = list(STEP_RE.finditer(text))
        for i, mk in enumerate(marks):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
            block = text[mk.end():end]
            lines = block.splitlines()[1:]                      # drop rest of marker line
            note = " ".join(l[3:] for l in lines if l.startswith("-- "))
            sql = "\n".join(l for l in lines if not l.startswith("--"))
            sql = re.sub(r"\s--[^\n]*", "", sql)                # trailing comments
            stmts = [s.strip() for s in sql.split(";") if s.strip()]
            steps[int(mk.group(1))] = (int(mk.group(2)), note, stmts)
    return dict(sorted(steps.items()))


def fmt_table(cur):
    if cur.description is None:
        return [f"   OK ({cur.rowcount} row(s) affected)"] if cur.rowcount > 0 else ["   OK"]
    cols = [d[0] for d in cur.description]
    rows = [["NULL" if v is None else str(v) for v in r] for r in cur.fetchall()]
    if cols == ["Type", "Name", "Status"]:                     # SHOW ENGINE INNODB STATUS
        status = rows[0][2]
        m = re.search(r"LATEST DETECTED DEADLOCK\n-+\n(.*?)\n-+\nTRANSACTIONS", status, re.S)
        body = m.group(1) if m else "(no deadlock section found)"
        return ["   LATEST DETECTED DEADLOCK (from SHOW ENGINE INNODB STATUS):"] + \
               ["   | " + l for l in body.splitlines()]
    w = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c) for i, c in enumerate(cols)]
    line = "   +" + "+".join("-" * (x + 2) for x in w) + "+"
    out = [line, "   | " + " | ".join(c.ljust(w[i]) for i, c in enumerate(cols)) + " |", line]
    out += ["   | " + " | ".join(v.ljust(w[i]) for i, v in enumerate(r)) + " |" for r in rows]
    return out + [line]


def run_step(conn, stmts, buf):
    cur = conn.cursor()
    for s in stmts:
        short = " ".join(s.split())
        buf.append(f"  > {short if len(short) < 110 else short[:107] + '...'};")
        t0 = time.time()
        try:
            cur.execute(s)
            while True:
                if cur.description is not None or cur.rowcount > 0:
                    buf.extend(fmt_table(cur))
                if not cur.nextset():
                    break
            took = time.time() - t0
            if took > 0.5:
                buf.append(f"   (this statement waited {took:.1f} s for a lock)")
        except pymysql.err.MySQLError as e:
            buf.append(f"   ERROR {e.args[0]}: {e.args[1]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("demo_folder")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="")
    ap.add_argument("--socket")
    a = ap.parse_args()

    kw = dict(user=a.user, password=a.password, database="arcledger", autocommit=True)
    kw.update(unix_socket=a.socket) if a.socket else kw.update(host=a.host, port=a.port)
    conns = {1: pymysql.connect(**kw), 2: pymysql.connect(**kw)}
    pending = {}                                   # session -> (thread, step, buffer)
    print(f"Demo: {os.path.basename(os.path.abspath(a.demo_folder))}")
    print(f"Two separate connections: Session 1 id={conns[1].thread_id()}, Session 2 id={conns[2].thread_id()}\n")

    def flush_finished():
        for s, (th, n, buf) in list(pending.items()):
            if not th.is_alive():
                print(f"... Session {s}, STEP {n} RESUMED - the lock it was waiting for was released:")
                print("\n".join(buf) + "\n")
                del pending[s]

    for n, (s, note, stmts) in parse_steps(a.demo_folder).items():
        if s in pending:                           # a session cannot start a new step while blocked
            pending[s][0].join()
            flush_finished()
        print(f"===== STEP {n}  (Session {s}) =====")
        print(f"  # {note}")
        buf = []
        th = threading.Thread(target=run_step, args=(conns[s], stmts, buf))
        th.start()
        th.join(timeout=2.0)
        time.sleep(0.3)
        if th.is_alive():
            print("\n".join(buf))
            print(f"   ... Session {s} is WAITING for a lock held by the other session ...\n")
            buf.clear()
            pending[s] = (th, n, buf)
        else:
            print("\n".join(buf) + "\n")
        flush_finished()

    for s, (th, n, buf) in list(pending.items()):
        th.join()
    flush_finished()


if __name__ == "__main__":
    main()

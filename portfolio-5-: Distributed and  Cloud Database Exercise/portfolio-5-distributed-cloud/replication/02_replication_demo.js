// =============================================================
// DEMO 1 - REPLICATION: a write on the primary appears on every secondary
// Run (connected to the whole replica set):
//   mongosh "mongodb://localhost:27017,localhost:27018,localhost:27019/arcledger?replicaSet=rs0" 02_replication_demo.js
// =============================================================

db = db.getSiblingDB("arcledger");
const members = rs.status().members;
const primary = members.find(m => m.stateStr === "PRIMARY").name;
print("Primary: " + primary);
print("Secondaries: " + members.filter(m => m.stateStr === "SECONDARY").map(m => m.name).join(", "));

// 1. Every member holds a FULL copy of the ArcLedger data (copied by initial sync)
print("\n-- Full copy of the data on every member --");
members.forEach(m => {
  const conn = new Mongo(`mongodb://${m.name}/?directConnection=true&readPreference=secondaryPreferred`);
  const d = conn.getDB("arcledger");
  print(`  ${m.name.padEnd(18)} ${m.stateStr.padEnd(10)} customers ${d.customers.estimatedDocumentCount()}  ` +
        `transactions ${d.transactions.estimatedDocumentCount()}`);
});

// 2. A new write on the primary - does it reach the secondaries, and how fast?
const ref = "REPL-" + Date.now();
const written = new Date();
db.rs_demo.insertOne({ ref: ref, amount: NumberDecimal("25000.00"), note: "replication test", written_at: written },
                     { writeConcern: { w: 1 } });
print(`\n-- Wrote ${ref} on the primary at ${written.toISOString()} --`);

members.filter(m => m.stateStr === "SECONDARY").forEach(m => {
  const d = new Mongo(`mongodb://${m.name}/?directConnection=true&readPreference=secondary`).getDB("arcledger");
  const t0 = Date.now();
  let doc = null;
  while (!doc && Date.now() - t0 < 10000) { doc = d.rs_demo.findOne({ ref: ref }); if (!doc) sleep(10); }
  print(`  ${m.name.padEnd(18)} ${doc ? "FOUND after " + (Date.now() - t0) + " ms of polling" : "NOT FOUND within 10 s"}`);
});

// 3. The oplog: the replicated log of operations each secondary replays
const oplogEntry = db.getSiblingDB("local").oplog.rs.find({ ns: "arcledger.rs_demo", "o.ref": ref }).limit(1).toArray()[0];
print("\n-- The oplog entry that carried this write to the secondaries --");
printjson({ op: oplogEntry.op, ns: oplogEntry.ns, ts: oplogEntry.ts, wall: oplogEntry.wall, document_ref: oplogEntry.o.ref });

// 4. Replication lag per member (difference between primary and secondary optimes)
// rs.status() learns other members' positions from heartbeats (every ~2 s),
// so wait for fresh heartbeats before comparing optimes.
print("\n-- Replication lag (after fresh heartbeats) --");
sleep(4000);
const st = rs.status();
const pOpt = st.members.find(m => m.stateStr === "PRIMARY").optimeDate;
st.members.forEach(m => print(`  ${m.name.padEnd(18)} ${m.stateStr.padEnd(10)} lag ${(pOpt - m.optimeDate) / 1000} s`));

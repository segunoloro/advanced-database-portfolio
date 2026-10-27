// =============================================================
// DEMO 4 - NO MAJORITY, NO WRITES (consistency chosen over availability)
// Stop TWO of the three members, then connect DIRECTLY to the survivor, e.g.:
//   mongosh "mongodb://localhost:27019/?directConnection=true" 05_no_majority.js
// =============================================================

db = db.getSiblingDB("arcledger");
const hello = db.hello();
print(`Connected to ${hello.me}`);
print(`isWritablePrimary: ${hello.isWritablePrimary}   secondary: ${hello.secondary}`);
print(`Members it can see as up: ${rs.status().members.filter(m => m.health === 1).map(m => m.name).join(", ")}`);
print(`Votes needed for a majority: ${Math.floor(rs.conf().members.filter(m => m.votes > 0).length / 2) + 1}, votes available: ` +
      `${rs.status().members.filter(m => m.health === 1 && rs.conf().members.find(c => c.host === m.name).votes > 0).length}\n`);

// 1. Try to WRITE (e.g. post a transfer) - refused
try {
  db.rs_demo.insertOne({ ref: "NO-MAJORITY-" + Date.now(), amount: NumberDecimal("1000.00") });
  print("WRITE: accepted (unexpected)");
} catch (e) {
  print("WRITE: REFUSED -> " + String(e.message).split("\n")[0]);
}

// 2. Try to READ - still possible, but the data may be stale
try {
  db.getMongo().setReadPref("secondaryPreferred");
  const n = db.rs_demo.countDocuments({});
  const latest = db.rs_demo.find().sort({ _id: -1 }).limit(1).toArray()[0];
  print(`READ:  allowed (readPreference secondaryPreferred) -> ${n} rs_demo records, newest written ${latest ? (latest.at || latest.written_at) : "-"}`);
  print("       (this member cannot know whether newer writes exist elsewhere - the read may be STALE)");
} catch (e) {
  print("READ:  refused -> " + String(e.message).split("\n")[0]);
}

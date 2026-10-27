// =============================================================
// DEMO 5 - CONSISTENCY SETTINGS: write concern and stale reads
// Part A: w:1 vs w:"majority" - when is a write "safe"?
// Part B: a secondary that lags behind returns an OLD balance.
//         Member 27019 is temporarily made a DELAYED member (20 s behind),
//         which makes replication lag visible and repeatable.
//         The original configuration is restored at the end.
// Run (connected to the whole replica set, all 3 members up):
//   mongosh "mongodb://localhost:27017,localhost:27018,localhost:27019/arcledger?replicaSet=rs0" 06_consistency_demo.js
// =============================================================

db = db.getSiblingDB("arcledger");
const DELAY = 20;
const LAG_MEMBER = rs.conf().members.find(m => m.host.endsWith(":27019")).host;
if (rs.status().members.find(m => m.name === LAG_MEMBER).stateStr === "PRIMARY") {
  print(`${LAG_MEMBER} is currently primary - asking it to step down first`);
  try { new Mongo(`mongodb://${LAG_MEMBER}/?directConnection=true`).getDB("admin").runCommand({ replSetStepDown: 30 }); } catch (e) {}
  sleep(15000);
}

// ---------------- Part A: write concern ----------------
print("==== Part A: write concern ====");
function timeWrites(wc, n) {
  const t0 = Date.now();
  for (let i = 0; i < n; i++) db.rs_demo.insertOne({ wc_test: JSON.stringify(wc), i: i, at: new Date() }, { writeConcern: wc });
  return ((Date.now() - t0) / n).toFixed(2);
}
print(`w:1         average ${timeWrites({ w: 1 }, 200)} ms per write  - acknowledged by the primary ONLY`);
print(`w:majority  average ${timeWrites({ w: "majority" }, 200)} ms per write  - acknowledged by 2 of 3 members`);
print("A w:1 write can be LOST if the primary dies before replicating it (it is rolled back when the");
print("old primary rejoins). A w:majority write survives any single-member failure.");

// ---------------- Part B: stale read from a lagging secondary ----------------
print(`\n==== Part B: stale read (${LAG_MEMBER} made ${DELAY} s delayed) ====`);
const original = rs.conf();
try {
  const cfg = rs.conf();
  const m = cfg.members.find(x => x.host === LAG_MEMBER);
  m.priority = 0;                       // a delayed member must never become primary
  m.secondaryDelaySecs = DELAY;
  cfg.version += 1;
  rs.reconfig(cfg);
  sleep(3000);

  const acct = "DEMO-ACCOUNT-1";
  db.rs_demo.updateOne({ acct: acct }, { $set: { acct: acct, balance: NumberDecimal("100000.00") } }, { upsert: true, writeConcern: { w: "majority" } });
  print(`Setup: ${acct} balance = 100,000 (waiting ${DELAY + 2} s so the delayed member has it too)`);
  sleep((DELAY + 2) * 1000);

  // The customer withdraws 30,000 - committed on the primary
  db.rs_demo.updateOne({ acct: acct }, { $inc: { balance: NumberDecimal("-30000.00") } }, { writeConcern: { w: "majority" } });
  print("Customer withdraws 30,000 -> committed with w:majority (primary + one secondary)\n");

  const read = (label, conn, opts) => {
    const d = conn.getDB("arcledger");
    const doc = d.rs_demo.find({ acct: acct }).readConcern(opts.rc || "local").limit(1).toArray()[0];
    print(`  ${label.padEnd(55)} balance ${doc.balance}`);
  };
  read("primary, readConcern local", db.getMongo(), {});
  read("primary, readConcern majority", db.getMongo(), { rc: "majority" });
  const lag = new Mongo(`mongodb://${LAG_MEMBER}/?directConnection=true&readPreference=secondary`);
  read(`lagging secondary ${LAG_MEMBER} (just after the write)`, lag, {});
  print(`\n  ...waiting ${DELAY + 2} s for the delayed secondary to catch up...`);
  sleep((DELAY + 2) * 1000);
  read(`lagging secondary ${LAG_MEMBER} (after catching up)`, lag, {});
  print("\nThe lagging secondary showed the OLD balance (100,000) for a while: a stale read.");
  print("For money, read balances from the primary (or with readConcern majority + causal consistency).");
} finally {
  const cfg = rs.conf();
  const m = cfg.members.find(x => x.host === LAG_MEMBER);
  const o = original.members.find(x => x.host === LAG_MEMBER);
  m.priority = o.priority; m.secondaryDelaySecs = o.secondaryDelaySecs || 0;
  cfg.version += 1;
  rs.reconfig(cfg);
  print(`\nRestored ${LAG_MEMBER}: priority ${m.priority}, secondaryDelaySecs ${m.secondaryDelaySecs}`);
}

// =============================================================
// DEMO 2 - FAILOVER: does the bank keep accepting writes when the primary dies?
// This "probe" acts like the banking app: it writes one record per second and
// prints which member is primary. While it runs, STOP the primary (see README).
// Run (connected to the whole replica set):
//   mongosh "mongodb://localhost:27017,localhost:27018,localhost:27019/arcledger?replicaSet=rs0&serverSelectionTimeoutMS=3000" 03_failover_probe.js
// It runs for 90 seconds, then prints a summary.
// =============================================================

db = db.getSiblingDB("arcledger");
const RUN_SECONDS = (typeof PROBE_SECONDS !== "undefined") ? PROBE_SECONDS : 90;
const runId = "PROBE-" + Date.now();
const log = [];
let lastOk = null, longestGap = 0, ok = 0, failed = 0;
const primariesSeen = [];

print(`Probe ${runId}: one write per second for ${RUN_SECONDS} s. Stop the primary now-ish.\n`);
const end = Date.now() + RUN_SECONDS * 1000;
let seq = 0;
while (Date.now() < end) {
  seq++;
  const t = new Date();
  let primary = "?";
  try {
    const r = db.rs_demo.insertOne({ probe: runId, seq: seq, at: t }, { writeConcern: { w: "majority", wtimeout: 5000 } });
    primary = db.hello().primary;
    ok++;
    if (lastOk) longestGap = Math.max(longestGap, (Date.now() - lastOk) / 1000);
    lastOk = Date.now();
    if (primariesSeen[primariesSeen.length - 1] !== primary) primariesSeen.push(primary);
    print(`${t.toISOString().substr(11, 8)}  #${String(seq).padStart(3)}  OK     primary=${primary}`);
  } catch (e) {
    failed++;
    print(`${t.toISOString().substr(11, 8)}  #${String(seq).padStart(3)}  ERROR  ${String(e.message).split("\n")[0].substr(0, 90)}`);
  }
  const wait = 1000 - (Date.now() - t.getTime());
  if (wait > 0) sleep(wait);
}

print("\n==== Summary ====");
print(`writes attempted : ${seq}`);
print(`writes succeeded : ${ok}`);
print(`writes failed    : ${failed}`);
print(`primaries seen   : ${primariesSeen.join("  ->  ")}`);
print(`longest gap between successful writes: ${longestGap.toFixed(1)} s  (= how long the bank could not accept writes)`);
print(`records stored   : ${db.rs_demo.countDocuments({ probe: runId })} (every acknowledged write survived the failover: ${db.rs_demo.countDocuments({ probe: runId }) === ok})`);

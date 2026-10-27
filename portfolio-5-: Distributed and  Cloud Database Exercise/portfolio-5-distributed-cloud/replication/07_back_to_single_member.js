// =============================================================
// Return rs0 to ONE member (your normal MongoDB service on 27017).
// Why: with 3 members configured, 27017 alone has 1 of 3 votes, so if the
// two extra members are not running it can never become primary - Compass
// and the Portfolio 4 scripts could no longer write.
// Run with ALL THREE members still running:
//   mongosh "mongodb://localhost:27017,localhost:27018,localhost:27019/?replicaSet=rs0" 07_back_to_single_member.js
// Afterwards close the two member windows (Ctrl+C). You can delete
// C:\mongodb-rs if you do not want to repeat the demos.
// =============================================================

const KEEP = /:27017$/;
let st = rs.status();
let primary = st.members.find(m => m.stateStr === "PRIMARY").name;

// The member we keep must be the primary to run the removal
if (!KEEP.test(primary)) {
  print(`Primary is ${primary}; handing over to the 27017 member first...`);
  const cfg = rs.conf();
  cfg.members.forEach(m => { m.priority = KEEP.test(m.host) ? 10 : 1; });
  cfg.version += 1;
  rs.reconfig(cfg);
  for (let i = 0; i < 30; i++) {
    sleep(2000);
    try { primary = rs.status().members.find(m => m.stateStr === "PRIMARY").name; } catch (e) { primary = "?"; }
    if (KEEP.test(primary)) break;
  }
  print(`Primary is now ${primary}`);
  db = new Mongo(`mongodb://${primary}/?directConnection=true`).getDB("admin");
}

rs.conf().members.filter(m => !KEEP.test(m.host)).forEach(m => {
  const r = rs.remove(m.host);
  print(`rs.remove("${m.host}") -> ok: ${r.ok}`);
  sleep(2000);
});
const cfg = rs.conf();
cfg.members.forEach(m => { m.priority = 1; });
cfg.version += 1;
rs.reconfig(cfg);

print("\nrs0 members now:");
rs.status().members.forEach(m => print(`  ${m.name}  ${m.stateStr}`));
print("\nOptional: remove the demo collection with  db.getSiblingDB('arcledger').rs_demo.drop()");

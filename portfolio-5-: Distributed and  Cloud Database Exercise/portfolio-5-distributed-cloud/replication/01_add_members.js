// =============================================================
// ArcLedger - Portfolio 5: grow replica set rs0 from 1 to 3 members
// Before running: start the two extra members (windows\start_member.bat 27018
// and 27019, each in its own window). Your existing MongoDB service is the
// member on 27017.
// Run while connected to the CURRENT primary (27017):
//   mongosh "mongodb://localhost:27017/?directConnection=true" 01_add_members.js
// (Compass: shell tab on your localhost:27017 connection, paste the file.)
// =============================================================

const NEW_PORTS = [27018, 27019];

let cfg = rs.conf();
const first = cfg.members[0].host;                 // e.g. "localhost:27017" or "MY-LAPTOP:27017"
const isLocalName = /^(localhost|127\.0\.0\.1):/.test(first);

// MongoDB requires ALL members to use localhost names, or NONE of them.
// rs.initiate() on Windows often records the computer name, so switch it to localhost.
if (!isLocalName) {
  print(`Member 0 is "${first}" - changing it to "localhost:27017" so all members match.`);
  cfg.members[0].host = "localhost:27017";
  cfg.version += 1;
  rs.reconfig(cfg);
  sleep(3000);
}
const prefix = rs.conf().members[0].host.split(":")[0];   // "localhost" or "127.0.0.1"

NEW_PORTS.forEach(p => {
  const host = `${prefix}:${p}`;
  if (rs.conf().members.some(m => m.host === host)) {
    print(`${host} is already a member`);
  } else {
    const r = rs.add({ host: host });
    print(`rs.add("${host}") -> ok: ${r.ok}`);
  }
});

// Wait for both new members to finish their initial sync (copying all data)
print("\nWaiting for initial sync (copies every database to the new members)...");
const t0 = Date.now();
while (true) {
  const st = rs.status().members.map(m => `${m.name}=${m.stateStr}`);
  const ready = rs.status().members.filter(m => ["PRIMARY", "SECONDARY"].includes(m.stateStr)).length;
  print(`  ${Math.round((Date.now() - t0) / 1000)}s  ${st.join("  ")}`);
  if (ready === 1 + NEW_PORTS.length) break;
  if (Date.now() - t0 > 15 * 60 * 1000) { print("Still syncing after 15 minutes - check the member windows / logs."); break; }
  sleep(5000);
}

print("\nReplica set configuration:");
rs.conf().members.forEach(m =>
  print(`  _id ${m._id}  ${m.host.padEnd(18)} priority ${m.priority}  votes ${m.votes}`));
print("\nMembers:");
rs.status().members.forEach(m =>
  print(`  ${m.name.padEnd(18)} ${m.stateStr.padEnd(10)} health ${m.health}  optime ${m.optimeDate ? m.optimeDate.toISOString() : "-"}`));
print("\nConnect to the whole replica set from now on with:");
print(`  mongodb://${prefix}:27017,${prefix}:27018,${prefix}:27019/arcledger?replicaSet=rs0`);

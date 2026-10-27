// =============================================================
// Member status - run after each step of Demos 2-4 to see who is primary,
// who is down, and whether every member holds the same data.
// Connect DIRECTLY to any member that is still running, e.g.:
//   mongosh "mongodb://localhost:27018/?directConnection=true" 04_member_status.js
// =============================================================

const st = rs.status();
const prim = st.members.find(m => m.stateStr === "PRIMARY");
print(`Checked from: ${db.hello().me}   at ${new Date().toISOString()}`);
print(`Primary now : ${prim ? prim.name : "NONE - no member can reach a majority, so no writes are possible"}\n`);
print("member             state       health  last optime              votes");
st.members.forEach(m => {
  const vote = rs.conf().members.find(c => c.host === m.name).votes;
  print(`${m.name.padEnd(18)} ${m.stateStr.padEnd(11)} ${String(m.health).padEnd(7)} ` +
        `${m.optimeDate && m.optimeDate.getTime() > 0 ? m.optimeDate.toISOString() : "-".padEnd(24)} ${vote}`);
});

// Same data everywhere? Count the probe records on every reachable member.
print("\nrs_demo records on each reachable member (must be equal once all have caught up):");
st.members.filter(m => m.health === 1).forEach(m => {
  try {
    const d = new Mongo(`mongodb://${m.name}/?directConnection=true&readPreference=secondaryPreferred`).getDB("arcledger");
    print(`  ${m.name.padEnd(18)} ${d.rs_demo.countDocuments({})}`);
  } catch (e) { print(`  ${m.name.padEnd(18)} unreachable`); }
});

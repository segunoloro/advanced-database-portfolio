// =============================================================
// ArcLedger - MongoDB at scale (515,000 transaction documents)
// The same kinds of question as Portfolio 2, so the two databases can be
// compared. For each query: the plan (COLLSCAN = full scan, IXSCAN = index),
// documents/keys examined, and the average time of 10 runs after a warm-up.
// Run on the migrated data:
//   mongosh "mongodb://localhost:27017/arcledger?directConnection=true" 06_performance_at_scale.js
// Safe to re-run: it removes the two indexes it adds before measuring.
// =============================================================

db = db.getSiblingDB("arcledger");

// ---- helpers ------------------------------------------------
function findKey(obj, key) {                       // first value of `key` anywhere in a nested object
  if (obj === null || typeof obj !== "object") return undefined;
  if (key in obj) return obj[key];
  for (const k of Object.keys(obj)) { const v = findKey(obj[k], key); if (v !== undefined) return v; }
  return undefined;
}
function planSummary(explainOut) {
  const s = JSON.stringify(explainOut);
  const stages = [...new Set((s.match(/"stage":"(COLLSCAN|IXSCAN|FETCH|OR|SORT|SORT_MERGE|GROUP|EXPRESS_IXSCAN|IDHACK)"/g) || [])
                     .map(x => x.split(":")[1].replace(/"/g, "")))];
  const idx = [...new Set((s.match(/"indexName":"([^"]+)"/g) || []).map(x => x.split(":")[1].replace(/"/g, "")))];
  return { stages: stages.join(", "), indexes: idx.join(", ") || "none",
           docs_examined: findKey(explainOut, "totalDocsExamined"),
           keys_examined: findKey(explainOut, "totalKeysExamined") };
}
function avgMs(fn, runs) {
  fn();                                            // warm-up
  const t0 = Date.now();
  for (let i = 0; i < runs; i++) fn();
  return +((Date.now() - t0) / runs).toFixed(2);
}
const results = [];
function measure(id, title, explainFn, runFn) {
  const r = Object.assign({ query: id, description: title }, planSummary(explainFn()), { avg_ms: avgMs(runFn, 10) });
  results.push(r);
  print("\n==== " + id + " " + title + " ====");
  printjson(r);
}

// ---- start from a clean baseline ----------------------------
["ix_txn_date", "ix_txn_status_date"].forEach(n => { try { db.transactions.dropIndex(n); } catch (e) {} });

const cust = db.customers.findOne({ "accounts.1": { $exists: true } }, { bvn: 1 }, { sort: { _id: 1 } });
const acc  = db.transactions.findOne({ type: "TRANSFER" }, {}, { sort: { _id: 1 } }).transfer.destination_account_number;
const dayOn = ISODate("2026-09-15T00:00:00Z"), dayOff = ISODate("2026-09-16T00:00:00Z");
const weekOn = ISODate("2026-10-09T00:00:00Z"), weekOff = ISODate("2026-10-17T00:00:00Z");
print("Parameters: customer BVN " + cust.bvn + ", account " + acc + ", day 2026-09-15, week 2026-10-09..16");
print("Documents: customers " + db.customers.countDocuments() + ", transactions " + db.transactions.estimatedDocumentCount());

// ---- S1 Customer profile with all accounts --------------------
// MySQL: customer JOIN account JOIN branch (3 tables)
measure("S1", "Customer profile with accounts (by BVN)",
  () => db.customers.find({ bvn: cust.bvn }).explain("executionStats"),
  () => db.customers.findOne({ bvn: cust.bvn }));

// ---- S2 Full statement: money out OR money in ----------------
// MySQL Portfolio 2: OR version was a full scan (117 ms); UNION ALL rewrite 0.1 ms
const stmt = { status: "SUCCESSFUL", $or: [ { account_number: acc }, { "transfer.destination_account_number": acc } ] };
measure("S2", "Full statement with $or (out + in)",
  () => db.transactions.find(stmt).sort({ transaction_date: 1 }).explain("executionStats"),
  () => db.transactions.find(stmt).sort({ transaction_date: 1 }).toArray());

// ---- S3 Daily report - BEFORE a date index --------------------
const daily = [
  { $match: { transaction_date: { $gte: dayOn, $lt: dayOff } } },
  { $group: { _id: { type: "$type", status: "$status" }, n: { $sum: 1 }, total: { $sum: "$amount" } } } ];
measure("S3a", "Daily report - no date index",
  () => db.transactions.explain("executionStats").aggregate(daily),
  () => db.transactions.aggregate(daily).toArray());

// ---- S4 Failure reasons, last 7 days - BEFORE an index --------
const reasons = [
  { $match: { status: "FAILED", transaction_date: { $gte: weekOn, $lt: weekOff } } },
  { $unwind: "$events" }, { $match: { "events.event": "FAILED" } },
  { $group: { _id: "$events.message", n: { $sum: 1 } } } ];
measure("S4a", "Failed in last 7 days, by reason - no index",
  () => db.transactions.explain("executionStats").aggregate(reasons),
  () => db.transactions.aggregate(reasons).toArray());

// ---- add the indexes (same reasoning as Portfolio 2) -----------
db.transactions.createIndex({ transaction_date: 1 }, { name: "ix_txn_date" });
db.transactions.createIndex({ status: 1, transaction_date: 1 }, { name: "ix_txn_status_date" });   // equality first, range last
print("\nCreated indexes: ix_txn_date {transaction_date}, ix_txn_status_date {status, transaction_date}");

measure("S3b", "Daily report - with ix_txn_date",
  () => db.transactions.explain("executionStats").aggregate(daily),
  () => db.transactions.aggregate(daily).toArray());
measure("S4b", "Failed in last 7 days, by reason - with ix_txn_status_date",
  () => db.transactions.explain("executionStats").aggregate(reasons),
  () => db.transactions.aggregate(reasons).toArray());

// ---- storage -------------------------------------------------
print("\n==== Storage ====");
["customers", "transactions"].forEach(c => {
  const s = db.runCommand({ collStats: c });          // all sizes in bytes
  const mb = (b) => +(b / 1024 / 1024).toFixed(1);
  printjson({ collection: c, documents: s.count, avg_doc_bytes: Math.round(s.avgObjSize),
              data_mb_uncompressed: mb(s.size), storage_mb_on_disk_compressed: mb(s.storageSize),
              indexes_mb: mb(s.totalIndexSize) });
});

print("\n==== Summary ====");
results.forEach(r => print(`${r.query.padEnd(4)} ${r.description.padEnd(52)} ${r.stages.padEnd(26)} docs=${String(r.docs_examined).padStart(7)}  ${String(r.avg_ms).padStart(8)} ms`));

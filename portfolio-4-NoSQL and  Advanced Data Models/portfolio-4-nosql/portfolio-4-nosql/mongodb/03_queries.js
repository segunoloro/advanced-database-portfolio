// =============================================================
// ArcLedger - MongoDB queries (evidence for Portfolio 4)
// Works on the migrated data (or on 02_seed.js): example customers,
// accounts and transactions are picked from whatever is loaded.
// Run:  mongosh "mongodb://localhost:27017/arcledger?directConnection=true" 03_queries.js
// (Compass: open the shell tab, `use arcledger`, paste the file.)
// Each query notes the MySQL equivalent for comparison.
// =============================================================

db = db.getSiblingDB("arcledger");
const show = (title, x) => {
  print("\n==== " + title + " ====");
  (Array.isArray(x) ? x : [x]).forEach(d => printjson(d));
};

// Pick real examples from the loaded data
const twoAcctCustomer = db.customers.findOne({ "accounts.1": { $exists: true } });
const sampleTransfer  = db.transactions.findOne({ type: "TRANSFER", status: "SUCCESSFUL" }, {}, { sort: { _id: 1 } });
const acc             = sampleTransfer.transfer.destination_account_number;   // receives transfers
print("Examples used: customer BVN " + twoAcctCustomer.bvn + ", transfer " + sampleTransfer.transaction_ref +
      ", statement account " + acc);

// Q1 Customer profile with all accounts and their branch: ONE read, no join.
//    MySQL: customer JOIN account JOIN branch
show("Q1 Customer profile (single document read)",
  db.customers.findOne({ bvn: twoAcctCustomer.bvn },
                       { _id: 0, first_name: 1, last_name: 1, phone: 1, accounts: 1 }));

// Q2 A transfer with its transfer details and full event history: ONE read.
//    MySQL: transactions JOIN transaction_transfer JOIN transaction_logs
show("Q2 Transfer with details and log events (single document read)",
  db.transactions.findOne({ transaction_ref: sampleTransfer.transaction_ref }, { _id: 0 }));

// Q3 Account statement: money out (it is the source) plus money in (it is
//    a transfer destination), newest first, latest 10.
show("Q3 Statement for " + acc + " (latest 10)",
  db.transactions.aggregate([
    { $match: { status: "SUCCESSFUL",
                $or: [ { account_number: acc }, { "transfer.destination_account_number": acc } ] } },
    { $sort: { transaction_date: -1 } },
    { $limit: 10 },
    { $project: { _id: 0, date: "$transaction_date", ref: "$transaction_ref", type: 1,
                  direction: { $cond: [ { $or: [ { $eq: ["$type", "DEPOSIT"] },
                                                  { $eq: ["$transfer.destination_account_number", acc] } ] },
                                        "CREDIT", "DEBIT" ] },
                  amount: { $toString: "$amount" } } }
  ]).toArray());

// Q4 Failure reasons: $unwind the embedded events array.
//    MySQL: transaction_logs WHERE event = 'FAILED' GROUP BY message
show("Q4 Failure reasons",
  db.transactions.aggregate([
    { $match: { status: "FAILED" } },
    { $unwind: "$events" },
    { $match: { "events.event": "FAILED" } },
    { $group: { _id: "$events.message", count: { $sum: 1 } } },
    { $sort: { count: -1 } },
    { $project: { _id: 0, reason: "$_id", count: 1 } }
  ]).toArray());

// Q5 Transaction volume by type and status (GROUP BY equivalent).
show("Q5 Volume by type and status",
  db.transactions.aggregate([
    { $group: { _id: { type: "$type", status: "$status" }, count: { $sum: 1 }, total: { $sum: "$amount" } } },
    { $project: { _id: 0, type: "$_id.type", status: "$_id.status", count: 1, total: { $toString: "$total" } } },
    { $sort: { type: 1, status: 1 } }
  ]).toArray());

// Q6 Total balances per branch: $unwind embedded accounts. Branch name is
//    already copied into each account, so no lookup is needed.
show("Q6 Total balances by branch (top 5)",
  db.customers.aggregate([
    { $unwind: "$accounts" },
    { $group: { _id: "$accounts.branch.branch_name", accounts: { $sum: 1 }, total: { $sum: "$accounts.balance" } } },
    { $sort: { total: -1 } }, { $limit: 5 },
    { $project: { _id: 0, branch: "$_id", accounts: 1, total: { $toString: "$total" } } }
  ]).toArray());

// Q7 A join IS still possible when needed: $lookup the receiver's name.
show("Q7 Transfers with receiver name via $lookup (first 5)",
  db.transactions.aggregate([
    { $match: { type: "TRANSFER", status: "SUCCESSFUL" } },
    { $sort: { _id: 1 } }, { $limit: 5 },
    { $lookup: { from: "customers", localField: "transfer.destination_account_number",
                 foreignField: "accounts.account_number", as: "receiver" } },
    { $project: { _id: 0, ref: "$transaction_ref", from: "$account_number",
                  to: "$transfer.destination_account_number", amount: { $toString: "$amount" },
                  receiver: { $concat: [ { $first: "$receiver.first_name" }, " ", { $first: "$receiver.last_name" } ] } } }
  ]).toArray());

// Q8 Reconciliation over ALL accounts: stored balance vs balance rebuilt
//    from successful transactions (same check as MySQL V7 in Portfolio 1).
const cents = (d) => Math.round(parseFloat(d.toString()) * 100);
const rebuilt = {};
db.transactions.aggregate([
  { $match: { status: "SUCCESSFUL" } },
  { $project: { legs: { $concatArrays: [
      [ { acc: "$account_number",
          amt: { $cond: [{ $eq: ["$type", "DEPOSIT"] }, "$amount", { $multiply: ["$amount", -1] }] } } ],
      { $cond: [{ $eq: ["$type", "TRANSFER"] },
                [ { acc: "$transfer.destination_account_number", amt: "$amount" } ], [] ] } ] } } },
  { $unwind: "$legs" },
  { $group: { _id: "$legs.acc", net: { $sum: "$legs.amt" } } }
], { allowDiskUse: true }).forEach(r => { rebuilt[r._id] = cents(r.net); });
let ok = 0, bad = [];
db.customers.find({}, { accounts: 1 }).forEach(c => c.accounts.forEach(a => {
  (cents(a.balance) === (rebuilt[a.account_number] || 0)) ? ok++
    : bad.push({ account: a.account_number, stored: a.balance.toString(),
                 from_transactions: ((rebuilt[a.account_number] || 0) / 100).toFixed(2) });
}));
show("Q8 Balance reconciliation, all accounts",
     { accounts_ok: ok, accounts_mismatch: bad.length, mismatches: bad.slice(0, 5) });

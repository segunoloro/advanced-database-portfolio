// =============================================================
// ArcLedger - MongoDB sample data (same data as MySQL 02_seed.sql)
// Run AFTER 01_setup.js:  mongosh arcledger 02_seed.js
// =============================================================

db = db.getSiblingDB("arcledger");
const D = (v) => NumberDecimal(String(v));      // money helper

// -------------------------------------------------------------
// 1. Branches
// -------------------------------------------------------------
const branches = [
  { _id: 1, branch_name: "Ikeja Allen Avenue", city: "Ikeja", state: "Lagos" },
  { _id: 2, branch_name: "Victoria Island",    city: "Lagos", state: "Lagos" },
  { _id: 3, branch_name: "Abuja Wuse II",      city: "Abuja", state: "FCT"   }
];
db.branches.insertMany(branches);

// Extended reference: copy of the branch fields an account needs
const br = (id) => {
  const b = branches.find(x => x._id === id);
  return { branch_id: b._id, branch_name: b.branch_name, city: b.city };
};
const acct = (number, type, branchId, opened) => ({
  account_number: number, account_type: type, balance: D(0),
  status: "ACTIVE", opened_date: ISODate(opened), branch: br(branchId)
});

// -------------------------------------------------------------
// 2. Customers with their accounts embedded
//    (balances start at 0 and are calculated in step 4)
// -------------------------------------------------------------
db.customers.insertMany([
  { _id: 1, first_name: "Adaeze", last_name: "Nwosu", bvn: "22100000001", phone: "+2348030000001",
    email: "adaeze.nwosu@mail.example", date_of_birth: ISODate("1990-04-12"),
    accounts: [ acct("0123456781", "SAVINGS", 1, "2026-01-15"),
                acct("0123456782", "CURRENT", 1, "2026-03-02") ] },     // 1 customer -> many accounts
  { _id: 2, first_name: "Tunde", last_name: "Afolabi", bvn: "22100000002", phone: "+2348030000002",
    email: "tunde.afolabi@mail.example", date_of_birth: ISODate("1985-11-30"),
    accounts: [ acct("0123456783", "CURRENT", 2, "2026-02-10") ] },
  { _id: 3, first_name: "Ibrahim", last_name: "Bello", bvn: "22100000003", phone: "+2348030000003",
    date_of_birth: ISODate("1998-01-22"),                                 // no email: field simply absent
    accounts: [ acct("0123456784", "SAVINGS", 3, "2026-05-20") ] },
  { _id: 4, first_name: "Chioma", last_name: "Okeke", bvn: "22100000004", phone: "+2348030000004",
    email: "chioma.okeke@mail.example", date_of_birth: ISODate("1993-07-08"),
    accounts: [ acct("0123456785", "SAVINGS", 1, "2026-06-01") ] },
  { _id: 5, first_name: "Bayo", last_name: "Ogunleye", bvn: "22100000005", phone: "+2348030000005",
    date_of_birth: ISODate("1979-02-14"),
    accounts: [ acct("0123456786", "CURRENT", 2, "2026-07-07") ] }
]);

// -------------------------------------------------------------
// 3. Transactions: transfer details and log events embedded
// -------------------------------------------------------------
const txn = (id, ref, account, type, amount, status, when, dest, failReason) => {
  const at = ISODate(when);
  const doc = {
    _id: id, transaction_ref: ref, account_number: account, type: type,
    amount: D(amount), status: status, transaction_date: at,
    events: [
      { event: "INITIATED", message: type + " request received", at: at },
      { event: status, message: status === "FAILED" ? failReason : "Completed",
        at: new Date(at.getTime() + 2000) }
    ]
  };
  if (dest) doc.transfer = { destination_account_number: dest };   // only transfers get this
  return doc;
};

db.transactions.insertMany([
  txn(1,  "TXN20261001001", "0123456781", "DEPOSIT",    500000,  "SUCCESSFUL", "2026-10-01T09:15:00Z"),
  txn(2,  "TXN20261001002", "0123456783", "DEPOSIT",    250000,  "SUCCESSFUL", "2026-10-01T10:02:00Z"),
  txn(3,  "TXN20261001003", "0123456784", "DEPOSIT",     40000,  "SUCCESSFUL", "2026-10-01T11:30:00Z"),
  txn(4,  "TXN20261001004", "0123456785", "DEPOSIT",     80000,  "SUCCESSFUL", "2026-10-01T12:45:00Z"),
  txn(5,  "TXN20261001005", "0123456786", "DEPOSIT",   1200000,  "SUCCESSFUL", "2026-10-01T14:00:00Z"),
  txn(6,  "TXN20261002006", "0123456781", "TRANSFER",    75000,  "SUCCESSFUL", "2026-10-02T08:20:00Z", "0123456783"),
  txn(7,  "TXN20261002007", "0123456781", "TRANSFER",   100000,  "SUCCESSFUL", "2026-10-02T08:25:00Z", "0123456782"),
  txn(8,  "TXN20261002008", "0123456783", "WITHDRAWAL",  20000,  "SUCCESSFUL", "2026-10-02T17:40:00Z"),
  txn(9,  "TXN20261003009", "0123456784", "TRANSFER",    60000,  "FAILED",     "2026-10-03T13:05:00Z", "0123456785", "Insufficient funds"),
  txn(10, "TXN20261003010", "0123456786", "TRANSFER",   150000,  "SUCCESSFUL", "2026-10-03T15:10:00Z", "0123456785"),
  txn(11, "TXN20261004011", "0123456785", "WITHDRAWAL",  30000,  "SUCCESSFUL", "2026-10-04T09:00:00Z")
]);

// -------------------------------------------------------------
// 4. Balances = net of successful transactions (same rule as MySQL)
//    One aggregation computes the net movement per account number.
// -------------------------------------------------------------
const net = db.transactions.aggregate([
  { $match: { status: "SUCCESSFUL" } },
  { $project: { legs: { $concatArrays: [
      [ { acc: "$account_number",
          amt: { $cond: [{ $eq: ["$type", "DEPOSIT"] }, "$amount", { $multiply: ["$amount", -1] }] } } ],
      { $cond: [{ $eq: ["$type", "TRANSFER"] },
                [ { acc: "$transfer.destination_account_number", amt: "$amount" } ], [] ] }
  ] } } },
  { $unwind: "$legs" },
  { $group: { _id: "$legs.acc", balance: { $sum: "$legs.amt" } } }
]).toArray();

net.forEach(r => db.customers.updateOne(
  { "accounts.account_number": r._id },
  { $set: { "accounts.$.balance": r.balance } }      // positional $ = the matching array element
));

print("branches: "     + db.branches.countDocuments());
print("customers: "    + db.customers.countDocuments());
print("transactions: " + db.transactions.countDocuments());
db.customers.aggregate([
  { $unwind: "$accounts" },
  { $project: { _id: 0, name: "$first_name", account: "$accounts.account_number",
                type: "$accounts.account_type", balance: { $toString: "$accounts.balance" } } }
]).forEach(r => print(JSON.stringify(r)));

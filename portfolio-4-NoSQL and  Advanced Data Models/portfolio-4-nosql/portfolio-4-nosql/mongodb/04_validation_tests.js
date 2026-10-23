// =============================================================
// ArcLedger - MongoDB negative tests
// Every write below SHOULD be rejected by a validator or a unique index.
// Duplicate values are looked up from the loaded data, so this works on
// the migrated data or on 02_seed.js.
// Run:  mongosh "mongodb://localhost:27017/arcledger?directConnection=true" 04_validation_tests.js
// =============================================================

db = db.getSiblingDB("arcledger");
const D = (v) => NumberDecimal(String(v));
let passed = 0, total = 0;

function expectFail(label, fn) {
  total++;
  try {
    fn();
    print("FAIL  " + label + "  -> was ACCEPTED (should have been rejected)");
  } catch (e) {
    passed++;
    const why = e.code === 11000 ? "duplicate key (unique index)" :
                e.code === 121   ? "document failed validation" : e.message;
    print("PASS  " + label + "  -> rejected: " + why);
  }
}

// Real values to duplicate
const c1   = db.customers.findOne({ "accounts.0": { $exists: true } }, {}, { sort: { _id: 1 } });
const acct = c1.accounts[0].account_number;
const ref  = db.transactions.findOne({}, { transaction_ref: 1 }, { sort: { _id: 1 } }).transaction_ref;
const branch0 = db.branches.findOne({}, {}, { sort: { _id: 1 } });
let nextId = 2000000000;                                  // ids far above any real one
const newCustomer = (changes) => Object.assign({
  _id: nextId++, first_name: "Test", last_name: "Person", bvn: "99999999999", phone: "+2340000000001",
  date_of_birth: new Date("1990-01-01"), accounts: [] }, changes);
const goodTxn = (changes) => Object.assign({
  _id: nextId++, transaction_ref: "TEST-" + nextId, account_number: acct, type: "DEPOSIT",
  amount: D(100), status: "SUCCESSFUL", transaction_date: new Date(),
  events: [{ event: "INITIATED", at: new Date() }] }, changes);
print("Duplicating: BVN " + c1.bvn + ", phone " + c1.phone + ", account " + acct + ", reference " + ref + "\n");

// --- customers --------------------------------------------------
expectFail("T01 BVN with letters",           () => db.customers.insertOne(newCustomer({ bvn: "22100A" })));
expectFail("T02 Duplicate BVN",              () => db.customers.insertOne(newCustomer({ bvn: c1.bvn })));
expectFail("T03 Duplicate phone",            () => db.customers.insertOne(newCustomer({ phone: c1.phone })));
expectFail("T04 Missing required field (phone)", () => {
  const d = newCustomer({}); delete d.phone; db.customers.insertOne(d); });
expectFail("T05 Account number already held by another customer", () =>
  db.customers.insertOne(newCustomer({ accounts: [{ account_number: acct, account_type: "SAVINGS", balance: D(0),
    status: "ACTIVE", opened_date: new Date(),
    branch: { branch_id: branch0._id, branch_name: branch0.branch_name, city: branch0.city } }] })));

const mustModify = (filter, update) => {
  const r = db.customers.updateOne(filter, update);
  if (r.modifiedCount === 0) throw new Error("not modified");
};
expectFail("T06 Negative account balance",   () => mustModify({ "accounts.account_number": acct }, { $set: { "accounts.$.balance": D(-1) } }));
expectFail("T07 Invalid account type",       () => mustModify({ "accounts.account_number": acct }, { $set: { "accounts.$.account_type": "CRYPTO" } }));
expectFail("T08 Balance as float, not Decimal128", () => mustModify({ "accounts.account_number": acct }, { $set: { "accounts.$.balance": 40000.10 } }));

// --- transactions ------------------------------------------------
expectFail("T09 Zero amount",               () => db.transactions.insertOne(goodTxn({ amount: D(0) })));
expectFail("T10 Negative amount",           () => db.transactions.insertOne(goodTxn({ amount: D(-500) })));
expectFail("T11 Unknown type",              () => db.transactions.insertOne(goodTxn({ type: "LOAN" })));
expectFail("T12 Duplicate reference",       () => db.transactions.insertOne(goodTxn({ transaction_ref: ref })));
expectFail("T13 TRANSFER without transfer details", () => db.transactions.insertOne(goodTxn({ type: "TRANSFER" })));
expectFail("T14 DEPOSIT carrying transfer details", () =>
  db.transactions.insertOne(goodTxn({ transfer: { destination_account_number: "1234567890" } })));
expectFail("T15 Transfer to the same account", () =>
  db.transactions.insertOne(goodTxn({ type: "TRANSFER", transfer: { destination_account_number: acct } })));
expectFail("T16 Transaction with no events", () => db.transactions.insertOne(goodTxn({ events: [] })));

// --- the gap: what MongoDB does NOT check -----------------------
print("\n-- Known gap: no foreign keys in MongoDB --");
const orphan = goodTxn({ account_number: "0000000000" });
db.transactions.insertOne(orphan);
print("ACCEPTED: a transaction for account 0000000000, which does not exist. MySQL's foreign key rejects this.");
db.transactions.deleteOne({ _id: orphan._id });

print("\n" + passed + " of " + total + " invalid writes rejected");
print("Test documents left behind: " +
      (db.customers.countDocuments({ _id: { $gte: 2000000000 } }) + db.transactions.countDocuments({ _id: { $gte: 2000000000 } })));

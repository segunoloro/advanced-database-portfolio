// =============================================================
// ArcLedger - Funds transfer as a multi-document ACID transaction
// A transfer between two customers changes TWO customer documents and
// inserts ONE transaction document - all three succeed or none do.
// Needs a replica set (see README). Works on the migrated data or 02_seed.js.
// Run:  mongosh "mongodb://localhost:27017/arcledger?directConnection=true" 05_transfer_transaction.js
// =============================================================

db = db.getSiblingDB("arcledger");
const D = (v) => NumberDecimal(String(v));

// Two ACTIVE accounts of two DIFFERENT customers, each with at least N100,000
const pick = db.customers.aggregate([
  { $unwind: "$accounts" },
  { $match: { "accounts.status": "ACTIVE", "accounts.balance": { $gte: D(100000) } } },
  { $sort: { _id: 1 } }, { $limit: 50 },
  { $group: { _id: "$_id", acc: { $first: "$accounts.account_number" }, name: { $first: "$first_name" } } },
  { $sort: { _id: 1 } }, { $limit: 2 }
]).toArray();
const A = pick[0].acc, B = pick[1].acc;
print("Sender:   " + pick[0].name + " " + A + "  (customer " + pick[0]._id + ")");
print("Receiver: " + pick[1].name + " " + B + "  (customer " + pick[1]._id + ")\n");

function balanceOf(accountNumber) {
  const c = db.customers.findOne({ "accounts.account_number": accountNumber }, { "accounts.$": 1 });
  return c.accounts[0].balance.toString();
}

function transfer(ref, fromAcc, toAcc, amount) {
  const session = db.getMongo().startSession();
  const cust = session.getDatabase("arcledger").customers;
  const txns = session.getDatabase("arcledger").transactions;
  const now = new Date();
  session.startTransaction({ readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
  try {
    // 1. Debit sender ONLY if the balance covers it (check + update in one atomic step)
    const debit = cust.updateOne(
      { accounts: { $elemMatch: { account_number: fromAcc, status: "ACTIVE", balance: { $gte: D(amount) } } } },
      { $inc: { "accounts.$.balance": D(-amount) } });
    if (debit.modifiedCount !== 1) throw new Error("Insufficient funds or inactive account");

    // 2. Credit receiver
    const credit = cust.updateOne(
      { accounts: { $elemMatch: { account_number: toAcc, status: "ACTIVE" } } },
      { $inc: { "accounts.$.balance": D(amount) } });
    if (credit.modifiedCount !== 1) throw new Error("Destination account not found");

    // 3. Record the transaction with its events
    const lastId = txns.find().sort({ _id: -1 }).limit(1).toArray()[0]._id;
    txns.insertOne({
      _id: lastId + 1, transaction_ref: ref, account_number: fromAcc, type: "TRANSFER",
      amount: D(amount), status: "SUCCESSFUL", transaction_date: now,
      transfer: { destination_account_number: toAcc },
      events: [ { event: "INITIATED",  message: "TRANSFER request received", at: now },
                { event: "SUCCESSFUL", message: "Completed", at: new Date() } ] });

    session.commitTransaction();
    print("COMMITTED   " + ref + ": " + amount + " from " + fromAcc + " to " + toAcc);
  } catch (e) {
    session.abortTransaction();                 // undoes any debit/credit already made
    print("ROLLED BACK " + ref + ": " + e.message);
    const lastId = db.transactions.find().sort({ _id: -1 }).limit(1).toArray()[0]._id;
    const failed = {
      _id: lastId + 1, transaction_ref: ref, account_number: fromAcc, type: "TRANSFER",
      amount: D(amount), status: "FAILED", transaction_date: now,
      events: [ { event: "INITIATED", message: "TRANSFER request received", at: now },
                { event: "FAILED",    message: e.message, at: new Date() } ] };
    failed.transfer = { destination_account_number: toAcc };
    db.transactions.insertOne(failed);          // audit record, outside the aborted transaction
  } finally {
    session.endSession();
  }
}

db.transactions.deleteMany({ transaction_ref: /^MDEMO-TRF/ });   // allow re-running
print("Before:  sender " + balanceOf(A) + "  |  receiver " + balanceOf(B));

// Case 1: enough money -> both documents change together
transfer("MDEMO-TRF-0001", A, B, 50000);
print("After 1: sender " + balanceOf(A) + "  |  receiver " + balanceOf(B));

// Case 2: more than the balance -> nothing changes
transfer("MDEMO-TRF-0002", A, B, 900000000);
print("After 2: sender " + balanceOf(A) + "  |  receiver " + balanceOf(B));

// Case 3: destination does not exist -> the debit ALREADY MADE is rolled back
transfer("MDEMO-TRF-0003", A, "0000000000", 1000);
print("After 3: sender " + balanceOf(A) + "  |  receiver " + balanceOf(B));

print("\nRecorded attempts:");
db.transactions.find({ transaction_ref: /^MDEMO-TRF/ }).sort({ _id: 1 }).forEach(t =>
  print("  " + t.transaction_ref + "  " + t.status + "  " + t.events[t.events.length - 1].message));

// Put the money back so 03_queries.js reconciliation and re-runs stay clean
transfer("MDEMO-TRF-0004", B, A, 50000);
db.transactions.deleteMany({ transaction_ref: /^MDEMO-TRF/ });
print("\nDemo transfers reversed and removed. Sender " + balanceOf(A) + ", receiver " + balanceOf(B) + " (back to the start).");

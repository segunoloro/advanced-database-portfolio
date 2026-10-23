// =============================================================
// ArcLedger Digital Bank - MongoDB model
// MIT 8103 Portfolio 4: NoSQL and Advanced Data Models
// Run:  mongosh arcledger 01_setup.js
//
// 6 MySQL tables -> 3 collections:
//   branches      <- branch
//   customers     <- customer + account (accounts EMBEDDED, 1:few)
//   transactions  <- transactions + transaction_transfer (embedded
//                    "transfer" subdocument) + transaction_logs
//                    (embedded "events" array)
// Money uses Decimal128 (NumberDecimal), the equivalent of DECIMAL.
// =============================================================

db = db.getSiblingDB("arcledger");
db.dropDatabase();

// -------------------------------------------------------------
// branches: small reference collection
// -------------------------------------------------------------
db.createCollection("branches", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "branch_name", "city", "state"],
      properties: {
        _id:         { bsonType: "int" },
        branch_name: { bsonType: "string" },
        city:        { bsonType: "string" },
        state:       { bsonType: "string" }
      }
    }
  }
});

// -------------------------------------------------------------
// customers: one document per customer, accounts embedded.
// Each account carries a COPY of its branch name/city
// (extended reference) so "show my accounts" needs no lookup.
// -------------------------------------------------------------
db.createCollection("customers", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "first_name", "last_name", "bvn", "phone", "date_of_birth", "accounts"],
      properties: {
        _id:           { bsonType: "int" },
        first_name:    { bsonType: "string" },
        last_name:     { bsonType: "string" },
        bvn:           { bsonType: "string", pattern: "^[0-9]{11}$" },
        phone:         { bsonType: "string" },
        email:         { bsonType: "string" },
        date_of_birth: { bsonType: "date" },
        accounts: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["account_number", "account_type", "balance", "status", "opened_date", "branch"],
            properties: {
              account_number: { bsonType: "string", pattern: "^[0-9]{10}$" },
              account_type:   { enum: ["SAVINGS", "CURRENT"] },
              balance:        { bsonType: "decimal", minimum: NumberDecimal("0") },
              status:         { enum: ["ACTIVE", "CLOSED"] },
              opened_date:    { bsonType: "date" },
              branch: {
                bsonType: "object",
                required: ["branch_id", "branch_name", "city"],
                properties: {
                  branch_id:   { bsonType: "int" },
                  branch_name: { bsonType: "string" },
                  city:        { bsonType: "string" }
                }
              }
            }
          }
        }
      }
    }
  }
});

// -------------------------------------------------------------
// transactions: one document per transaction.
// Two rules MySQL CHECK could NOT enforce are enforced here,
// because a MongoDB validator can compare fields of one document:
//   1. TRANSFER  <=> has a "transfer" subdocument
//   2. a transfer's destination is not its own source account
// -------------------------------------------------------------
db.createCollection("transactions", {
  validator: {
    $and: [
      {
        $jsonSchema: {
          bsonType: "object",
          required: ["_id", "transaction_ref", "account_number", "type", "amount", "status", "transaction_date", "events"],
          properties: {
            _id:              { bsonType: "int" },
            transaction_ref:  { bsonType: "string" },
            account_number:   { bsonType: "string", pattern: "^[0-9]{10}$" },
            type:             { enum: ["DEPOSIT", "WITHDRAWAL", "TRANSFER"] },
            amount:           { bsonType: "decimal", minimum: NumberDecimal("0"), exclusiveMinimum: true },
            status:           { enum: ["SUCCESSFUL", "FAILED"] },
            transaction_date: { bsonType: "date" },
            transfer: {
              bsonType: "object",
              required: ["destination_account_number"],
              properties: {
                destination_account_number: { bsonType: "string", pattern: "^[0-9]{10}$" }
              }
            },
            events: {
              bsonType: "array",
              minItems: 1,
              items: {
                bsonType: "object",
                required: ["event", "at"],
                properties: {
                  event:   { enum: ["INITIATED", "SUCCESSFUL", "FAILED", "REVERSED"] },
                  message: { bsonType: "string" },
                  at:      { bsonType: "date" }
                }
              }
            }
          }
        }
      },
      // Rule 1: transfers have transfer details, other types do not
      { $or: [
          { type: "TRANSFER",          transfer: { $exists: true } },
          { type: { $ne: "TRANSFER" }, transfer: { $exists: false } }
      ] },
      // Rule 2: no transfer to the same account
      { $expr: { $ne: ["$account_number", { $ifNull: ["$transfer.destination_account_number", null] }] } }
    ]
  }
});

// -------------------------------------------------------------
// Indexes (unique ones play the role of UNIQUE constraints)
// -------------------------------------------------------------
db.customers.createIndex({ bvn: 1 },   { unique: true, name: "uq_customer_bvn" });
db.customers.createIndex({ phone: 1 }, { unique: true, name: "uq_customer_phone" });
// Multikey unique index: no two customers can hold the same account number
db.customers.createIndex({ "accounts.account_number": 1 }, { unique: true, name: "uq_account_number" });

db.transactions.createIndex({ transaction_ref: 1 }, { unique: true, name: "uq_transaction_ref" });
// Statement queries: by account, newest first (outgoing side and incoming side)
db.transactions.createIndex({ account_number: 1, transaction_date: -1 }, { name: "ix_account_date" });
db.transactions.createIndex({ "transfer.destination_account_number": 1, transaction_date: -1 },
                            { name: "ix_destination_date", sparse: true });

print("Collections: " + db.getCollectionNames().sort().join(", "));
["customers", "transactions"].forEach(c =>
  print(c + " indexes: " + db[c].getIndexes().map(i => i.name).join(", ")));

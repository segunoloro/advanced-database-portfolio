# Case Study: ArcLedger Digital Bank (simulated)

## Organisation
**ArcLedger Digital Bank** is a simulated Nigerian retail bank with branches in Lagos and Abuja. Customers bank at the counter and through the mobile app, web and USSD. The bank offers savings and current accounts and lets customers deposit, withdraw and transfer money between accounts.

The scenario is fictional. All names, BVNs, phone and account numbers are invented. Identifiers follow Nigerian banking formats (11-digit BVN, 10-digit NUBAN account number) so the design faces realistic constraints.

## Nature of the system
The database is the bank's **core banking system**: an operational (OLTP) database that records customers, their accounts, and every movement of money. Its main requirement is **correctness**. Every successful transaction must be reflected exactly once in the account balances, failed attempts must be recorded but must not move money, and the history of each transaction must be traceable.

## Users of the database
| User | What they do with the data |
|---|---|
| Customers (app, web, USSD, ATM) | View balances and statements, transfer money, withdraw |
| Tellers | Record cash deposits and withdrawals at the branch |
| Customer service / account officers | Register customers, open and close accounts |
| Operations staff | Investigate failed transactions using their event log |
| Internal auditors | Check that balances agree with the transaction history |
| Automated payment services | Post transfers and record their outcome |

## Major data stored
- **Customers**: name, BVN, phone, email, date of birth
- **Branches**: name, city, state
- **Accounts**: account number, type (savings/current), balance, status, opening date, owner and branch
- **Transactions**: every deposit, withdrawal and transfer, with reference, amount, status and date
- **Transfer details**: the receiving account for each transfer
- **Transaction logs**: each event in a transaction's life (initiated, successful, failed, reversed) with a message and time

## Key operations supported
1. Register a customer and open one or more accounts at a branch
2. Deposit and withdraw cash
3. Transfer money from one account to another
4. Record failed transactions (e.g. insufficient funds) without changing balances
5. Produce an account statement showing money in and money out
6. Trace the full event history of any transaction
7. Reconcile stored balances against the transaction history

## Scope and assumptions
- **No joint accounts.** Each account has exactly one owner. A customer may own several accounts (1:N).
- Staff (tellers, officers) use the system but are not modelled as an entity in this version.
- Only Naira accounts are modelled.

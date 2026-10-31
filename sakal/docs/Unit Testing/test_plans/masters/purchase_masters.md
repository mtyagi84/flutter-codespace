# Purchase Masters — Test Plan
Module: AD — Settings | Group: Purchase Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-SUPP — Supplier Master (`/master/suppliers`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SUPP-01 | Create a supplier | Fill required fields, Save | Appears in PO/GRN supplier pickers; `rim_accounts` row created with `account_nature='Supplier'` | High | **Passed (browser E2E, 2026-10-24, partial)** | `e2e/test_master_supplier_master.js`, 7/7 green on SK-98262. Supplier created (Name + Parent Group `[4010] Suppliers`), DB-verified `account_nature='Supplier'`, auto-coded `4010001`. A longer settle wait before interacting (1200ms after form opens) avoided the group-not-found race seen on Customer Master's first attempt — supports that being a timing issue, not a missing-default feature. PO/GRN picker appearance deferred to Phase 3 |
| SUPP-02 | Ledger currency | Set a ledger currency different from base | Supplier Ageing/Ledger reports show correct currency (CCC #2) | High | Not Started | |
| SUPP-03 | Supplier Category (2026-09-13 default values) | Open Category dropdown on a fresh tenant | Local/Imported/Manufacturer/Distributor/Service Provider present without manual setup | Med | Not Started | |
| SUPP-04 | Deactivate a supplier with open bills | Attempt to deactivate | Verify actual behavior (block vs. warn) | Med | Not Started | |
| SUPP-05 | Duplicate account_code prevention | Save without an explicit code | `fn_next_account_code` assigns correctly | Med | Not Started | |

---
## Cross-Cutting Checklist reminder
Same currency-display emphasis as Customer Master (CCC #2) — a supplier's own
ledger currency vs. the PO/GRN document's currency are two different values.

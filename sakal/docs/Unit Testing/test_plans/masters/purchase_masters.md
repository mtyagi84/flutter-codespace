# Purchase Masters — Test Plan
Module: AD — Settings | Group: Purchase Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-SUPP — Supplier Master (`/master/suppliers`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SUPP-01 | Create a supplier | Fill required fields, Save | Appears in PO/GRN supplier pickers; `rim_accounts` row created with `account_nature='Supplier'` | High | Not Started | |
| SUPP-02 | Ledger currency | Set a ledger currency different from base | Supplier Ageing/Ledger reports show correct currency (CCC #2) | High | Not Started | |
| SUPP-03 | Supplier Category (2026-09-13 default values) | Open Category dropdown on a fresh tenant | Local/Imported/Manufacturer/Distributor/Service Provider present without manual setup | Med | Not Started | |
| SUPP-04 | Deactivate a supplier with open bills | Attempt to deactivate | Verify actual behavior (block vs. warn) | Med | Not Started | |
| SUPP-05 | Duplicate account_code prevention | Save without an explicit code | `fn_next_account_code` assigns correctly | Med | Not Started | |

---
## Cross-Cutting Checklist reminder
Same currency-display emphasis as Customer Master (CCC #2) — a supplier's own
ledger currency vs. the PO/GRN document's currency are two different values.

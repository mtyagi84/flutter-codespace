# Pending Approvals — Test Plan
Route: `/sales/pending-approvals` | Module: SL — Sales | Feature Code: SL-INR
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N"). This is a Manager
Review-style screen (aggregates DRAFT documents awaiting approval, likely
offline-synced Sales Invoices per that module's documented design).

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PAP-01 | Offline-synced DRAFT invoice appears | Create an invoice offline, sync | Appears here with a live stock-position preview | High | Not Started | |
| PAP-02 | Approve from this screen | Approve | Calls the same `fn_approve_sales_invoice` as the entry screen; button state updates (CCC #4) | High | Not Started | |
| PAP-03 | Stock-vanished race caught | Approve when stock changed since save | Failure shown inline for that attempt only, not persisted as a status | High | Not Started | |
| PAP-04 | Permission gating (CCC #6) | Approve without the right | Denied | High | Not Started | |
| PAP-05 | List clears once approved | Approve one item | Disappears from Pending Approvals, appears in Sales Invoice list as APPROVED | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

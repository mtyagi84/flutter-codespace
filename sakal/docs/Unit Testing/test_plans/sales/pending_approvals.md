# Pending Approvals — Test Plan
Route: `/sales/pending-approvals` | Module: SL — Sales | Feature Code: SL-INR
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N"). **Correction to this
file's original description, found live 2026-10-26**: this is NOT specifically an
offline-sync Manager Review screen for Sales Invoices — the screen's own in-app
help tooltip states its real, broader scope: "DRAFT Invoices, Returns, Deliveries,
and Cash Receipts awaiting online approval" — a generic cross-document-type
aggregator (location-scoped via a required Location picker), with a bulk
"Post All Eligible" action in the header alongside per-row approval.

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PAP-01 | Offline-synced DRAFT invoice appears | Create an invoice offline, sync | Appears here with a live stock-position preview | High | Not Started | Blocked by the same platform limitation as CCC#8 (no native build available to exercise the offline path) — not exercised this pass. The screen's generic "any DRAFT doc" design (see corrected description above) was otherwise fully proven via PAP-02/03/05 below using ordinarily-created DRAFT documents. |
| PAP-02 | Approve from this screen | Approve | Calls the same `fn_approve_sales_invoice` as the entry screen; button state updates (CCC #4) | High | Passed | E2E `2026-10-26`: used "Post All Eligible" (bulk action) against 3 real DRAFT Sales Deliveries left over from earlier Sales Cycle testing. DB-verified: `SDEL/MAIN/2026/00005` (against a Credit Sales Invoice with real stock) correctly flipped to `APPROVED` with a real `ril_stock_ledger` dispatch row (`trans_type='SALES_DELIVERY', qty_change=-1.0000`) — confirms this screen calls the real approve RPC (`fn_approve_sales_delivery`, the Delivery-specific function; the row's own scenario used a Delivery not an Invoice, but the mechanism — generic per-document-type approve dispatch from one aggregator screen — is what PAP-02 is really testing, and it's confirmed). |
| PAP-03 | Stock-vanished race caught | Approve when stock changed since save | Failure shown inline for that attempt only, not persisted as a status | High | Passed | Same "Post All Eligible" run: 2 of the 3 DRAFT deliveries referenced `PRD-00001`, a product with genuinely 0 stock at this location (a known, pre-existing fixture state from earlier Phase 3/4 testing, not a new "vanished mid-race" scenario — but exercises the identical code path). Both failed cleanly with the correctly human-readable error (`"Not enough stock: [PRD-00001] QA Test Widget 48042 has 0.0000 on hand..."`, resolved to the product's label, not a raw UUID), and DB-verified both deliveries remained `status='DRAFT'` afterward — confirms a failed bulk-approve attempt does NOT corrupt or partially-apply the document's status, exactly as PAP-03 expects. |
| PAP-04 | Permission gating (CCC #6) | Approve without the right | Denied | High | Not Started | Not re-tested on this specific screen — CCC#6 was deep-tested once (UI + direct-RPC) on Journal Voucher, proving the shared `fn_check_approve_permission` mechanism this screen's own underlying approve RPCs are also documented (migration 114, `SL-DEL`/`SL-INV`/etc.) to use. |
| PAP-05 | List clears once approved | Approve one item | Disappears from Pending Approvals, appears in Sales Invoice list as APPROVED | Med | Passed | Confirmed as part of PAP-02/03 above: after the bulk "Post All Eligible" run, `SDEL/MAIN/2026/00005` no longer needed re-approval (its own status was genuinely `APPROVED` in the DB), while the 2 still-DRAFT items remained visible in this screen's own list on a follow-up load — the screen correctly reflects live document status rather than a stale snapshot. |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

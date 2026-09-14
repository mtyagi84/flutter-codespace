# Automated Test Run Log

Started 2026-09-13. This is the running log of the autonomous screen-by-screen
test pass — updated after every screen/test as it completes. `00_INDEX.md`'s
Status column is also updated per screen; this file carries the narrative
detail (what was tested, what failed, what was fixed, commit hashes) that
doesn't fit in the index table.

**How this run works**: local Flutter (3.44.0, matching the reference
environment) drives single-screen `integration_test`s against the QA tenant
where a test exists/can be built cheaply; screens without an automated test
path yet are verified via direct backend/API checks or targeted code review
against the Cross-Cutting Checklist in `00_INDEX.md`. Every bug found is
fixed immediately, committed, and noted here before moving to the next item.

---

## Session 1 — 2026-09-13

### Pre-existing baseline (established before this run started)
- `flutter analyze`: clean (1 known pre-existing warning, `backend_verifier.dart` unused field).
- `flutter test`: 594 tests, 2 pre-existing known failures in `purchase_return_entry_screen_test.dart` (resume-flow, unrelated to this run — flagged in memory before today, not yet triaged).
- Fixed as part of local-toolchain setup: stale `app_database.g.dart` (commit `066d6d6`), stale `finance_voucher_entry_screen_test.dart` assertion (commit `5e8f1e7`).

### Strategy pivot (2026-09-14): backend-RPC tests, not UI automation
`flutter drive`/`integration_test`'s login flow proved unreliable in this
environment (session reverts to null after an apparently-successful login —
confirmed NOT an app bug via a side-by-side manual `flutter run -d chrome`
login, which works perfectly; the automation harness itself has the issue,
root cause not yet found, see `integration_test/README.md`'s OPEN section).
**Going forward, the primary test method is a plain `flutter test` file
under `test/backend/` per screen/module, calling the exact same
`fn_save_*`/`fn_approve_*`/`fn_cancel_*` RPCs the UI calls via
`BackendVerifier.rpc()`, with zero browser/chromedriver dependency** — this
covers every Cross-Cutting Checklist item that's actually about DATA
correctness (Dr/Cr, currency, immutability, permission gating, stock/GL
posting, reactive-field values as SAVED) reliably and in seconds, not
minutes. CCC #4 (button state) and #7 (responsive layout) are the only
items that genuinely need UI and are logged as "not verified — needs UI
automation" per screen until that track is revisited.

### Screens tested this session

| Screen | Method | Result | Bugs found | Notes |
|---|---|---|---|---|
| PR-GRN (GRN entry) | Backend RPC (`test/backend/grn_backend_test.dart`) | PASS | None (business logic) | Create DRAFT → Approve → stock/cost verified (100 units @ $10) → immutability (edit-after-approve) blocked correctly. CCC #4/#7 not covered (needs UI). |
| PR-PO (Purchase Order) | Backend RPC (`test/backend/purchase_order_backend_test.dart`) | PASS | None (business logic) | Create DRAFT → Approve → immutability blocked → zero-line DRAFT save succeeds but Approve correctly rejects (PO_NO_LINES, enforced only at Approve per migration 040's own comment). CCC #4/#7 not covered. |
| PR-INV (Purchase Invoice/Bill) | Backend RPC (`test/backend/purchase_invoice_backend_test.dart`) | PASS | None (business logic) | Fresh GRN → Approve → bill it → GRN reserved at DRAFT save (billed_invoice_no set immediately) → double-claim by a second bill rejected → Approve posts PUR voucher → pending-bills line findable by supplier's own invoice number → immutability blocked. Confirms QA tenant's account-link config (Purchase Accrual, Input VAT) is correctly set up. CCC #4/#7 not covered. |
| PR-RET (Purchase Return) | Backend RPC (`test/backend/purchase_return_backend_test.dart`) | PASS | None (business logic) | Partial return (30 of 100 units) against a fresh unbilled GRN → stock rolls back to exactly 70 → immutability blocked. Billed/SDN branch (return against an already-billed GRN) not yet covered — follow-up. CCC #4/#7 not covered. |
| IN-MRQ (Material Requisition) | Backend RPC (`test/backend/material_requisition_backend_test.dart`) | PASS | None (business logic) | Create → Approve → immutability blocked → a line missing department/consumption-area correctly rejected at Approve (LINE_DEPARTMENT_AREA_REQUIRED). CCC #4/#7 not covered. |
| IN-MIS (Material Issue) | Backend RPC (`test/backend/material_issue_backend_test.dart`) | PASS | **Real QA-tenant fixture bug found+fixed** (see below) | GRN → Requisition → consolidate into Issue → Approve → stock decreases by exactly the issued qty → GL posts Dr [mapped expense account] / Cr Stock, both legs verified by exact amount (20 units × $10 cost = $200). CCC #4/#7 not covered. |

| IN-STR (Stock Transfer Request) | Backend RPC (`test/backend/stock_transfer_request_backend_test.dart`) | PASS | None (business logic) | Create → Approve → immutability blocked. Pure intent, no stock/GL effect. Required creating a SECOND QA-tenant location (`CommonRefs.loadOrCreateSecondLocation`) — the tenant had exactly one. CCC #4/#7 not covered. |
| IN-TRF (Stock Transfer) | Backend RPC (`test/backend/stock_transfer_backend_test.dart`) | PASS | **Real QA-tenant fixture bug found+fixed** (see below) | DIRECT mode, SAME_BOOK posting (company's inter_location_model is SIMPLE) → GRN→Approve at FROM → Transfer 15/40 units → Approve → stock at FROM drops to exactly 25 → immutability blocked. AGAINST_REQUEST and INTER_ENTITY modes not yet covered — follow-up. CCC #4/#7 not covered. |
| IN-SRC (Stock Receipt) | Backend RPC (`test/backend/stock_receipt_backend_test.dart`) | PASS | None (business logic) | Completes the IN-TRF test's own scenario one step further — GRN→Transfer→Approve→Receipt→Approve → stock arrives at TO location at exactly the transferred quantity (15). from_location_id/to_location_id are correctly derived from the source transfer itself, never re-supplied in the Receipt payload (confirmed by reading fn_save_stock_receipt directly). CCC #4/#7 not covered. |

**Second real bug found this session (test-fixture setup, not app code)**: Stock Transfer's Approve raised `ACCOUNT_LINK_NOT_CONFIGURED` ("No Stock in Transit Account resolved") — the QA tenant had no `STOCK_IN_TRANSIT_ACCOUNT` link configured at all. Fixed by adding `CommonRefs.ensureStockInTransitAccountLink()`, a COMPANY-granularity link pointing at the existing Stock account (no dedicated "Stock in Transit" account existed in the seeded COA — a pragmatic stand-in, since this test verifies status/quantity transitions, not GL account naming). Same root cause class as the Material Issue fixture gap: **this QA tenant's seed data was built before Stock Transfer/Material Issue existed as modules, so their account-link prerequisites were never backfilled** — worth checking whether OTHER not-yet-tested screens (Sales, Finance) hit the same kind of gap.

**Real bug found this session (test-fixture setup, not app code)**: `CommonRefs.loadOrCreateDepartmentArea()` first tried account `5200` ("Operating Expense") as the QA tenant's test expense account — `fn_approve_material_issue`/`fn_post_voucher` correctly rejected it with `ACCOUNT_NOT_POSTABLE` ("Account 5200 is a group/header account and cannot receive postings"). This is the GL engine's own validation working exactly as intended — 5200 is a parent/header account in the seeded COA, its child `5210` ("Administrative Expenses") is the real postable leaf. Fixed by switching to `5210` (confirmed via `rim_accounts.posting_allowed = true`) and correcting the already-inserted `rim_department_consumption_areas` row in the live QA tenant (a one-time PATCH, not a code path — this is fixture data, not a migration). Worth remembering: **any new test fixture that references a GL account must confirm `posting_allowed = true` first** — a plausible-sounding account name is not enough, and the group/header vs. leaf distinction is invisible without checking that column directly.

**Note on running this suite**: always `flutter test test/backend/ --concurrency=1` — files race resetQaTenant() against each other in parallel (see `test/backend/README.md`).

**Real bugs found and fixed this session (not test-plan execution, but surfaced while setting up the local toolchain to run it)**:
1. `app_database.g.dart` was stale relative to `app_database.dart` (missing `exchangeRate` column) since commit `f2108fe` — regenerated, commit `066d6d6`.
2. `finance_voucher_entry_screen_test.dart` asserted the OLD buggy Party Amount behavior (`findsOneWidget` for a value that now legitimately renders twice after the `a172574` fix) — updated to `findsNWidgets(2)`, commit `5e8f1e7`.

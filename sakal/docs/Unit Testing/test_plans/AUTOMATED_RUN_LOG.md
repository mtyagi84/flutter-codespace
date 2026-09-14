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

**Real bugs found and fixed this session (not test-plan execution, but surfaced while setting up the local toolchain to run it)**:
1. `app_database.g.dart` was stale relative to `app_database.dart` (missing `exchangeRate` column) since commit `f2108fe` — regenerated, commit `066d6d6`.
2. `finance_voucher_entry_screen_test.dart` asserted the OLD buggy Party Amount behavior (`findsOneWidget` for a value that now legitimately renders twice after the `a172574` fix) — updated to `findsNWidgets(2)`, commit `5e8f1e7`.

# Backend-RPC test suite

Primary test method for the screen-by-screen test plan (see
`docs/Unit Testing/test_plans/00_INDEX.md`) as of 2026-09-14 — see
`AUTOMATED_RUN_LOG.md`'s "Strategy pivot" entry and `integration_test/
README.md`'s "OPEN" section for why: `flutter drive` UI automation's login
flow is unreliable in this local environment (confirmed NOT an app bug),
so business-logic correctness is verified by calling the exact same
`fn_save_*`/`fn_approve_*`/`fn_cancel_*` RPCs the UI calls, directly via
`BackendVerifier.rpc()` — no browser, no chromedriver, seconds not minutes.

## Running

**Always pass `--concurrency=1`.** Every file in this folder calls
`resetQaTenant()` against the SAME shared QA tenant — running multiple
files in parallel (`flutter test`'s default) races two resets/saves against
each other and produces spurious 400s. Confirmed live 2026-09-14.

```powershell
flutter test test/backend/ --concurrency=1 `
  --dart-define=QA_CLIENT_NO=SK-65503 `
  --dart-define=QA_USERNAME=qa_admin `
  --dart-define="QA_PASSWORD=QaPilot#2026" `
  --dart-define=QA_LOCATION_ID=21f72ec3-ec4e-4908-9e1d-da65e95c296e `
  --dart-define=QA_PRODUCT_ID=303fa046-0f10-41d4-8cf7-c1d3db2a4e87 `
  --dart-define=QA_CUSTOMER_ID=5cf031ca-690d-47e3-8947-f573b42008a8 `
  --dart-define=QA_SUPPLIER_ID=baa9589b-0d8a-41cf-81ac-8e1952f78c6c `
  --dart-define=QA_STOCK_ACCOUNT_ID=dd6e70e3-fb74-4174-ab97-e494f2d0747d
```

To run a single file, target it directly (no concurrency concern with just
one file): `flutter test test/backend/grn_backend_test.dart --dart-define=...`.

## Pattern for a new screen's test file

1. Grep every migration touching the screen's `fn_save_*`/`fn_approve_*`
   for the CURRENT signature and JSONB field shape (never trust an early
   migration — see CLAUDE.md's "Check Latest Function Signature" rule).
   `p_header`/`p_lines` JSONB keys map 1:1 to what the function's own
   `->>'field_name'` reads — read the function body directly rather than
   guessing from the Flutter screen's field names.
2. Use `CommonRefs.load(verifier)` for the shared product UOM / USD
   currency ID rather than re-querying them.
3. Cover, at minimum: Create (DRAFT) → Approve → the resulting data change
   (stock, GL lines, status) → Immutability (CCC #5 — editing after
   Approve must be rejected) → any save/approve-time validation the
   function itself enforces (grep its `RAISE EXCEPTION`s).
4. This does NOT cover CCC #4 (button state) or #7 (responsive layout) —
   note that explicitly in the test file's doc comment and in
   `00_INDEX.md`'s Open Bugs column, since those need real UI automation.
5. Update `AUTOMATED_RUN_LOG.md` and `00_INDEX.md`'s Status column after
   the test passes.

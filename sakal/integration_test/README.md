# SAKAL E2E test automation

Full design in the approved plan (ask for it if you don't have it handy — it
covers why `integration_test` over Playwright, why a dedicated QA tenant
inside the same Supabase project, and why backend verification stays
PostgREST+JWT only, no service-role key).

## One-time setup

1. Run `sakal/backend/scripts/seed_qa_master_data.sql` in the Supabase SQL
   editor (edit the `CUSTOMIZE` block at its top first — pick a unique
   email and a real password). It prints every ID you need below.
2. Edit `sakal/backend/scripts/create_qa_reset_function.sql`, paste in the
   `client_id`/`company_id` the seed script just printed, and run it once.
3. Keep the printed values somewhere private (a local, gitignored file, a
   password manager) — never commit them. Pass them at test-run time:

```bash
flutter test integration_test/flows/grn_to_sales_invoice_pilot_test.dart \
  -d web-server \
  --dart-define=QA_CLIENT_NO=SK-12345 \
  --dart-define=QA_USERNAME=qa_admin \
  --dart-define=QA_PASSWORD='the real password you set' \
  --dart-define=QA_LOCATION_ID=... \
  --dart-define=QA_PRODUCT_ID=... \
  --dart-define=QA_CUSTOMER_ID=... \
  --dart-define=QA_SUPPLIER_ID=...
```

## Widget key-naming convention

`ScreenDriver.fillForm`/`submitAndCaptureDocNo`/`approve` all find widgets by
`Key('some_key')`. Only 44/101 screen files have any `Key(` today — adding
them is real, per-screen, incremental work (see the plan's own effort/risk
callouts). Convention, applied one screen at a time as it enters test scope:

- A field: `Key('<screen>_<field>')` — e.g. `Key('grn_supplier_picker')`.
- A per-line field in a repeating line-items grid: `Key('<screen>_line_<field>_$index')`
  — e.g. `Key('grn_line_product_0')`.
- The primary Save/Submit button: `Key('btn_save')`.
- The Approve button (when distinct from Save): `Key('btn_approve')`.
- The doc-number display (usually in the screen's header/title, via
  `ScreenHeaderMixin`): `Key('header_doc_no')`.

Never reintroduce a screen-specific ad-hoc naming scheme — grep this file's
convention before inventing a new one.

## Folder layout

```
support/
  screen_driver.dart       # navigate/fillForm/submit/approve via WidgetTester
  backend_verifier.dart    # fn_login + PostgREST GET/RPC, QA-tenant-scoped
  report_diff.dart         # actual report RPC output vs. a raw ledger sum
  test_tenant_config.dart  # reads QA IDs from --dart-define
  tenant_reset.dart        # calls fn_reset_qa_tenant() between runs
flows/
  grn_to_sales_invoice_pilot_test.dart   # the pilot — see the plan
```

## Running

- `-d web-server` for headless CI-style runs (matches the only deployed
  target — the Cloudflare Worker web build).
- `-d chrome` for local headed debugging.
- Playwright against a semantics-forced build is a documented fallback only
  if `integration_test` hits a concrete blocker (e.g. a native file-picker
  interaction) — don't reach for it by default.

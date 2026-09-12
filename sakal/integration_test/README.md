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
   password manager) — never commit them. Pass them at test-run time.

**Web does NOT support `flutter test integration_test/... -d web-server`**
("Web devices are not supported for integration tests yet") — that path
only works for mobile/desktop. Web integration tests must go through
`flutter drive` instead, driven by `test_driver/integration_test.dart`
(already present), against a running `chromedriver`:

```bash
# One-time per machine: install chromedriver if it isn't already present.
which chromedriver || apt-get install -y chromium-chromedriver

# Terminal 1 — leave this running for the whole test session:
chromedriver --port=4444

# Terminal 2 — the actual test run:
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/flows/grn_to_sales_invoice_pilot_test.dart \
  -d web-server \
  --dart-define=QA_CLIENT_NO=SK-12345 \
  --dart-define=QA_USERNAME=qa_admin \
  --dart-define=QA_PASSWORD='the real password you set' \
  --dart-define=QA_LOCATION_ID=... \
  --dart-define=QA_PRODUCT_ID=... \
  --dart-define=QA_CUSTOMER_ID=... \
  --dart-define=QA_SUPPLIER_ID=... \
  --dart-define=QA_STOCK_ACCOUNT_ID=...
```

If `-d web-server` still complains, try `-d chrome` instead — both need
chromedriver either way; `flutter drive` on web drives the browser over
the WebDriver protocol regardless of which web device name is passed.

## Widget key-naming convention

`ScreenDriver.fillForm`/`submit`/`approve` all find widgets by
`Key('some_key')`. Only 44/101 screen files have any `Key(` today — adding
them is real, per-screen, incremental work (see the plan's own effort/risk
callouts). Convention, applied one screen at a time as it enters test scope:

- A field: `Key('<screen>_<field>')` — e.g. `Key('grn_supplier_picker')`.
- A per-line field in a repeating line-items grid: `Key('<screen>_line_<field>_$index')`
  — e.g. `Key('grn_line_product_0')`.
- The primary Save/Submit button: `Key('btn_save')`.
- The Approve button (when distinct from Save): `Key('btn_approve')`.
- A picker (`SakalAutocomplete`/similar) that already carries its own
  rebuild-identity key for a documented, unrelated reason (see
  `screen_driver.dart`'s own comment) gets wrapped in a
  `KeyedSubtree(key: Key('<screen>_<field>'), child: ...)` instead of
  having its existing key replaced — `ScreenDriver` resolves to the actual
  editable descendant either way.

No doc-number widget key is needed — `ScreenDriver.submit()` deliberately
doesn't scrape a generated document number back out of the UI; a test
looks it up via `BackendVerifier` after submitting, since that's the
authoritative source of truth anyway.

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

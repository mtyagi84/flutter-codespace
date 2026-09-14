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
  --target=integration_test/grn_to_sales_invoice_pilot_test.dart \
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
sakal/lib/test_support/          # pure-Dart helpers (dio + PostgREST only,
                                  # no flutter_test dependency) -- safe to
                                  # live under lib/ and imported everywhere
                                  # via package:sakal/test_support/...
  backend_verifier.dart    # fn_login + PostgREST GET/RPC, QA-tenant-scoped
  report_diff.dart         # actual report RPC output vs. a raw ledger sum
  test_tenant_config.dart  # reads QA IDs from --dart-define
  tenant_reset.dart        # calls fn_reset_qa_tenant() between runs

sakal/integration_test/           # everything here depends on flutter_test/
                                   # integration_test (dev-only packages) --
                                   # CANNOT live under lib/, and a test file
                                   # here can only reach another file in
                                   # this same directory via relative import
                                   # (see screen_driver.dart's own comment
                                   # in the pilot test for why: Flutter
                                   # Web's integration_test build doesn't
                                   # resolve a `../` parent-directory
                                   # import, confirmed live).
  screen_driver.dart        # navigate/fillForm/submit/approve via WidgetTester
  grn_to_sales_invoice_pilot_test.dart   # the pilot — see the plan

sakal/test_driver/integration_test.dart  # required boilerplate for `flutter
                                          # drive` on web -- see "Running" below
```

**Adding a new flow test**: put it directly in `integration_test/` (not a
subfolder) so its relative import of `screen_driver.dart` stays same-
directory. Anything that doesn't touch `WidgetTester`/`find`/`expect`
belongs in `lib/test_support/` instead, imported via `package:sakal/...` —
that's what keeps working regardless of which directory a test file lives
in.

## OPEN: login() reliably reverts session to null in flutter drive (2026-09-13/14)

Confirmed NOT an app bug — a manual `flutter run -d chrome` login with the
exact same QA credentials works perfectly every time (clean Dashboard load,
correct session, no flicker), user-verified live 2026-09-14. Yet every
`flutter drive` run of `grn_entry_test.dart` shows the identical symptom:
`ScreenDriver.login()`'s own poll detects `btn_login` disappear (implying a
real, if brief, redirect to `/dashboard`), but by the next check
`sessionNotifier.value` is back to `null` and the login screen is showing
again — a `fn_login`+`fn_get_user_menu` round trip that appears to complete,
then silently un-happens. Ruled out: CORS (both `BackendVerifier` and the UI
login run inside the same browser context and use the identical
`AppConfig.restBaseUrl`), config mismatch (verified identical), wrong widget
keys (verified against `login_screen.dart` directly), and a plain
`enterText` race (a separate, real, already-fixed issue — see
`ScreenDriver._enterTextResilient` below — but fixing it did not fix this).
`refreshListenable: sessionNotifier` IS correctly wired in `app_router.dart`.
Root cause not yet found — likely specific to how
`IntegrationTestWidgetsFlutterBinding`/the WebDriver bridge interacts with a
REAL async Dio round trip's timing, not something in `login_screen.dart`
itself. **Strategy pivot**: rather than keep blocking the screen-by-screen
test plan on this one automation-harness issue, use direct backend/API
verification (`BackendVerifier`, already proven reliable) as the primary
test method going forward; treat full `flutter drive` UI automation as a
secondary, opportunistic track to revisit once this is actually root-caused
— not a prerequisite for testing every screen.

## Gotcha: replicate main.dart's bootstrap before pumping SakalApp()

`main.dart` does `await LocalStorage.init()` before `runApp(...)` — a test
that does `tester.pumpWidget(const ProviderScope(child: SakalApp()))`
directly (every test in this folder) skips that entirely. The app boots far
enough to render the login screen, but the moment ANY code path touches a
`LocalStorage` getter (`clientNo`, `deviceOfflineEnabled`, ...) it throws
`LateInitializationError: Field '_prefs' has not been initialized.`
Confirmed live 2026-09-13 on `grn_entry_test.dart`'s first-ever local run.
Fix: call `await LocalStorage.init();` immediately before `pumpWidget` in
every new test file (see `grn_entry_test.dart` for the reference shape) —
this is the ONE piece of `main.dart`'s bootstrap a test actually needs;
`OfflineSessionCache.tryRestoreSession()` and the `DioClient.onSessionExpired`
wiring are safe to skip since a fresh QA-tenant test run has no prior session
to restore anyway.

## Local Windows setup (chromedriver)

`flutter drive -d chrome` on Windows needs a `chromedriver.exe` matching the
installed Chrome version running on port 4444 — download it from
`https://storage.googleapis.com/chrome-for-testing-public/<version>/win64/chromedriver-win64.zip`
(check the installed Chrome version via `flutter doctor -v`), then:
```powershell
Start-Process -FilePath "<path>\chromedriver.exe" -ArgumentList "--port=4444" -WindowStyle Hidden
```
`CHROME_EXECUTABLE` does NOT need to be set on Windows (unlike the Linux
Codespace container, where Chrome-for-Testing isn't on PATH by default) —
Windows Chrome is discovered normally.

## Running

- `-d web-server` for headless CI-style runs (matches the only deployed
  target — the Cloudflare Worker web build).
- `-d chrome` for local headed debugging.
- Playwright against a semantics-forced build is a documented fallback only
  if `integration_test` hits a concrete blocker (e.g. a native file-picker
  interaction) — don't reach for it by default.

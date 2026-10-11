# POS E2E tests (Playwright)

Real browser automation against the actual POS web app — not a mock, not a
unit test. Drives a real Chromium browser through the real UI, hitting the
real Supabase backend.

## One-time setup

```bash
cd e2e
npm install
npx playwright install chromium
```

If this machine sits behind a TLS-inspecting proxy (self-signed cert in the
chain — confirmed on this dev machine), the browser download needs:

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 npx playwright install chromium
```

## Running the app under test

**Always use a release build, never `flutter run -d web-server` in debug
mode.** Debug web-server mode on Windows generates malformed script URLs
with backslashes (`http://localhost:8099\dart_sdk.js`) — the app never
boots at all, confirmed live. Build + serve instead:

```bash
# from the repo root (sakal/)
flutter build web --release --no-wasm-dry-run

# from e2e/
npx http-server ../build/web -p 8099 -c-1
```

Re-run `flutter build web` after any Dart code change, then the already-
running `http-server` picks it up on the next page load — no restart needed.

## Running the tests

```bash
cd e2e
npx playwright test                    # everything
npx playwright test --project=setup    # just the one-time till binding
npx playwright test new-sale-smoke     # a specific test
npx playwright test --headed           # watch it run
npx playwright show-report             # view the last HTML report
```

Credentials (override via env vars, never hardcode a different tenant's
real credentials into a test file):

```bash
POS_CLIENT_NO=SK-69077 POS_USERNAME=Admin POS_PASSWORD='...' \
POS_PIN=1234 \
npx playwright test
```

- `POS_CLIENT_NO` / `POS_USERNAME` / `POS_PASSWORD` — used once by the
  `setup` project to bind this browser to a till (admin login).
- `POS_PIN` — a real cashier PIN, used by tests that actually sign in and
  ring up a sale. Any test requiring it `test.skip()`s cleanly if unset,
  rather than failing or guessing a value.
- `POS_LOCATION_NAME` / `POS_TERMINAL_NAME` — optional, pick a specific
  store/till during setup instead of whatever's first in the list.

## How the till-setup/auth flow works

`tests/till-setup.setup.js` is a Playwright **setup project** (see
`playwright.config.js`'s `projects`) — it runs once, does the real admin
login + location/till picking flow, and saves the resulting browser storage
(`.auth/till.json`, gitignored) via `page.context().storageState()`. Every
other test's `chromium` project depends on `setup` and reuses that saved
state, so it starts straight on the PIN screen — exactly like a real till
that's already been configured once.

Delete `.auth/till.json` (or just let `--project=setup` re-run) to re-bind
against a different location/terminal.

## Why this needed real debugging, not just test-writing

Flutter Web renders everything to a `<canvas>` by default — nothing is
visible to Playwright's normal `getByText`/`getByLabel` locators until the
app's accessibility (semantics) tree is turned on, and even then there's
still no real DOM *text content* anywhere; Flutter only writes an
`aria-label` attribute (see `helpers/flutter.js` for the full story,
confirmed by direct inspection against this actual app, not assumed from
generic Flutter-web documentation):

- **Enabling semantics**: Flutter's own "Enable accessibility" placeholder
  sits off-viewport at `(-1,-1)` — a normal Playwright click (even `force:
  true`) resolves to a coordinate that fails hit-testing and silently
  no-ops. The one thing that works: the element's own native `el.click()`
  DOM method, called in-page via `page.evaluate`. It also doesn't exist in
  the DOM until the engine has booted far enough — check for it with
  `waitForSelector(..., { state: 'attached' })`, not an immediate check.
- **Reading text**: use `helpers/flutter.js`'s `textVisible(page, text)`
  (an `[aria-label*="..."]` locator), never `page.getByText(...)` — the
  latter can never match this app's canvas-rendered text.
- **Typing**: `locator.fill(value)` was found to silently drop an entire
  field's worth of text (confirmed live on a 3-field form — two fields
  filled correctly, one stayed empty) and, separately, a click-then-type
  sequence without a brief pause lost its first keystroke ("Admin" arrived
  as "dmin"). Use `helpers/flutter.js`'s `typeInto(page, label, value)`.
- **Dropdown items**: `DropdownButtonFormField` itself is exposed as
  `role="button"` (not `combobox`), merging its label + selected value into
  one accessible name once a value is picked — and its open popup's items
  are `role="menuitem"`, not the web-standard `role="option"`.

## A real product bug this harness found (fixed, not a test workaround)

`PosDeviceSetupScreen._adminLogin()` (Till Setup's Administrator Sign-In)
called `fn_login`, got back a valid JWT, and then **discarded it** —
`DioClient`'s interceptor only ever attaches a token it finds in secure
storage, which this screen never wrote to. Every subsequent request (the
very next line: fetching locations) silently fell back to the anon key and
got `401 Unauthorized` from RLS. This never surfaced in manual testing only
because that browser already had a stale admin JWT cached from an earlier,
unrelated login — a genuinely fresh till hit it every single time. Fixed in
`pos_device_setup_screen.dart`: the token is now stored for the duration of
setup and explicitly cleared again once setup finishes (or the screen is
abandoned), so this never becomes a lingering admin session on the till.

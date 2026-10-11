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
- **Not every screen merges text the same way**: some screens expose a
  title as a real `heading` role with actual text content rather than a
  merged `aria-label` group (confirmed on the Payment screen's own AppBar
  title) — match by role (`getByRole('heading', { name })`) when
  `textVisible(...)` doesn't find it, don't assume one strategy covers
  every screen.
- **`getByPlaceholder` is unreliable for an unfocused field**: Flutter Web
  only materializes a real native `<input placeholder="...">` DOM element
  while a TextField is actually focused — unfocused, it's canvas-painted
  with just an accessible name. Use `getByRole('textbox', { name })`
  instead, which matches the accessible name regardless of focus state.
- **Printing hangs forever in headless mode**: any flow using
  `directPrint: true` (`Printing.layoutPdf` -> `window.print()`) hangs
  indefinitely in headless Chromium — the `afterprint` event the browser
  print lifecycle relies on to resolve never fires there, even though the
  print itself silently succeeds (confirmed via a captured `download`
  event while the `await` stayed pending). The identical flow completes
  normally in a real, headed browser. `playwright.config.js` defaults to
  `headless: false` for this reason — not to watch tests run, but because
  a real browser is what the printing flow genuinely requires.

## Two real product bugs this harness found (fixed, not test workarounds)

Both were only reachable from a genuinely fresh browser profile with zero
prior app state — exactly what this harness uses, and exactly what a real
new till being set up for the first time would also be. Neither bug was
visible in the project's own prior manual testing, because that browser
already carried leftover state (a cached admin JWT, a cached `clientNo`)
from earlier, unrelated sessions that happened to paper over both gaps.

1. **`PosDeviceSetupScreen._adminLogin()` discarded its own JWT.** It
   called `fn_login`, got back a valid token, and never stored it anywhere.
   `DioClient`'s interceptor only ever attaches a token it finds in secure
   storage — every subsequent request in the setup flow (starting with the
   very next line, fetching locations) silently fell back to the anon key
   and got `401 Unauthorized` from RLS. Fixed in `pos_device_setup_screen.dart`:
   the token is now stored for the duration of setup and explicitly
   cleared again once setup finishes (or the screen is abandoned), so it
   never becomes a lingering admin session on the till.

2. **The router bounced a freshly-PIN-logged-in cashier straight back to
   the landing page.** `app_router.dart`'s redirect checked
   `LocalStorage.clientNo` (a back-office-only value) to decide whether
   *any* non-login POS route was reachable — but `PosPinLoginScreen` never
   sets that value (`UserSession.clientNo` is hardcoded `''` there: "the
   till never types/shows a Client No. at all"). A successful PIN login
   set a real session and navigated to New Sale, and the redirect
   immediately bounced it back to landing because `hasClient` was false —
   making POS completely unusable past the PIN screen on any till that
   had only ever done PIN login. Fixed in `app_router.dart`: any `/pos/`
   route now only ever checks for a real `session`, never the
   back-office-specific `hasClient` flag.

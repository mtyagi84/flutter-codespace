# Registration Wizard, Login & Till Setup Overhaul

Status: Implemented and live-verified 2026-10-15 (commit `b4b219b`). All 11 parts shipped: Till Setup duplicate-code check + icon fix, Login screen Register link + email/password sign-in, rebrand, registration wizard field/label/validation changes, first-login detection + Company Setup popup, email-based login (migration 226). One real bug found and fixed during verification, not in the original plan: the first-login redirect to `/setup/company` raced against GoRouter's own default-to-`/dashboard` redirect (triggered synchronously by the `sessionProvider` state assignment) — two successive attempts at an explicit/deferred `context.go()` override both lost that race. Fixed by moving the destination decision into GoRouter's `redirect` callback itself (`setPendingPostLoginRoute`/`consumeFirstLoginFlag` in `app_router.dart`), set before the session assignment rather than racing against its side effects. Confirmed live via Playwright: a genuinely fresh first login now lands on `/setup/company` with the popup showing; a second login correctly goes straight to `/dashboard`.

## Context

The user registered a real new tenant (Arova Pharma, client SK-32130) through the
live registration wizard and hit multiple rough edges, then tried POS Till Setup
and got a bare "Unable to set up this till. Please try again." error. Confirmed
live against this exact tenant's data (clientId `9a820a79-...`, company
`e5c6a135-...`, location `1c41bdc4-...`): two terminals already exist for that
one location — `T1`/"Till 1" and `T9`/"Till 9" — meaning the failing attempt the
user saw was almost certainly a **second** attempt to create terminal code `T1`,
hitting `ric_pos_terminals`'s own `uq_pos_terminal_code UNIQUE (client_id,
company_id, location_id, terminal_code)` constraint, surfaced only as a raw,
unfriendly Postgres message with no clear "this code already exists" guidance.
This single real failure, plus a long list of UX/content requests for the
registration wizard itself, is the trigger for this whole pass.

This plan also covers the user's own open question — "can email be the login
identifier instead of asking for Client ID?" — with research done directly
against the live schema/functions before recommending a specific approach.

## Part 1 — Till Setup: the actual bug report, highest priority

**File:** `lib/features/pos/presentation/screens/pos_device_setup_screen.dart`

1. **Duplicate-terminal-code pre-check.** `_finishSetup()` (lines 154–215)
   already has `_terminals` loaded in memory (populated earlier by `_loadTerminals()`,
   line ~151, the same list the "Existing Till" dropdown uses) — no extra query
   needed. Before the `POST /ric_pos_terminals` insert (line 161), when
   `_creatingNew` is true, check whether `_newTerminalCode.trim()` (case-
   insensitive) already appears in `_terminals` for the selected location; if so,
   set a clear `_error` ("Till code 'T1' already exists at this location — pick
   'Existing Till' instead, or choose a different code.") and return before
   attempting the insert at all. This turns the common real-world case (a second
   setup attempt reusing the same till code) into an immediate, friendly message
   instead of a raw DB constraint error surfacing through `ErrorPresenter.format`.
2. **Icon confusion fix.** `PosKeyboardField`
   (`lib/features/pos/presentation/widgets/pos_keyboard.dart`, lines 282–301) has
   a static `prefixIcon: Icons.keyboard_outlined` and a tappable suffix "Open
   touch keyboard" button using `Icons.keyboard_alt_outlined` — two near-identical
   keyboard glyphs at opposite ends of the same field, confirmed as the exact
   cause of the reported confusion. Fix: remove the static `prefixIcon` entirely
   (it conveys no actionable information — the label text already identifies the
   field) so the ONLY keyboard-glyph icon left on the field is the real, tappable
   action button. Matches `PosAmountField`'s own existing pattern (no prefixIcon,
   only its one `Icons.dialpad` action button) — makes every field type on this
   screen consistent. This single widget change fixes every `PosKeyboardField`
   use app-wide (Till Code, Till Name, and the Client No./Username/Password
   fields on this same screen's Administrator Sign-In step).

## Part 2 — Login screen: link to registration

**File:** `lib/features/auth/presentation/screens/login_screen.dart`, after the
Sign In button (line 477, before the closing `],` at line 478).

Add a centered row below Sign In: plain text "Don't have a registered business?"
+ a text-button-style "Register" link (`context.go(RouteNames.register)`), plus
a small `(?)` `IconButton` (`Icons.help_outline`, compact) immediately next to
it that opens a small `AlertDialog`/popup explaining in 2–3 sentences what
registration does and why a new user would want it (creates their own client
account, company, first location and admin login — same content already summarized
on the Landing screen's "Register Your Business" framing). No navigation change
needed elsewhere — `RouteNames.register` already exists and is already reachable
from Landing.

## Part 3 — Landing screen rebrand

**File:** `lib/features/auth/presentation/screens/landing_screen.dart` +
`lib/core/config/app_config.dart`.

- `app_config.dart` (lines 2–5): change `appName` from `'SAKAL ERP'` to
  `'LiteLink ERP'`, and `appTagline` from `'Sampurna — Complete Business
  Solution'` to `'INTEGRATED. INTELLIGENT. IMPACTFUL'`. Confirmed via grep:
  `AppConfig.appName` is referenced in exactly 3 files (`app.dart` — the
  `MaterialApp` title, `login_screen.dart`, `landing_screen.dart`) — changing
  the constant propagates cleanly everywhere it's meant to, no other rebrand
  surface exists in the app today (CLAUDE.md itself documents the OLD name
  throughout as project history/docs, not runtime UI — out of scope here,
  not touched).
- `landing_screen.dart`'s `_buildLogo()` (lines 63–95): remove the white
  rounded-square "S" container (lines 66–82) entirely; keep the app-name
  `Text` (now reading "LiteLink ERP").

## Part 4 — Registration wizard, Step 0 "About Your Business"

**File:** `register_screen.dart`, `_buildStep0()` (lines 331–353).

1. **Rename field** (line 338): "Business / Trading Name" → "Business / Trading
   Company Name" (label text only — `_businessNameCtrl` and the backend
   `p_business_name` param are unchanged).
2. **Country → dropdown, 4 fixed options.** Replace the free-text `_countryCtrl`
   field (line 339) with a `_dropdownField`-style dropdown restricted to
   `['India', 'Zambia', 'United Arab Emirates', 'Democratic Republic of Congo']`
   (matches this app's own existing supported-tenant set — Zambia/DRC/India are
   already the 3 accounting standards offered on Step 3, UAE is new but a plain
   string value needs no backend change since `p_country` is already a free
   TEXT param). Keep a `TextEditingController`-equivalent string state
   (`_country`) instead of a controller, defaulting to the first option.
3. **Phone: country-code prefix + per-country digit validation.** Replace the
   plain `_field(_phoneCtrl, 'Phone Number', ...)` (line 349) with a `Row`:
   a small non-editable prefix chip showing the dial code derived from the
   selected Country (`India→+91`, `Zambia→+260`, `United Arab
   Emirates→+971`, `Democratic Republic of Congo→+243`, via a small
   `const Map<String,String> _countryDialCodes`), and a `TextFormField` for
   the national number with `FilteringTextInputFormatter.digitsOnly` and a
   validator checking the expected digit COUNT for that country (`India`→10,
   `Zambia`→9, `UAE`→9, `DRC`→9 — a small `const Map<String,String,int>`
   equivalent `_countryPhoneDigits`). On submit, concatenate dial code +
   digits into `p_phone` exactly as today (backend param unchanged). Update
   the dial-code prefix live when Country changes (`setState` on the country
   dropdown's `onChanged`).

## Part 5 — Registration wizard, Step 1 "Company Details"

**File:** `register_screen.dart`, `_buildStep1()` (lines 355–387).

1. **Help tooltips** on both "Business / Trading Company Name" (shown again
   here only as read-only context, if at all — confirm during implementation
   whether to show it) and "Company Name" (line 362): a small `(?)` icon next
   to each label (or a `Tooltip`-wrapped `Icon(Icons.info_outline, size:14)`)
   explaining the distinction — Business/Trading Name is the overall
   registered entity (what `ric_clients.client_name` stores), Company Name is
   this specific operating company under that client (what
   `ric_companies.company_name` stores — a client can have multiple companies
   later). Confirmed via `fn_register_client.sql` these ARE two genuinely
   different columns on two different tables, not redundant.
2. **Back navigation** — confirmed via direct code read
   (`build()`, lines 183–191) that an AppBar back-arrow `IconButton` ALREADY
   renders for every step after the first (`_step > 0`), including this one,
   calling the existing `_back()` method (line 115). No code change needed
   here — will verify live during manual testing that it's actually visible/
   discoverable (not just present in code) before concluding nothing further
   is needed; flagging this explicitly so the user can confirm it's really
   missing rather than just easy to miss against the dark header.
3. **Relabel "Local Currency (regional)"** (line 379) → reflects what it
   actually means in practice for this user base (a stable preferred-reporting
   currency like USD, tracked alongside the true base currency — not
   "regional" at all): new label **"Other Currency You Want to See Reports
   In"**. No behavior change — still the same `_localCurrency`/
   `p_local_currency` value, same dropdown/options, same auto-suggest-
   accounting-standard side effect (`_onLocalCurrencyChanged`, line 105).

## Part 6 — Registration wizard, Step 2 "Your First Location"

**File:** `register_screen.dart`, line 65 (`_locationTypes` list) +
`_buildStep2()` (lines 389–414).

Add `'RETAIL_SHOP'` to `_locationTypes` (currently `['STORE', 'WAREHOUSE',
'OFFICE']`) with a friendly display label "Retail Shop" (the dropdown today
shows the raw enum string directly via `_dropdownField`'s `Text(e)` — either
switch this one dropdown to a label-mapping version, matching how
`_accountingStdCard` already does title-vs-value separation on Step 3, or
confirm `ric_locations.location_type` has no CHECK constraint limiting its
values before adding a new one (needs a quick live check during
implementation — `STORE`/`WAREHOUSE`/`OFFICE` are already free-form TEXT per
the registration function's own `upper(trim(p_location_type))`, no backend
migration anticipated, but must confirm no CHECK constraint rejects a new
value before shipping).

## Part 7 — Registration wizard, Step 3 "Accounting Setup"

**File:** `register_screen.dart`, line 51.

Change the initial default `_accountingStd = 'OHADA'` → `'INDIAN'`. Per the
user's own confirmed choice: this changes only the value shown when the
wizard first opens — the existing currency-based auto-suggestion
(`_accountingStdByCurrency` map, lines 99–103, triggered by
`_onLocalCurrencyChanged`) stays completely intact, so choosing CDF or ZMW as
the "Other Currency" on Step 1 still auto-suggests OHADA/Zambia respectively,
exactly as today — only a user who never touches that dropdown (or picks a
currency with no mapped standard) sees Indian as the default.

## Part 8 — Registration wizard, Step 4 "Administrator Account" — new email field

**File:** `register_screen.dart`, `_buildStep3()` (lines 416–472, this is the
Admin step despite the confusing method name — step index 4) + backend
`fn_register_client.sql`.

Per the user's confirmed choice: this is a genuinely separate email from Step
1's business-contact email, not a reuse.

- **Flutter:** add `_adminEmailCtrl` (new `TextEditingController`, disposed
  alongside the others in `dispose()`), a new required `_field(...)` with
  email-format validation (same pattern as Step 1's `_emailCtrl` validator,
  lines 344–347), placed logically before Username (so the flow reads Name →
  Email → Username → Password → Confirm). Add `'p_admin_email':
  _adminEmailCtrl.text.trim()` to the `fn_register_client` RPC payload
  (`_submit()`, around line 126).
- **Backend, `fn_register_client.sql`:** add a new `p_admin_email text`
  parameter. Change the `rim_users` insert (lines 91–102) to use
  `lower(trim(p_admin_email))` instead of `lower(trim(p_email))` for the
  `email` column — `p_email` stays exclusively the business/registration
  contact written to `ric_clients.registration_email` (line 55, unchanged).
  Add a second duplicate-email guard mirroring the existing one at lines
  32–39, but checking `rim_users.email` instead of `ric_clients
  .registration_email` (needed regardless of whether Part 11's email-login
  migration ships, since two admins sharing one login email would already be
  confusing — becomes load-bearing once Part 11's global unique index on
  `rim_users.email` exists, since that migration will reject a duplicate at
  the DB level anyway with a much less friendly error if this app-level check
  isn't also in place first).

## Part 9 — First-login informational popup (NOT a new settings UI)

Per the user's explicit correction: **no new settings screens or fields** —
specifically ruled out building the missing Currency Decimal Places UI. Scope
is narrowed to: redirect a brand-new admin's very first login to the existing
Company Setup screen, and show a one-time informational popup there listing
the 6 settings worth reviewing before transacting, with no new configuration
surface built for any of them.

1. **Detecting "first login."** No existing flag anywhere (confirmed — no
   onboarding/setup-completeness column on `ric_companies`, nothing in
   `fn_login`'s response). Add one: a new nullable
   `ric_companies.first_login_at timestamptz` column (migration). `fn_login`
   (and the new `fn_login_by_email` from Part 11, sharing the same core —
   see that part) sets it via `UPDATE ric_companies SET first_login_at =
   now() WHERE id = v_company_id AND first_login_at IS NULL` as part of the
   same login transaction, and the function's own JSON response includes a
   new `is_first_login: (the value WAS null before this call)` boolean
   alongside the existing fields (`user_id, client_id, client_no, company_id,
   company_name, location_id, full_name, username, must_change,
   access_token` — confirmed this exact shape from migration 204, the latest
   live `fn_login`; must re-verify directly against the live DB before
   implementing, not just trust the migration file, per this project's own
   documented "grep/verify the latest live definition" lesson).
2. **Flutter redirect.** `login_screen.dart`'s post-login handling
   (`_submitOnline()`) stores the session as today; additionally read
   `d['is_first_login']` from the `fn_login` response and, if true, navigate
   to `RouteNames.company` (`/setup/company`) instead of letting the router's
   default post-login redirect send them to `/dashboard` (the router's
   existing rule at `app_router.dart` lines 205–206 only fires when `loc ==
   login/landing`, so an explicit `context.go(RouteNames.company)` here takes
   precedence and is the simplest, most local change — no router rule
   needed).
3. **The popup itself.** On `company_screen.dart`, show a one-time
   `AlertDialog` (triggered by an `is_first_login` flag threaded in via
   `context.go(RouteNames.company, extra: {'firstLogin': true})` or a
   provider flag read once in `initState`) listing, in plain language, the 6
   settings the user named — Product Coding, Inter-Location Model, Quantity
   Entry Mode, Number Format, Currency Decimal Places, Quick Invoice Setup —
   with one line each on why it matters and that several of them (confirmed
   via existing code comments: barcode/part-number toggles lock once products
   exist; Inter-Location Model locks once transactions exist) become
   difficult or impossible to change later once real data exists. Mention
   that Currency Decimal Places is configured via Finance → Currencies and
   Quick Invoice Setup via its own screen (`RouteNames.quickInvoiceSetup`) —
   pure text pointers, no new fields. A single "Got it" button dismisses it;
   no further tracking needed (it only ever shows once anyway, since
   `is_first_login` is only ever true on that one login).

## Part 10 — Till Setup screen is unaffected by Part 9

Confirmed: `pos_device_setup_screen.dart` has its own fully separate
one-time admin-login path (Part 1 already covers its real bug) and is not
part of the back-office `login_screen.dart` flow at all — no interaction
with Part 9's redirect logic.

## Part 11 — Email-based login (additive, Client ID stays)

Per the user's confirmed choice: implement now, as a **new, additional**
login path — the existing Client ID + Username + Password path is not
removed or changed in any way, so nothing currently working can regress.

### Backend

1. **New migration**: `CREATE UNIQUE INDEX uq_users_email ON rim_users
   (lower(email)) WHERE email IS NOT NULL AND is_deleted = false;` — a
   partial index (matches this project's own established convention for
   exactly this situation, e.g. `uq_users_client_username`'s own case-
   insensitive tightening in migration 204). Checked live: only 13 active
   users total today, 3 with no email, zero duplicates — safe to add
   immediately in this environment; a real production tenant would need the
   same check (and any cleanup) before this ships there, called out
   explicitly as a pre-flight step, not assumed safe everywhere.
2. **Refactor `fn_login` into a shared core + two entry points** — avoids
   duplicating the lockout/bcrypt/JWT-issuance logic (the project's own
   established "shared engine, never duplicate" principle). Before writing
   this, re-fetch the LIVE current definition of `fn_login` directly from the
   database (`pg_get_functiondef`) rather than trusting migration 204's file
   content — this session already found one real function drifted from its
   own migration history once today (`fn_settle_pos_non_cash_tenders`), so
   this step is treated as mandatory, not optional.
   - New private helper, e.g. `fn_login_finish(p_user rim_users, p_client
     ric_clients, p_password text) RETURNS json` — takes an already-resolved
     user+client row pair, does the bcrypt check, lockout counting,
     license/trial-expiry check, JWT claim building/signing, the new
     `first_login_at` update from Part 9, and returns the same JSON shape
     `fn_login` returns today (plus the new `is_first_login` field).
   - `fn_login(p_client_no, p_username, p_password)` — unchanged signature,
     resolves the user row by `client_id + lower(username)` exactly as today,
     then delegates to `fn_login_finish`.
   - New `fn_login_by_email(p_email text, p_password text)` — resolves the
     user row by `lower(email)` alone (now unambiguous thanks to the new
     unique index), its client via `user.client_id`, then delegates to the
     same `fn_login_finish`. A not-found email returns the same generic
     invalid-credentials-style response `fn_login` already uses for a
     wrong client/username combination today — never reveals whether an
     email exists.
3. **`fn_register_client`**: add the Part 8 duplicate-email check against
   `rim_users.email` before this migration ships, so a genuine duplicate hits
   a friendly `ADMIN_EMAIL_EXISTS`-style exception instead of the raw unique-
   index violation this migration introduces.

### Flutter

**File:** `login_screen.dart`. Default the form to **Email + Password**
only (no Client ID, no Username field) — calls the new
`/rpc/fn_login_by_email`. Add a small, clearly-labelled text link/toggle
("Sign in with Client ID instead") that switches the form to today's
existing Client ID + Username + Password layout and calls the existing
`/rpc/fn_login` — fully preserves the current path for anyone who needs it
(shared logins, admins juggling multiple clients, etc.), satisfying the
user's own explicit "Client ID stays, just not asked by default" framing.
The "Work Offline" local-cache flow (keyed by `client_no` via
`LocalStorage`) is unaffected either way: a successful ONLINE login via
either path already resolves and caches `client_no` same as today (the
response shape is unchanged) — offline re-login continues to work exactly
as it does now, regardless of which path was used for the original online
login that seeded the cache.

**File:** `register_screen.dart`'s `_buildSuccess()` (lines 474–592) — the
"Your Client ID ... they will need it to sign in" messaging (lines 558–560)
is now only half-true once Email+Password is the default sign-in path.
Soften the wording to something like "Save this Client ID — you can use it
to sign in with a username instead of email, or share it with teammates who
prefer that." rather than removing the Client ID display (it's still
genuinely useful, just no longer strictly required for day-to-day sign-in).

## Verification

- `flutter analyze` clean on every touched file (`register_screen.dart`,
  `login_screen.dart`, `landing_screen.dart`, `app_config.dart`,
  `pos_device_setup_screen.dart`, `pos_keyboard.dart`, `company_screen.dart`).
- Backend: re-verify the LIVE `fn_login` definition before refactoring it
  (Part 11, step 2) — do not trust the migration file alone. Deploy each new
  migration directly against the dev DB (same `pg` Client pattern used
  throughout this session) and confirm with a direct SQL call before
  considering it done, mirroring how migration 224's fix was verified earlier
  this session.
- Manual smoke test once deployed, covering the user's own exact repro: open
  Login, confirm the new "Register" link + `(?)` popup; go through the
  wizard end to end on a fresh tenant — rebrand visible on Landing, Business
  step shows the renamed field + Country dropdown + country-coded phone
  (test at least 2 of the 4 countries), Company step shows both tooltips +
  renamed currency label, Location step offers Retail Shop, Accounting step
  opens on Indian by default but still auto-switches when CDF/ZMW is picked
  on the previous step, Admin step requires and sends a separate email;
  complete registration, confirm first login lands on Company Setup with the
  one-time popup (second login does NOT show it again); test Till Setup
  twice in a row with the SAME till code on the SAME location and confirm a
  clear, friendly duplicate message instead of a raw DB error, and confirm
  the Till Code/Till Name fields no longer show two near-identical keyboard
  icons; test Email+Password login end to end, then the "Sign in with Client
  ID instead" toggle, confirming both reach the dashboard correctly.

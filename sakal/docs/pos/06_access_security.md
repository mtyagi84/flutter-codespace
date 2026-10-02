# POS User Access, Terminal/Device Security & Permissions

## 1. Organizational mapping
```
Company          -> ric_companies
Store / Branch   -> ric_locations (already the right granularity — a "store" IS a SAKAL location)
POS Register     -> ric_pos_terminals (NEW — the logical checkout counter)
Device           -> ric_pos_devices (NEW — the physical PC/tablet running Flutter)
Shift            -> rih_pos_shifts (NEW)
Cashier Session  -> the existing JWT session (rim_users + fn_login), no new concept needed
Transaction      -> rih_sales_invoices / rih_sales_returns (existing, tagged with pos_shift_id)
```
A location group (`ric_location_groups`, SIMPLE vs INTER_ENTITY) is untouched
by POS — a POS sale is always a normal external sale regardless of inter-
location model; POS never triggers inter-entity posting.

## 2. Access dimensions (kept separate, per the reference BRD's own explicit
recommendation — never collapse these into one mapping)

| Dimension | SAKAL mechanism |
|---|---|
| Capability (what a role can do) | `ric_master_menus`/`ric_user_menus`, new `feature_code`s below |
| Store scope | `ric_user_location_access` (existing, unchanged) |
| POS/terminal scope | `ric_user_pos_terminal_access` (new, `01_data_model.md` §1) |
| Device binding | `ric_pos_devices.bound_terminal_id` (new) |
| Approval limit | `ric_user_sales_controls` (discount), new POS-specific limits (variance threshold, payout threshold — company-level config, not per-user, per `11_open_decisions.md`) |
| Transaction scope | Cashier sees own shift's sales by default; supervisor/manager see the whole store — same `view_allowed` vs. a location/shift filter the screen applies client-side, no new column |

## 3. New feature codes (`ric_master_menus`, group `POS`)
| feature_code | Screen | Notes |
|---|---|---|
| `POS-SALE` | New Sale | `approve_allowed` not meaningful (Save IS Approve, like Quick Invoice) |
| `POS-HOLD` | Hold/Resume | |
| `POS-RETURN` | Return | `approve_allowed` gates return-without-receipt and high-value refunds |
| `POS-PRICECHK` | Price Check | view-only, no `edit_allowed` needed |
| `POS-SHIFT` | Shift (open/cash-up/close) | `approve_allowed` gates variance approval |
| `POS-PAYOUT` | Cash In/Out/Payout/Drop | `approve_allowed` gates above-threshold payouts |
| `POS-APPROVALS` | Approvals queue | supervisor/manager only |
| `POS-ADMIN` | Terminal/device/scheme/loyalty admin | manager/admin only |
| `SL-RET-NOREF` | (sub-permission) Return without receipt | |

## 4. Login decision — PIN-only on the till, password never appears there
A till is a touchscreen with no physical keyboard, so the POS app's login
screen **never shows a username/password field at all** — confirmed with the
user: PIN is sufficient, and typing a password at a shop counter is both
impractical and unnecessary (same pattern Square/Clover/Toast/Odoo POS all
use). Password-based login still exists in SAKAL — it's just not reachable
from the POS surface:

- **Device provisioning (rare, admin-only, back-office screen)** — a real
  username/password sign-in, done once when a device is first set up (or
  after it's deliberately reset), on the existing web/desktop admin login,
  never on the till itself. This is what calls `fn_login` and binds the
  device (`ric_pos_devices.bound_terminal_id`). Once bound, the device stores
  its client/company/location/terminal context in secure storage
  (`flutter_secure_storage` — the same mechanism the JWT already uses; this is
  what the user described as "tenant ID saved in cookies," just the
  cross-platform-correct version of it) — the till never asks for a Client
  No. again.
- **Cashier login (every shift, every switch)** — a **4-6 digit PIN** on a
  large on-screen numeric keypad, nothing else. New `rim_users.pin_hash`
  column (bcrypt, same hashing as `password_hash`, never stored or logged in
  plain text) and a new `fn_pos_pin_login(p_device_uid, p_pin)`:
  1. Resolves `(client_id, company_id, location_id, terminal_id)` from the
     device's own binding (`ric_pos_devices`), not from anything the PIN
     entry screen sends — the till can't be tricked into claiming a different
     tenant.
  2. Fetches the small candidate set of active users with
     `ric_user_pos_terminal_access` for THIS terminal (never the whole
     company — keeps the next step fast regardless of company size).
  3. `bcrypt`-compares the entered PIN against each candidate's `pin_hash`
     until one matches (stop at first match since PINs are enforced unique
     per company — see below).
  4. Re-validates everything `fn_login` already checks (active user, store/
     terminal access, device not blocked) and mints the same JWT shape.
  "Forgot PIN" is **not** a password fallback — it's "ask a manager," who
  resets the employee's PIN via their own PIN-authenticated manager action
  (see `fn_set_user_pin` below), still with no password ever typed at the
  till.

### PIN uniqueness, enforced without ever storing a PIN in plain text
A PIN can't be uniqueness-checked with a plain `UNIQUE` index (bcrypt salts
make two different hashes of the same PIN look nothing alike). Instead,
`fn_set_user_pin(p_user_id, p_new_pin)` — called rarely, at employee
onboarding or a manager-driven reset, never at login — `bcrypt`-compares the
candidate PIN against every OTHER active user's existing `pin_hash` **within
that company** (a handful to a few dozen comparisons; fine since this isn't a
per-sale operation) and rejects it with `PIN_ALREADY_IN_USE` on a collision.
Scope is per-company, not per-client, since a PIN only ever needs to
disambiguate within the set of users `fn_pos_pin_login` searches (§ above).

### Till idle-lock (folded into Phase 1, 2026-10-02)
A till left unattended mid-shift must not stay usable. New
`ric_companies.pos_idle_lock_minutes` (default 3) — purely a client-side
timer in the POS app, reset on any touch/keypress; on timeout, the screen
shows the same PIN-pad overlay as Login, **without ending the session or the
JWT** — unlocking just re-verifies the PIN belongs to an authorized user at
this terminal (any authorized user, not necessarily the one who locked it —
matches a real shared till where a different cashier might pick it back up)
and dismisses the overlay. No new table: this is a UI state plus one company
column, not a transaction.

### Lockout is device-scoped, not user-scoped
A wrong PIN doesn't identify who it was meant for, so the usual "lock that
user's account after N failures" doesn't apply directly. `ric_pos_devices`
gains `failed_pin_attempts INTEGER DEFAULT 0` and `pin_locked_until
TIMESTAMPTZ` — mirrors `rim_users.locked_until`'s shape, but keyed to the
device: N consecutive failed PIN attempts on one till locks PIN entry on
THAT device for a cool-down period, protecting an unattended terminal without
needing to guess which employee was being targeted. Resets to 0 on any
successful PIN login.

At either tier, after success the app additionally validates: active
`ric_user_location_access` for the store, active `ric_user_pos_terminal_access`
for the terminal (date-effective — `valid_from/valid_to` checked against
`now()`), the device is registered and `bound_terminal_id` matches (or is
unbound and this is a first-time registration flow), the device is not
`is_blocked`, and — if the company enables it — a concurrent-session rule
(`ric_companies.pos_allow_concurrent_sessions`, new, default false). **Changing
a terminal identifier in the UI must never bypass this check** — the same
server-side re-validation principle as every other client-trusts-nothing rule
in this schema (CLAUDE.md's "never trust the client payload for a frozen
field").

## 5. Device registration & security
A device generates a stable `device_uid` on first run (stored via
`flutter_secure_storage`, same mechanism already used for the JWT) and
registers itself (`fn_pos_register_device`, SECURITY DEFINER, callable without
an existing binding) — an admin/manager then binds it to a terminal.
`is_blocked=true` denies any new transactional authorization "as soon as
connectivity allows" — for an offline device already mid-shift, the block
takes effect the moment it next reaches the server (consistent with this
app's existing offline philosophy: nothing can be revoked instantly on a
device with no network, only delayed until it reconnects). Secrets: unchanged
from the rest of the app — no service-role key is ever shipped to Flutter;
RLS is the real boundary (`auth_rw_<table>` on every new POS table).

## 6. Approval / capability philosophy
Unchanged from SAKAL's existing convention stated throughout CLAUDE.md: **a
missing permission row always means deny, never permissive** (the same rule
`ric_user_sales_controls` and `fn_check_approve_permission` already
establish) — applied identically to every new POS feature code and to
`ric_user_pos_terminal_access` itself (no row = no terminal access, full
stop, never "unrestricted" the way `v_user_accessible_locations` treats a
missing location-access row).

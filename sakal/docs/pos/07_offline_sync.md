# Offline Strategy

POS is the single highest offline-exposure screen in the app — a supermarket
till cannot simply stop working because connectivity drops mid-shift. This
extends SAKAL's existing offline design (`SyncEngine`, `generateLocalId()`,
Drift cache, "Approve stays online-only") rather than inventing a parallel
mechanism, with one deliberate widening of scope.

## 1. What's cached locally (same `GenericLookupCache`/per-feature Drift table
pattern already used app-wide)
Products + barcodes + prices (already cached for Quick Invoice), tax groups,
active schemes/promotions (a snapshot — see "cached promotion risk" below),
the cashier's terminal/shift config, payment methods, currencies + the most
recent exchange rates, and the unposted transaction queue. Same "master data:
full replace on sync, server wins" / "transactions: append-only, PENDING ->
SYNCED, never re-pushed" rules from CLAUDE.md's Offline Strategy section.

## 2. Offline-capable operations (v1 scope)
- **Sale** — DIRECT mode, CASH sale_type, exactly like Quick Invoice today:
  `fn_save_sales_invoice` queued via `SyncEngine.enqueue`, status stays
  `DRAFT` until synced + approved. AGAINST_QUOTATION/ORDER stays online-only
  (unchanged — needs a live cross-device check).
- **Hold/Resume** — a `HELD` status row is just a DRAFT-shaped cache row;
  resuming it offline is the same local read Quick Invoice already does for
  a resumed DRAFT.
- **Shift open/close** — **new scope beyond Quick Invoice.** Opening a shift
  offline queues `fn_save_pos_shift_open`-equivalent the same way; a shift
  opened offline gets a local shift id until synced. Cash-up/close is
  **more cautious**: the expected-cash formula depends on every sale/payout
  that happened during the shift, which may itself still be queued — so an
  offline close computes `expected_cash` from whatever's in the **local**
  cache (same formula, local data) and is clearly marked provisional
  (same `PROVISIONAL` watermark convention Quick Invoice's print already uses
  for an unsynced document) until the shift's own sync completes and the
  server recomputes/confirms the same figure. A mismatch between the
  provisional and server-confirmed expected cash is flagged for the manager,
  never silently reconciled.
- **Cash-in/out/payout** — queued the same way as any other local
  transaction.

## 3. Deliberately online-only (unchanged from the rest of the app)
Return (needs a live "how much already returned" check — same reasoning as
Sales Return today, migration 099's own header comment), exchange, any
approval requiring live supervisor verification against the server's own
`ric_user_sales_controls`/menu permissions, and loyalty redemption above a
small offline-safe cap (see `11_open_decisions.md` DEC-03 — the reference
BRD explicitly flags "whether loyalty redemption is allowed offline" as a
policy decision, not an engineering default).

## 4. Idempotency
`generateLocalId()` already produces a globally-unique `LOCAL-<millis>-<rand>`
id used as the queued document's key — unchanged mechanism, extended to
`SyncEngine._renameLocalDocument`'s switch statement with new cases for
`'POS_SHIFT'`, `'POS_PAYOUT'`, and `'SALES_INVOICE'` already has its own case
(POS sales reuse it as-is). The server-side RPCs these calls hit
(`fn_save_sales_invoice`, a new `fn_save_pos_shift_open`/`fn_close_pos_shift`,
`fn_save_pos_payout`) are naturally idempotent the same way every other
`fn_save_*` in this schema already is: a retry with the same business key
(e.g. the same shift's open event) either no-ops or safely re-saves a DRAFT —
no separate "client transaction id" column is needed beyond the local-id
pattern already proven across the app.

## 5. Offline limits (company-configurable, per `11_open_decisions.md` DEC-03)
Maximum offline duration before a terminal is forced to reconnect before
opening a new sale, maximum offline sale amount, which tender methods are
allowed offline (cash always; card/mobile money only if the physical terminal
itself works offline, which is a hardware integration concern outside this
app's control), whether loyalty redemption is allowed offline, and whether a
CREDIT (customer-account) sale is allowed offline at all (recommended default:
no — a credit sale needs a live credit-limit check, same reasoning Sales
Order's own credit controls already apply).

## 6. Device/session validation while offline
A device already authorized before going offline keeps working for the
company's configured "offline grace period" (new setting,
`ric_companies.pos_offline_grace_hours`) — the device-blocking check in
`06_access_security.md` §5 can only actually take effect once the device
reconnects, consistent with the rest of this app's offline philosophy.

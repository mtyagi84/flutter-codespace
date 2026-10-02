# Shift & Cash Management

## 1. Shift lifecycle
```
(no shift) -> OPEN -> CASH_UP_PENDING -> CLOSED
```
- **Open**: cashier picks a terminal they have `ric_user_pos_terminal_access`
  for, enters the opening float per currency
  (`rih_pos_shift_opening_float`), optionally counts it by denomination
  (`rid_pos_shift_denomination_counts`, same table used at close), adds
  opening notes. A company policy (`ric_companies.pos_require_opening_approval`,
  new, default false) can require a supervisor to confirm an opening float
  that deviates from the terminal's configured standard float before the
  shift actually opens.
- **Operate**: sales, returns, cash-in/out, payouts, drops all tag the shift
  via `pos_shift_id`.
- **Cash-up (CASH_UP_PENDING)**: the cashier (or a supervisor) enters counted
  cash — either a direct total per currency or a full denomination count
  (recommended, since it also doubles as a physical count discipline). The
  system computes `expected_cash_*` (formula in `01_data_model.md` §1) and
  `variance_* = counted - expected`.
- **Close**: once variance is within the configured threshold (or approved
  above it), `fn_close_pos_shift` does two things in one transaction: (a)
  freezes every closing/cash-up value — same immutability principle as every
  other approved/posted document in this schema (no in-place edit after
  close; a correction is a new adjusting cash movement, same as a reversing
  journal entry elsewhere in SAKAL); (b) **posts this shift's consolidated GL
  entries** — the Sales/Tax/COGS/settlement vouchers described in
  `03_payments_multicurrency.md` §4, one set per currency actually used this
  shift, tagged `source_doc_type='POS_SHIFT'`/`source_doc_no=shift_no`. Stock
  movements for every sale in the shift already posted in real time at each
  sale's own approve time — nothing stock-related waits for Close; only the
  GL legs do, and only for CASH sales (CREDIT sales in the shift already
  posted their own GL immediately, unchanged). The shift only reaches
  `CLOSED` once both the cash-up freeze and the GL posting succeed together.

## 2. Variance handling
- `variance_reason` is **mandatory** the moment `|variance| > 0.01` in any
  currency, regardless of threshold (good discipline, costs nothing).
- A company-configured `pos_cash_variance_approval_threshold` (per currency,
  or expressed as a %, see `11_open_decisions.md` DEC-07) determines whether
  `variance_approved_by` must be set before Close is allowed — same
  supervisor-password verification pattern as a discount override
  (`fn_verify_discount_override`), reused here rather than inventing a new
  mechanism.
- The variance is **never silently absorbed** into any account without a
  trace — it posts (at Close) as its own small JV: Dr/Cr a
  `CASH_VARIANCE_ACCOUNT` (new `rim_account_link_types` row, company-
  granularity) against Dr/Cr the shift's own cash account, tagged
  `source_doc_type='POS_SHIFT'`.

## 3. Cash-in / cash-out / payout / cash-drop
One table, `rih_pos_payouts`, `movement_type` distinguishes intent:

| Type | Purpose | Drawer effect | GL |
|---|---|---|---|
| CASH_IN | Add cash not from a sale (e.g. change fund top-up from safe) | + | Dr Cash / Cr the source account (Safe/Bank) |
| CASH_OUT | Remove cash for an operational reason, no expense | − | Dr the destination / Cr Cash |
| PAYOUT | A real expense paid straight from the drawer | − | Dr the expense `gl_account_id` / Cr Cash |
| CASH_DROP | Move excess till cash to a safe/bank custody mid-shift | − | Dr Safe/Bank-in-transit / Cr Cash |

Every row requires a `reason_id` (`rim_common_masters`, type
`POS_CASH_MOVEMENT_REASON`) and posts immediately via the existing
`fn_post_voucher('JV', ...)` shared engine — **not** a bespoke posting
function, since this is a plain two-line journal entry with no tax/discount/
stock complexity. A `PAYOUT` above the configured threshold requires
`approved_by` before it can post (DEC-08).

## 4. Denomination counting
`rim_currency_denominations` (new, global default seed per ISO currency —
e.g. USD: 100/50/20/10/5/1 notes + 0.25/0.10/0.05/0.01 coins; company-editable
to match local reality) backs both the opening-float and cash-up count UI.
A company can disable denomination counting entirely
(`ric_companies.pos_require_denomination_count`, default true) and let a
cashier just type one total per currency — `rid_pos_shift_denomination_counts`
stays empty in that case and `counted_cash_*` is entered directly on the
shift header.

## 5. Offline
Shift open/close is made offline-capable (a genuinely new scope beyond what
Quick Invoice ever needed — see `07_offline_sync.md`) since a cashier cannot
reasonably be asked to find a different screen mid-shift if connectivity
drops. Cash-in/out/payout queue through the same `SyncEngine` mechanism as a
DRAFT sale.

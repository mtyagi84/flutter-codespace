# Sales Invoice (Quick Invoice)
## Screen Requirement Document

**Module:** Sales (fourth screen — after Sales Quotation, Sales Price Master, Sales Order)
**Route:** `/sales/invoices` (list + entry), `/sales/invoice-manager-review`, `/setup/quick-invoice-setup`
**Status:** ✅ Built — migrations 088/089 run successfully against real Supabase (2026-07-16/17), full Flutter layer built, pgTAP test suite (`089_sales_invoice_test.sql`, 20 assertions) iterated through several real execution bugs (listed in §6) and confirmed by the user to run green end-to-end. Committed to git (`2c0ce7d`), plus a QA-tester pass (7 bugs fixed) and 3 Codespace compile-error fixes on top. Migration 090 (2026-07-18) closes bug 17's deferred SI/SI voucher-numbering collision — see §6.

This document is the single source of truth for this screen — kept up to date across sessions specifically so recurring details (barcode, batch/serial, negative-stock rules, charges) never have to be rediscovered. Update it whenever anything below changes.

---

## 1. Screen Name

**Sales Invoice** — three screens:
- **Quick Invoice Setup** — per-user admin config (location, cash customer, cash accounts, default sales person). Dedicated screen, lockable per user once they've made ≥1 invoice.
- **Quick Sales Entry / List** — the fast POS-style invoice screen itself, plus its list.
- **Sales Invoice — Manager Review** — online-only screen listing unposted (`DRAFT`) invoices (offline-synced or a rare online failure), showing live stock availability, and posting them.

---

## 2. Screen Description

### Why this screen is needed
Sales Invoice is where a sale actually becomes real: stock leaves, GL posts, and (optionally) cash gets collected. Unlike every prior Sales-module screen, this one is deliberately **not** a heavyweight multi-step document — it's built for speed at a register or counter, where a cashier picks Cash/Credit, adds products (scan or pick), and saves — done. Company-level toggles decide whether stock dispatch and cash collection happen immediately at Save, or are deferred to future dedicated screens.

### Where it sits in the ERP
```
Sales Quotation ──(Convert)──▶ Sales Order ──┐
                                              ├──▶ Sales Invoice ──▶ GL + Stock (+ Cash Receipt)
Direct entry (no quotation/order) ───────────┘
```
Three independent ways to reach an invoice — **Direct**, **Against Quotation**, **Against Order** — but unlike Sales Order's own partial-conversion model, invoicing a Quotation or Order is **whole-document only**: every line copied verbatim, no partial quantity, and once invoiced that source document can never be invoiced again (until/unless the invoice itself is cancelled).

### Auto-approve, not a multi-stage workflow
Every other module in this app is Save Draft → Approve as two distinct, visible user actions. Quick Invoice's "Save" *is* the approve step — online, Flutter chains `fn_save_sales_invoice` then `fn_approve_sales_invoice` invisibly in one click. This is a deliberate UX deviation, not a shortcut: the underlying two-function shape is identical to every other module, so the exact same functions serve the offline path (see below), where a `DRAFT` status is real and momentary rather than fictional.

### Offline behavior
Online supports all 3 modes. **Offline supports Direct mode only** (Cash or Credit) — Against-Quotation/Order need a live "not already invoiced by someone else" check. An offline save queues via the existing `SyncEngine`/`generateLocalId()` mechanism (same as every other offline-capable module) and prints immediately off in-memory state with a clearly marked **PROVISIONAL** watermark (the real `invoice_no` isn't assigned until sync). Once synced, the invoice exists with a real number in `DRAFT` status — **not** auto-approved — until a manager reviews it on the new Manager Review screen, which shows live stock availability and calls the same `fn_approve_sales_invoice` used everywhere else. This same screen is also the safety net for the rare *online* case where approve fails right after save (e.g. a stock race condition).

---

## 3. Screen Layout

### 3.1 Quick Invoice Setup (admin screen)
Per-user list + entry: pick a user, assign Location, Cash Customer (`rim_accounts`), Local Cash Account, Base Cash Account, Default Sales Person (prefill only). Once that user has saved ≥1 invoice, the row locks — shown with a clear "Locked — N invoices already made" banner, no edit controls rendered.

### 3.2 Quick Sales List Screen
`SakalAdaptiveList` — Invoice No, Date, Mode (Direct/Against Quotation/Against Order badge), Sale Type (Cash/Credit), Customer, Status (`DRAFT`/`APPROVED`/`CANCELLED` chip), Grand Total, Sales Person. Filters: Location, Status, Sale Type, Date range. `+ New Invoice` (top-right) opens the mode picker.

### 3.3 Quick Sales Entry Screen
```
┌──────────────────────────────────────────────────────────────────────┐
│  Quick Sales                                          [Save Invoice] │
│  INV/KIN/2026/00001 · Cash                                  [Print]  │
├──────────────────────────────────────────────────────────────────────┤
│  Sale Type: (●) Cash  ( ) Credit          Mode: Direct/Quotation/Order│
│  [Cash]  Name: [____]  Mobile: [____]  Address: [____]  (optional)   │
│  [Credit] Customer: [code] name ▾        Sales Person: [____▾]       │
│  Header Discount %: [___]  (fans out to all lines, editable per line) │
├──────────────────────────────────────────────────────────────────────┤
│  Lines                          [+ Add Line] (Direct only)  [Scan: _]│
│  # | Product | UOM | Qty | Rate🔒 | Disc%editable | Tax | Total | [x]│
│    ↳ Batch/Serial Allocation — auto-filled (FEFO), edit if needed    │
│      [Reset to FEFO]                                                 │
├──────────────────────────────────────────────────────────────────────┤
│  Charges (optional — DIRECT: editable; AGAINST_*: read-only carried  │
│  forward from the source Quotation/Order)          [+ Add Charge]    │
│  Charge▾ | Amount/Percent | ADD/DEDUCT · amount | Tax: n | [x]        │
├──────────────────────────────────────────────────────────────────────┤
│  Remarks/Note: [_______________________________________] (optional)  │
├──────────────────────────────────────────────────────────────────────┤
│  Subtotal:  Discount:  Charges:  Tax:  GRAND TOTAL                   │
├──────────────────────────────────────────────────────────────────────┤
│  Collect Payment (shown only if company allows)                      │
│  Local [____]   Base [____]                                          │
└──────────────────────────────────────────────────────────────────────┘
```
- Header buttons top-right next to the title (standard convention); mobile stacks below.
- Sale Type toggle switches the customer block: Cash shows free-text name/mobile/address (optional, snapshot-only, never creates a `rim_accounts` row); Credit shows the standard Account-Picker Autocomplete + a Sales Person dropdown (prefilled from the user's Quick Invoice Setup default, editable).
- Against-Quotation/Against-Order mode: no `+ Add Line`, lines pre-filled read-only from the source document (whole-document, no partial), hidden entirely when offline.
- Discount % per line: editable up to the cashier's own `ric_user_sales_controls` cap; entering more triggers the supervisor override popup (username/password).
- Batch/serial candidate picker per line appears only when `stock_dispatch_mode` will be `IMMEDIATE` for this invoice (company flag `quick_invoice_dispatch_stock=true` at save time) **and** the product's own `tracking_type` is `BATCH`/`BATCH_WITH_EXPIRY`/`SERIAL`. See §4's Batch/Serial subsection for the FEFO auto-fill behavior — this is the one thing about this screen that differs from every other batch/serial-tracked module in the app.
- Charges card: DIRECT mode is freely editable (Add/Remove/edit amount); AGAINST_QUOTATION/AGAINST_ORDER mode shows the source document's own charges, read-only (server ignores any client-submitted charges in these two modes and copies the source verbatim regardless).
- Collect Payment section appears only when `quick_invoice_collect_cash=true`; two amount fields (local/base currency), independently editable, default to the grand total in the applicable currency, can be reduced (partial) or zeroed.

### 3.4 Sales Invoice — Manager Review
Pick a Location → list of `status='DRAFT'` invoices for it (mode/type/customer/amount/line count). Expand a row to see each line's live stock position (current stock vs. requested qty, flagged if insufficient and negative-stock isn't allowed) as a read-only preview. `Post` per row (or bulk "Post All Eligible") calls `fn_approve_sales_invoice`; a failure shows inline for that attempt without persisting an error state, and the invoice stays `DRAFT` for the manager to act on (adjust qty via edit, cancel, or wait and retry).

---

## 4. Screen Functionality

### Header fields
| Field | Behavior |
|---|---|
| Invoice No | Auto-assigned on save, format `SI/{LOC}/{YYYY}/{SEQ5}` (per-location, `fn_next_trans_no`). Offline: shows a `LOCAL-...` placeholder, watermarked provisional, until sync. |
| Invoice Date | Defaults to today. |
| Invoice Mode | `DIRECT` / `AGAINST_QUOTATION` / `AGAINST_ORDER` — chosen once at creation from the list screen's "+ New Invoice" picker; Against-Quotation/Order hidden offline. |
| Sale Type | `CASH` / `CREDIT` — toggle. |
| Customer | Cash: always the user's own `cash_customer_id` from Quick Invoice Setup (never shown as a picker); free-text name/mobile/address captured alongside for that transaction only. Credit: Account-Picker Autocomplete, `account_nature='Customer'`. Against-Quotation/Order: inherited from the source document (always a real customer by that point) — see §6 bug (11), the header-payload `customer_id` is legitimately absent in these two modes. |
| Sales Person | Dropdown of `rim_users`, prefilled from setup's `default_sales_person_id` when set. |
| Header Discount % | Optional; fans out to every current/future line's own `discount_percent` until a line is edited individually (line always wins). Same governance path as any line discount. Resolves the supervisor-override dialog **once** for the whole batch, not once per line. |
| Remarks | Optional free text. |

### Discount governance
Reuses `ric_user_sales_controls` (built for Sales Order) for the cashier's own `can_give_discount`/`max_discount_percent`. `discount_given_by` is stamped on **every** discounted line (not just overridden ones) — the cashier's own id when within their own cap, or a supervisor's id when an override was used. Exceeding the cap opens a small dialog (username + password); on submit, `fn_verify_discount_override` checks the credentials (same bcrypt check `fn_login` uses, but without touching lockout/telemetry or minting a token) and the supervisor's *own* `ric_user_sales_controls`, returning their identity on success. `fn_save_sales_invoice` re-verifies server-side that any over-cap line has a valid, currently-eligible `discount_given_by` — never trusts client-only enforcement.

### Price
Direct mode: `fn_get_active_price` resolves the rate exactly as Sales Order does (locked, `price_source='PRICE_MASTER'`, override path gated by `can_override_price` + a reason, `price_source='MANUAL_OVERRIDE'`). Against-Quotation/Order: rate frozen verbatim from the source line (`price_source='QUOTATION'`/`'ORDER'`).

### Charges (added post-design-review, before first Supabase run)
**Origin**: not in the original plan — user asked directly "did you consider charges like Sales Order/Quotation have?" mid-build. It was a real gap: converting an AGAINST_QUOTATION/AGAINST_ORDER document with a real freight/packing charge on it would have silently dropped that amount from the invoice and posted no GL for it. User's scope answer (asked via question, not assumed): **both** DIRECT ad-hoc charges **and** AGAINST_* carry-forward — not one or the other.
- **Schema**: `rid_sales_invoice_charges` (mirrors `rid_sales_order_charges`/`rid_sales_quotation_charges` exactly — `charge_id`, `charge_name`, `is_taxable`, `tax_id`, `nature` ADD/DEDUCT, `gl_account_id`, `amount_or_percent`, `percent`, `amount`, `tax_amount`, `allocation_factor`), plus `rih_sales_invoices.charges_amount` and `rid_sales_invoice_lines.charge_amount`/`landed_amount` (apportioned share of charges onto each line, same allocation-factor idiom as Sales Order/Quotation).
- **DIRECT mode**: charges are freely client-supplied every save (same "always editable" convention as Sales Order) — reuses the identical apportionment formula (`allocation_factor = charge.amount / subtotalBeforeCharges`, fanned back onto each line as `charge_amount`/`landed_amount = final_amount + charge_amount`) and the identical Charges-card widget, ported over from `sales_order_entry_screen.dart`.
- **AGAINST_QUOTATION/AGAINST_ORDER mode**: charges are server-copied **verbatim** from the source document's own `rid_sales_quotation_charges`/`rid_sales_order_charges` — the client's own `p_charges` payload is **ignored** in these two modes. Deliberately *stricter* than Sales Order's own charges handling (which stays freely client-editable in every mode, since Order never posts GL and allows partial-qty conversion) — Sales Invoice already established "nothing left for the client to legitimately choose" for line items in these two modes, and charges follow the identical rule for the identical reason.
- **GL posting — the first time any Sales-module charge's `gl_account_id` actually posts anywhere** (Quotation/Order never post GL at all): one CR (ADD) or DR (DEDUCT) leg straight to the charge's own `gl_account_id` (never `fn_resolve_account_link` — a charge's account is captured directly on its own row at entry, same as GRN/PO charges), plus one CR/DR tax leg to `rim_taxes.gl_output_account_id` when the charge `is_taxable`. The charge's own `tax_amount` is **trusted as stored** rather than recomputed server-side — unlike a product line's tax *group* (multiple member taxes needing rate-weighted apportionment, which this module does recompute for product lines), a charge references exactly one `tax_id`, so there's no apportionment ambiguity to protect against.
- **Flutter gap found while porting**: `_loadTaxRates` originally only resolved rates for taxes that are members of some product's tax *group* — a charge's own standalone `tax_id` could easily not be a group member, silently showing 0% charge tax on screen. Fixed by unioning `_additionalCharges`' own taxable `tax_id`s into the same rate-fetch call.
- **Offline scope**: only the header's own `charges_amount` rollup is cached locally (Drift `SalesInvoicesCache.chargesAmount` — keeps a reopened offline DRAFT's totals breakdown accurate). The individual charge line items are **not** cached — same narrow, already-documented limitation as batch/serial allocations on an offline-created DRAFT (see below).
- **Print**: `rid_sales_invoice_charges` is registered as a print table (`'charges'`, alongside `'lines'`) with `charge_name`/`amount` row fields, and `totals.charges_amount` is a scalar field — wired into `print_field_registry.dart`, the default template (a Charges total row between Discount and Tax), and `print_sample_data.dart`.

### Stock dispatch & cash collection — company-controlled
`ric_companies.quick_invoice_dispatch_stock`/`quick_invoice_collect_cash` (freely editable, no lock — only affects future invoices). Snapshotted onto the invoice header at creation as `stock_dispatch_mode`/`cash_collection_mode` (`IMMEDIATE`/`DEFERRED`) so a later company-flag change never reinterprets an existing invoice's history.
- `IMMEDIATE` dispatch: `fn_post_stock_movement(trans_type='SALES_INVOICE', ...)` per line at approve time (existing negative-stock/batch-serial rules apply unchanged — see Batch/Serial below), plus a `COS` (Cost of Sales) journal voucher.
- `DEFERRED` dispatch: no stock/batch/serial touched here at all — left for a future Delivery screen (not built in this pass).
- `IMMEDIATE` collection: up to two Receipt Vouchers (local/base currency, whichever was actually collected) auto-generated and settled against this invoice's own bill.
- `DEFERRED` collection: the invoice's Customer DR line still posts with `inv_bill_no=self`, so it shows up in the existing `v_pending_bills` view for a future Receipt screen to settle — zero extra plumbing needed.

### Status lifecycle
```
DRAFT ──approve (online: automatic; offline: via Manager Review)──▶ APPROVED
  │
  └──────────────────────Cancel───────────────────────────────────▶ CANCELLED
```

### Buttons
| Button | Gate | Behavior |
|---|---|---|
| Save Invoice | `canAdd`, status = DRAFT (or new) | Online: save then immediately approve, one click. Offline: save only, queued. |
| Print | once an invoice number (real or provisional) exists | Works from in-memory state; provisional watermark pre-sync. |
| Cancel | `canApprove`, status ∈ {DRAFT, APPROVED — but APPROVED is blocked server-side, see below} | Requires a reason; frees the source Quotation/Order for re-invoicing if it was Against-Quotation/Order. **DRAFT only in practice** — `fn_cancel_sales_invoice` raises if status is already `APPROVED` (Immutability principle: once GL/stock posted, no reversal path exists in this build — that's a future Sales Return module's job). |

### Permissions
`ScreenPermissionMixin`, `screenName = '/sales/invoices'` (Manager Review and Quick Invoice Setup use their own new route names). Discount/price governance is via `ric_user_sales_controls`, same as Sales Order.

### Company-configurable line fields — the recurring checklist item
This module follows the exact same two-flag pattern as every other line-entry screen in the app (see CLAUDE.md's "Company-configurable line fields" section) — **do not reinvent this, always grep for the existing convention first**:
- **`showLooseQty`** — `(session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY'`, computed once in `build()`. Gates the "Qty Loose" field on a NEW-lot line (DIRECT mode only — AGAINST_* lines are frozen, qty comes from the source verbatim, no loose/pack split UI at all). When hidden, the Pack field's label becomes bare "Quantity" instead of "Qty Pack".
- **`showBarcode`** — `session?.enableBarcode ?? false`, computed once in `build()`. Gates the barcode scan `TextFormField` on DIRECT-mode lines (`_onBarcodeSubmitted` → `getProductByCode` → `_onProductSelected`). AGAINST_QUOTATION/AGAINST_ORDER lines carry their barcode forward from the source line's own saved `barcode` column (no scan UI needed — there's no independent product-selection step in those modes).
- Both are `!_isAgainstSource &&` — i.e. AGAINST_QUOTATION/AGAINST_ORDER never show either control, consistent with those modes having no line-editing surface at all.

### Batch/Serial — mandatory allocation, negative-stock rule, and FEFO auto-fill
This is the section the project keeps re-discovering gaps in across sessions — full detail, no shortcuts:
- **Gating**: the batch/serial section renders only when `_dispatchStock` (this invoice's `stock_dispatch_mode` will be `IMMEDIATE`) **and** the line's own product `tracking_type` is `BATCH`/`BATCH_WITH_EXPIRY` (batch) or `SERIAL` (serial). `tracking_type` is a per-**product** attribute (`rim_products.tracking_type`) — never a company-level toggle, and none should ever be added for it (documented project-wide rule, re-stated here because it's the #1 thing that gets second-guessed).
- **Mandatory, strict, negative-stock-NEVER**: exactly like every other batch/serial-tracked module (GRN, Material Issue, Purchase Return, Stock Adjustment) — a batch or serial is a specific identifiable lot/unit, not a fungible quantity, so `allow_negative_stock` flags (item- or location-level) **never** apply to it, full stop. This is enforced twice: client-side (`_batchSerialError` blocks Save if batch quantities don't sum to exactly the line's `base_qty`, or the selected serial count doesn't exactly match), and authoritatively server-side inside `fn_post_stock_movement` (`BATCH_INSUFFICIENT_STOCK`/`SERIAL_NOT_IN_STOCK`). Untracked/aggregate products fall back to the normal item-AND-location `allow_negative_stock` combination — but that fallback **never** applies to a tracked line.
- **Candidates**: `getBatchStockBalance`/`getSerialStockStatus` — same generic `v_batch_stock_balance`/`v_serial_stock_status` views every other module uses, filtered to `balance>0`/`status='IN_STOCK'` at this invoice's own location. Batches come back ordered `expiry_date.asc.nullslast` (FEFO); serials come back ordered `serial_no.asc`.
- **FEFO auto-allocation — this screen's own addition, Flutter-only, no schema change** (raised by the user as "a point of discussion," resolved same session as the charges feature): every *other* batch/serial-tracked module makes allocation deliberately manual — correct for a back-office document, wrong for a POS checkout flow where hand-picking a batch on every scan defeats the entire point of "Quick." `_autoAllocateBatchSerial(row)` fills batch quantities / selects serials straight from the candidates' own existing FEFO-ish order, capped at whatever's available per candidate, up to the line's own needed quantity. Wired into: product selection (`_onProductSelected`), barcode scan (`_onBarcodeSubmitted`, via `_onProductSelected`), every qty-field edit (`_onLineQtyChanged`), and the AGAINST_QUOTATION/AGAINST_ORDER candidate-load loops (`_loadFromQuotation`/`_loadFromOrder`). Fields stay fully editable afterward (never a lock), a shortfall is simply left unfilled so the existing error/server check still catches it, and a "Reset to FEFO" button lets the cashier manually re-trigger it after editing. **Re-running always recomputes from a clean slate** — a manual override on that line does not survive a qty edit (accepted speed/simplicity trade-off for this screen specifically). **Not** a `ric_companies` toggle, for the same "tracking_type is per-product, not per-company" reasoning above — this is a per-screen UX behavior, not a company policy choice. `fn_save_sales_invoice`'s own mandatory-allocation validation is unaware of and unaffected by whether the client auto-filled or hand-typed the values.
- **Resume-a-DRAFT**: `_restoreBatchSerialAllocations` (online-only, since it's a `_remote`-only datasource call — see Offline scope below) loads whatever was actually saved (`rid_transaction_line_batches`/`rid_transaction_line_serials` filtered by `source_doc_type='SALES_INVOICE'`) and re-populates the matched candidates — it never re-runs FEFO over an already-saved allocation. This was itself a real gap caught by the mandatory pre-completion self-check (§6, bug found during original build, before this session).

### Offline support
Direct-mode (Cash or Credit) Save works fully offline via the standard Drift cache + `SyncEngine` retrofit pattern (`SalesInvoicesCache`/`SalesInvoiceLinesCache`, schema v21, plus a `_renameLocalDocument` case for `SALES_INVOICE`). Against-Quotation/Order are online-only. Approve is never offline — deferred to Manager Review for anything left in `DRAFT`.
- **Cached locally**: header (including the new `chargesAmount` rollup) and lines.
- **NOT cached locally** (known, narrow, documented limitations — not bugs, deliberate scope cuts given the size of this build): individual charge line items (`rid_sales_invoice_charges` rows) and batch/serial allocations (`rid_transaction_line_batches`/`rid_transaction_line_serials`). Reopening an offline-created, not-yet-synced DRAFT after navigating away loses these two specific details — the invoice's own totals (`grandTotal`, `chargesAmount`) stay correct regardless, since those are computed and cached at save time.

### Print support
Standard `PrintEngine` integration — this is the customer-facing receipt, the single most important print target in the app. Works purely from in-memory screen state (no network calls), so pre-sync offline printing needs zero special-casing beyond a provisional watermark. Charges are printed as their own table (see Charges subsection above). Batch/serial detail is **not** printable on this or any other document in the app yet — a known, explicitly scoped-out gap (`print_field_registry.dart`'s `rowFields` maps don't expose `batch_no`/`expiry_date` anywhere).

---

## 5. Data Flow

### Upstream — what this screen reads
| Source | Purpose |
|---|---|
| `rim_accounts` (`account_nature='Customer'`) | Customer picker (Credit). **Not** `'Income'`/`'Expense'`/`'Asset'`/`'Liability'` — those aren't real `account_nature` values (see §6 bug 7); GL accounts (Sales/COS/Stock/Tax/Cash) all use `'General'`. |
| `ric_user_quick_invoice_setup` | Cash sale defaults: location, cash customer, cash accounts, default sales person |
| `rih_sales_quotations`/`rid_sales_quotation_lines`/`rid_sales_quotation_charges`, `rih_sales_orders`/`rid_sales_order_lines`/`rid_sales_order_charges` | Source data for Against-Quotation/Order modes (lines AND charges, both copied verbatim server-side) |
| `fn_get_active_price` | Locked price resolution for Direct mode |
| `ric_user_sales_controls` | Discount + price-override governance |
| `rim_account_link_types` (`SALES_ACCOUNT`, `COST_OF_SALES_ACCOUNT`, `STOCK_ACCOUNT`) + `rim_taxes.gl_output_account_id` | GL account resolution for lines |
| `rim_additional_charges` + each charge's own `gl_account_id`/`tax_id` | Charges master + GL resolution for charges (captured directly on the charge row, never `fn_resolve_account_link`) |
| `v_batch_stock_balance`/`v_serial_stock_status` | Batch/serial candidates (FEFO-ordered) |
| `ric_companies.quick_invoice_dispatch_stock`/`quick_invoice_collect_cash` | Immediate vs. deferred behavior |

### Tables this screen introduced
| Table | Notes |
|---|---|
| `ric_user_quick_invoice_setup` | Per-user cash-sale defaults; lockable after first invoice. |
| `rih_sales_invoices` | Header. `invoice_mode`, `sale_type`, `quotation_no/date`/`order_no/date` (soft link only — no reservation flag on the source tables), `stock_dispatch_mode`/`cash_collection_mode` snapshots, `charges_amount`. |
| `rid_sales_invoice_lines` | Standard product/qty/rate/discount/tax shape + `discount_given_by`, `source_quotation_line_serial`/`source_order_line_serial`, `charge_amount`/`landed_amount`. |
| `rid_sales_invoice_charges` | Added post-review — mirrors `rid_sales_order_charges` exactly. |

PG functions: `fn_save_sales_invoice`, `fn_approve_sales_invoice`, `fn_cancel_sales_invoice`, `fn_verify_discount_override`, `fn_quick_cash_account_local`/`fn_quick_cash_account_base` (helpers), `fn_lock_quick_invoice_setup` (trigger function).

### Confirmed: real GL/stock impact (unlike every prior Sales-module screen)
`fn_approve_sales_invoice` posts an `SLS` (Sales Voucher) voucher always (including charge CR/DR legs), a `COS` (Cost of Sales) voucher when dispatch is immediate, and up to two Receipt Vouchers when collection is immediate — the first screen in the Sales module pipeline that actually does, and the first place any Sales-module charge's own `gl_account_id` ever posts. `SLS` is a dedicated GL-posting code, distinct from `SI` (which numbers `invoice_no` only) — see §6 bug 17/19 and migration 090.

### Downstream — what consumes this screen's output
- `v_pending_bills` — any invoice's Customer DR line with `inv_bill_no=self` and not yet settled shows here, for either an immediate auto-settlement (this screen) or a future dedicated Receipt screen.
- A future Sales Delivery screen would consume any invoice left with `stock_dispatch_mode='DEFERRED'` — not built in this pass.

### What is NOT in this screen (current, accurate scope exclusions)
- No partial invoicing of a Quotation or Order (whole-document only)
- No Delivery screen (deferred-dispatch invoices just wait) or dedicated Receipt screen (deferred-collection invoices rely on the existing generic `v_pending_bills`) — both explicitly future work
- No new stock-availability-check logic — Manager Review reuses `fn_post_stock_movement`'s existing negative-stock rules unchanged
- No reversal/return path once `APPROVED` — future Sales Return module's job
- Charge-level GL account and tax are captured/trusted as entered, never re-derived via `fn_resolve_account_link` — see Charges subsection

---

## 6. Known bugs found during build & test (chronological — read before touching this module again)

**Found by self-review, before any migration ever ran** (see CLAUDE.md's Sales Invoice section for full detail — summarized here):
1. Invalid PL/pgSQL — `FOR var1, var2 IN SELECT ...` isn't legal, needed a `RECORD` loop variable.
2. Guessed tax-group join table name wrong (`rim_tax_group_lines` vs real `rim_tax_group_members`).
3. Uninitialized-`RECORD` crash when stock dispatch is deferred (COS voucher result read unconditionally).
4. Receipt Voucher cash-drawer lookup used `p_approved_by` instead of the invoice's own `created_by`.
5. Receipt Voucher currency math reused the invoice's own `rate_to_base`/`rate_to_local` instead of resolving fresh rates for each receipt's own `trans_currency` (LOCAL or BASE, not the invoice's currency).
6. Batch/serial mandatory-allocation check only ran inside the DIRECT-mode line loop — silently skipped for AGAINST_QUOTATION/ORDER.
7. Resume-a-DRAFT gap: batch/serial allocations never reloaded when reopening a saved DRAFT — fixed via `_restoreBatchSerialAllocations`.

**Found while running the migration file itself against real Supabase** (user pasted the exact Postgres error each time):
8. `voucher_nature='JV'` used for the `COS` voucher-type seed row — conflated `voucher_type_code` (correctly `'JV'` elsewhere) with the separate `voucher_nature` column, which doesn't allow `'JV'` as a value. Fixed to `'JOURNAL'`.
9. Undeclared `v_check_line RECORD` — the unified batch/serial validation loop referenced a variable never added to the `DECLARE` block.
10. `RETURNS TABLE (user_id UUID, full_name TEXT)` on `fn_verify_discount_override` created an implicit `user_id` variable that collided with `ric_user_sales_controls.user_id` in a query inside the same function — same class of bug already documented for `fn_post_voucher`'s `trans_no`/`trans_date` collision. Fixed by qualifying `ric_user_sales_controls.user_id`.
11. `rid_finance_lines.party_currency` is NOT NULL regardless of whether a voucher line has a real external party — the COS voucher's two lines (pure internal costing) never set `party_amount`/`party_currency`/`party_rate` at all, unlike every other purely-internal voucher in the schema (e.g. Material Issue's `MIC` lines, `068_material_issue.sql`, which set these self-referentially: `party_currency`=`trans_currency`, `party_rate`=1). Fixed by adding the same three keys to both COS lines.
12. `fn_save_sales_invoice`'s CASH/CREDIT customer-resolution block (`IF v_sale_type='CASH' ... ELSE ... END IF`) runs *before* the AGAINST_QUOTATION/AGAINST_ORDER block further down that re-derives `v_customer_id` from the locked source document. A CREDIT sale in either AGAINST_* mode legitimately omits `customer_id` from the payload (it's supposed to come from the quotation/order), but the upfront check raised `'Select a customer.'` before ever reaching that re-derivation. Fixed by scoping the upfront check to `v_invoice_mode = 'DIRECT'` only.
13. Adding new columns (`charges_amount`, `charge_amount`, `landed_amount`) to a `CREATE TABLE IF NOT EXISTS` statement is a silent no-op once the table already exists from an earlier successful run — the columns never actually land on a re-run. Fixed by adding explicit `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements alongside (belt-and-suspenders: the `CREATE TABLE` column list still serves a genuinely fresh install). **This is the general lesson**: once 089 has been run successfully even once, any further column addition to an existing table's `CREATE TABLE IF NOT EXISTS` block needs its own `ALTER TABLE ADD COLUMN IF NOT EXISTS` — the `CREATE TABLE` block alone is not enough on a re-run.

**Found only once the pgTAP test suite actually executed against Supabase for the first time** (fixture-only, not backend bugs):
14. `rim_accounts.account_nature` fixture rows used `'Income'/'Expense'/'Asset'/'Liability'` — not real values. The column is a party/screen-routing enum (`General/Customer/Supplier/Cash/Bank/Employee/Tax`); every GL account should be `'General'` (confirmed against `054_purchase_invoice_test.sql`'s own working fixture).
15. The fixture never created a `rim_financial_years` row covering its own test dates — `fn_check_period_open` (mandatory first check in every `fn_approve_*`/`fn_post_stock_movement`) raised `FY_CLOSED`.
16. The fixture had `can_override_price=false` for both test users and no Price Master rows at all, so every DIRECT-mode save hit `PRICE_NOT_CONFIGURED`. Fixed by flipping `can_override_price=true` + adding `price_override_reason` to every DIRECT-mode line payload — same shortcut Sales Order's own test file (`087_sales_order_test.sql`) already uses for the identical reason, rather than building a full `rih_price_master_headers`/`rid_price_master_lines` fixture.

**Found by re-running the pgTAP suite in a later session (2026-07-17)**:
17. Cash-sale settlement silently never marked the Customer receivable settled (`settled_amount` stayed 0/NULL). Root cause: the SI voucher's own Customer DR line was tagged `inv_bill_no=p_invoice_no` as a "self-reference" stand-in (the real trans_no isn't known until `fn_post_voucher` returns), and the Receipt Voucher's settling line was *also* tagged `inv_bill_no=p_invoice_no` — but `invoice_no` and the SI voucher's own `trans_no` are two separate draws from the same `'SI'` `fn_next_trans_no` sequence (one at save time, one at approve time), so they are never actually equal. `fn_post_finance_voucher`'s settlement lookup joins the settling line's `inv_bill_no` against the original line's real `trans_no` — with the wrong value tagged, it never found a match. Fixed by adding a follow-up `UPDATE rid_finance_lines` right after `fn_post_voucher` returns, correcting the Customer DR line's `inv_bill_no`/`inv_bill_date` to the real `v_si_result.trans_no`/`trans_date` (filtered by `source_line_type='CUSTOMER' AND source_line_no=0`, never by `inv_bill_no` itself — see `feedback_dont_filter_where_on_updated_column.md`), and changing both Receipt Voucher settling lines to tag `inv_bill_no=v_si_result.trans_no` instead of `p_invoice_no`. **Related, fixed 2026-07-18 in migration 090**: `invoice_no` (line numbering) and the SI GL voucher (posting) both used voucher_type_code `'SI'` — the same "numbering code must differ from posting code" anti-pattern this project already fixed for Purchase Bill (`PINV`/`PUR`) and Material Issue (`MISS`/`MIC`). Migration 090 adds a new `'SLS'` (Sales Voucher) code used only by `fn_approve_sales_invoice`'s `fn_post_voucher` call; `'SI'` now numbers `invoice_no` only. Forward-only per user decision — already-`APPROVED` invoices keep their existing `sales_voucher_no` drawn from the old shared `'SI'` counter untouched (Immutability principle), only invoices approved after 090 runs get an `'SLS'`-sequence voucher number. The COS voucher's own `'COS'` code was already distinct from day one and is untouched.
18. Test 15 (`fn_cancel_sales_invoice` on an APPROVED invoice) used `throws_ok(sql, 'cannot be cancelled', description)` — `throws_ok`'s message argument requires an *exact* match, not a substring, and the real message is the full `'Sales Invoice %s is %s and cannot be cancelled — ...'` string with a dynamic invoice_no baked in. Fixed by switching to `throws_like` with the wildcard pattern `'%cannot be cancelled%'` — the correct pgTAP tool when the exact message can't be reconstructed ahead of time (dynamic values) or isn't worth pinning down exactly. Test-only fix, no backend behavior changed.

**Found/fixed 2026-07-18 (migration 090)**:
19. See bug 17's "Related, fixed" note above — `'SI'`/`'SLS'` numbering/posting split, mirroring Purchase Bill's `PINV`/`PUR` and Material Issue's `MISS`/`MIC`. `fn_approve_sales_invoice` reproduced verbatim from 089 with exactly one literal changed (the `fn_post_voucher` call's `voucher_type_code`).

**Found via user hands-on testing 2026-07-18, all fixed same session — full detail now in CLAUDE.md's Sales Invoice section (search "UI/UX pass, 2026-07-18")**:
20. **Real crash** — Against Quotation/Against Order both threw `type 'List<dynamic>' is not a subtype of type 'List<_InvoiceLineRow>'` the moment a source document was picked. Root cause: `_loadFromQuotation`/`_loadFromOrder` typed their `ds`/`session` params as `dynamic`, which silently drops static generic-type inference on `.map(...).toList()`. Fixed by typing them `SalesInvoiceRepository`/`UserSession`, matching `_loadExisting`'s own pattern.
21. **New Invoice flow redesigned** — no more upfront mode dialog; "New Invoice" opens straight into DIRECT mode with an inline Direct/Against Quotation/Against Order `SegmentedButton` next to Cash/Credit, switchable anytime (confirm-and-discard if content was already entered).
22. **Line layout redesigned** — the "Lines" card + "Add Line" button is gone; every row has its own `(+)`/`(x)` icons. Direct mode auto-seeds and re-seeds a blank line so there's always ≥1 row. Keyboard-only chaining: Enter on Disc% → focuses that row's `(+)` → adds a line and focuses its Product field.
23. **Tax-column width fixed** — was a `Wrap` of fixed-width boxes (a tax group name wrapped 3 lines in ~90px while space sat unused); now a `Row` with `Expanded` on desktop.
24. **Discount-approver "by {name}" label removed** from line display (data still tracked/sent, just no longer shown).
25. **Currency/rate locking** — Cash sales now force local currency regardless of the cash customer's own ledger currency; rate fields locked (not just gated) whenever `_isAgainstSource` or Cash. Header Discount % moved onto the Currency/Rate row.
26. **Product/Customer pickers migrated to the new shared `SakalAutocomplete` widget** (`lib/core/widgets/sakal_autocomplete.dart`) — adds Up/Down-arrow + Enter keyboard navigation, which Flutter's own `Autocomplete` never provided (the #1 specific complaint: "I am not able to select product from product dropdown by pressing UP and Down key").
27. **Print — "Prepared By"/"Authorised Signatory" showed the label with no name against it**, on every module's print, not just this one. Root cause was app-wide: `signatures.prepared_by`/`signatures.authorised_by` were only registered/templated for VOUCHER; every other default template rendered them as static unbound text. Fixed at the shared level (`print_field_registry.dart` + all 16 non-voucher default templates) plus this screen's own `_buildPrintDocument()` now supplies a `signatures` map (resolved from `created_by`/`approved_by` against the already-loaded `_users` list) — though this screen's own default receipt template deliberately has no signature line to bind it to (a POS receipt was never meant to carry one); the data is there regardless for a custom template. Sales Order's print (the module actually shown in the user's screenshot) got the same `_buildPrintDocument()` fix. ~10 other modules' entry screens still need the same small addition — see CLAUDE.md's print-support section.

**Meta-lesson from this whole sequence**: this pgTAP file was written in one large pass and never actually executed until this session — every one of bugs 8-16 surfaced one at a time, in file order, as each fix let execution reach further. This is exactly why CLAUDE.md's "the test-writing step itself is a real bug-finding step, not just verification" note exists (from the original Sales Invoice build) — and why "self-review found N bugs" is not the same claim as "this code runs." Treat a migration/test pair as unverified until it has actually been pasted into Supabase and run to completion at least once, no matter how much self-review preceded it. Bugs 17-18 are proof this holds even after a suite has already run several rounds and mostly passed — the LAST couple of failures are often the least obvious ones (a cross-function data-flow assumption, a test-framework API detail) rather than another copy-paste slip.

---

## 7. Cross-cutting checklist — read this before extending this screen

Per explicit user instruction (2026-07-17): this module has repeatedly needed the same categories of detail rediscovered across sessions. Before touching this screen again, re-verify all of these against the actual current file — do not rely on memory of what was intended:

1. **Barcode**: gated by `showBarcode` (`session.enableBarcode`), DIRECT mode only, `_onBarcodeSubmitted` → `_onProductSelected`. Grep `barcodeCtrl|showBarcode` in the entry screen file.
2. **Pack/Loose Qty**: gated by `showLooseQty` (`session.qtyEntryMode != 'PACK_ONLY'`), DIRECT mode only. Grep `qtyLooseCtrl|showLooseQty`.
3. **Batch/Serial mandatory allocation + negative-stock-never**: see §4's dedicated subsection above — this is the one with the most history of being missed. Grep `isBatchTracked|isSerialTracked|batchCandidates|serialCandidates`.
4. **FEFO auto-allocation**: `_autoAllocateBatchSerial`/`_onLineQtyChanged` — this screen's own addition on top of #3, not present in any other module. Grep `_autoAllocateBatchSerial`.
5. **Charges**: `rid_sales_invoice_charges`, `_charges`/`_InvoiceChargeRow`/`_buildChargesCard` — DIRECT editable, AGAINST_* server-verbatim. Grep `_charges\b|rid_sales_invoice_charges`.
6. **Discount governance**: `ric_user_sales_controls`, `discount_given_by` populated on every discounted line, supervisor-override dialog. Grep `discount_given_by|can_give_discount`.
7. **Company-flag snapshots**: `stock_dispatch_mode`/`cash_collection_mode` are captured once at save time from `ric_companies`, never re-read live afterward. Grep `_dispatchStock|_collectCash|stock_dispatch_mode`.
8. **Offline scope gaps**: charges detail and batch/serial allocations are NOT cached locally on an offline-created DRAFT — this is deliberate, not a bug, but don't "fix" it without re-reading this document's Offline support subsection first.
9. **Resume-a-DRAFT**: `_loadExisting` must reload lines, charges (`_prefillChargesFromSource`), AND batch/serial allocations (`_restoreBatchSerialAllocations`) — all three, every time this function is touched.
10. **`account_nature` on any new test fixture in this codebase**: `'General'` for GL/ledger accounts, `'Customer'`/`'Supplier'` for party accounts — never `'Income'/'Expense'/'Asset'/'Liability'` (those don't exist as values). Applies to every future test file, not just this one.

---

*Design agreed: 2026-07-16. Built, migrations run, and iterated through real execution bugs: 2026-07-16/17. pgTAP suite confirmed green and voucher-numbering split (migration 090) applied: 2026-07-18.*

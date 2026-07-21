# Sales Delivery (Against Invoice)

## Screen Requirement Document

**Module:** Sales (sixth screen — after Sales Quotation, Sales Price Master, Sales Order, Sales Invoice, Sales Return)
**Route:** `/sales/deliveries` (list), `/sales/delivery-entry` (entry)
**Status:** ✅ **Built, migrations 100–102 run against Supabase (clean), pgTAP suite passing (17/17).** Backend (3 new tables + 1 altered table + 1 view + 2 functions), full Flutter layer (data/domain/repository/providers, list + entry screens, live-stock FEFO batch/serial picker, ship-to + transport sections), routes, print support, offline SAVE (built in from day one), and a same-session offline-SAVE retrofit onto Sales Return (previously fully online-only) plus a new unified Pending Approvals screen (replacing the old Sales-Invoice-only Manager Review) are all written. Still not yet validated by `flutter analyze`/`flutter test`, no `build_runner` pass for the new Drift tables, no manual click-through. See §8 for build session notes.

This document is the single source of truth for this screen — kept up to date across sessions, same convention as `sales_invoice.md`/`sales_return.md`. Update it whenever anything below changes.

---

## 1. Screen Name

**Sales Delivery** — two screens, same shape as every other transaction module:

- **Sales Delivery — Entry/List** — pick a customer's APPROVED `DEFERRED`-dispatch invoice, dispatch some/all of its pending lines, approve.
- No separate Manager Review screen for this module alone — its offline-DRAFT backlog is handled by a new **unified "Pending Approvals" screen** shared with Sales Invoice and Sales Return (see §5, replaces the old Sales-Invoice-only Manager Review screen).

---

## 2. Screen Description

### Why this screen is needed

Sales Invoice snapshots `stock_dispatch_mode` (`IMMEDIATE`/`DEFERRED`) at save time from the company-level `quick_invoice_dispatch_stock` flag. When `DEFERRED`, `fn_approve_sales_invoice` never touches stock or posts a COS voucher — both `sales_invoice.md` (lines 124/199/203) and `rid_sales_order_lines.delivered_qty`'s own doc comment flag this explicitly as a known, intentional gap: *"a future Sales Delivery screen would consume any invoice left with stock_dispatch_mode='DEFERRED' — not built in this pass."* This screen is that consumer. It also lets a warehouse manually (re)dispatch stock any time an invoice's automatic dispatch didn't happen — company setting off, or a technical failure at invoice time.

### Where it sits in the ERP

```
Sales Invoice (APPROVED, stock_dispatch_mode='DEFERRED') ──(Delivery, one or more times)──▶ Sales Delivery ──▶ Stock + COS (no financial/GL customer impact — that already happened at invoice time)
```

### Decisions confirmed live (this session)

1. **Non-financial document, structurally, not just by UI convention.** No `rate`/`tax`/`amount` column exists anywhere on `rid_sales_delivery_lines` or `rih_sales_delivery_headers` — a Delivery can never accidentally expose pricing, because there's nowhere for it to live. The only monetary impact posted is a COS (Cost of Sales) voucher, and even that has no customer-facing leg — it's a pure internal Stock↔COGS journal entry, same shape Sales Invoice's own IMMEDIATE-mode dispatch already posts.
2. **One delivery references exactly ONE invoice** (mirrors Sales Return's own single-invoice design) — but **that same invoice can be the source of many separate Sales Delivery documents over time**, each dispatching some remaining portion, until every line is fully delivered. Enforced via a cumulative-qty cap check at Approve time, same mechanism as Sales Return's `v_already_returned` pattern, adapted to a denormalized `delivered_qty` counter (see §5 for why this diverges from Sales Return's live-`SUM()` approach).
3. **Concurrency-safe by construction.** If User A drafts a delivery and User B independently approves a different delivery against the same invoice first, User A's stale draft is re-validated fresh against the invoice's now-current pending quantity at the moment THEY approve — never against what was true when they opened the screen. Mechanism: locking the source invoice header row (`FOR UPDATE`) inside `fn_approve_sales_delivery` serializes every concurrent approval attempt against that invoice, exactly Sales Return's own proven mechanism (migration 099, pgTAP tests 11/12).
4. **Offline-first, properly scoped.** SAVE (DRAFT creation) works offline, queued via the existing `SyncEngine`, mirroring Sales Invoice's DIRECT-mode pattern — built in from day one, not retrofitted. APPROVE is always online-only, non-negotiably: it posts real stock/GL under a row-lock only the live database connection can serialize across devices, and this system never silently un-posts an approved entry. A synced-but-unapproved Delivery DRAFT is picked up by the new unified Pending Approvals screen (§5), same as Sales Invoice's own offline Direct-mode drafts are today. This same offline-Save/online-Approve split was retrofitted onto Sales Return in this same session (previously fully online-only) — see `sales_return.md` for that change.
5. **DRAFT / APPROVED only, no CANCELLED** — same Immutability precedent as Sales Return/Purchase Return. Once approved, a delivery is as immutable as everything else in this schema.
6. **Batch/serial candidates come from LIVE stock, not from the source invoice.** A `DEFERRED` invoice never stages `rid_transaction_line_batches`/`rid_transaction_line_serials` rows at all (`fn_save_sales_invoice`'s staging logic is skipped entirely when dispatch is deferred) — so unlike Sales Return (which scopes candidates to exactly what the source invoice line sold), Sales Delivery has no source-document allocation to inherit. It picks fresh against `v_batch_stock_balance`/`v_serial_stock_status`, FEFO-auto-allocated, exactly the same call Sales Invoice's own DIRECT-mode dispatch already uses.
7. **New master + new generic table, both reusable beyond this module** (raised during planning, approved): a **Customer Delivery Location** master (this schema had zero equivalent — Sales Order's `ship_to`/`bill_to` are bare free-text columns) snapshotted onto each delivery for historical accuracy, and a **generic Transport Details table** (vehicle/transporter/driver), keyed the same `source_doc_type`/`source_doc_no`/`source_doc_date` way as `rid_transaction_line_batches`, so a future GRN/Stock Transfer module gets the same capability for free.
8. **Sales Invoice gains a read-only delivery-status badge** (Pending/Partially Delivered/Delivered), sourced from a new view — no new invoice column, no change to `fn_save_sales_invoice`/`fn_approve_sales_invoice`.

---

## 3. Screen Layout

### 3.1 List Screen

`SakalAdaptiveList` — Delivery No, Date, Invoice No (source), Customer, Location, Status (`DRAFT`/`APPROVED` chip), Received By, "Pending sync" badge (offline-queued not-yet-synced rows). Filters: Location, Status, Date range. `+ New Delivery` opens the pending-invoice picker directly.

### 3.2 Entry Screen

```
┌──────────────────────────────────────────────────────────────────────┐
│  Sales Delivery                                    [Save] [Approve]  │
│  SDEL/KIN/2026/00001                                        [Print]  │
├──────────────────────────────────────────────────────────────────────┤
│  Invoice: INV/KIN/2026/00042 · 2026-07-10 · Credit       [Change]    │
│  Customer: [code] name  (read-only, from invoice)                    │
│  Dispatch Location: Kinshasa Main  (read-only text, from invoice)    │
│  Delivery Date: [____]   Received By: [__________________] (free)   │
├──────────────────────────────────────────────────────────────────────┤
│  Lines (pre-filled from invoice, remaining-pending qty as default)   │
│  # | Product | Barcode | UOM | Pending Qty | Delivery Qty | [remove] │
│    ↳ Batch/Serial — FEFO auto-allocated from LIVE stock, editable,   │
│      Batch No / Manufacturing Date / Expiry Date all shown           │
│      [Reset to FEFO]                                                 │
├──────────────────────────────────────────────────────────────────────┤
│  Ship To: [saved location ▾] or type ad-hoc          [+ New Location]│
│  Address: [___________________]  City: [____]                        │
├──────────────────────────────────────────────────────────────────────┤
│  Transport Details (optional, collapsible)                           │
│  Vehicle No: [___]  Transporter: [___]  Driver: [___]  Phone: [___]  │
├──────────────────────────────────────────────────────────────────────┤
│  Remarks: [_______________________________________] (optional)      │
└──────────────────────────────────────────────────────────────────────┘
```
**No financial figures anywhere on this screen** — not gated, structurally absent (§2 decision 1).

- Header buttons top-right (standard convention); mobile stacks below.
- Invoice picker (`+ New Delivery`) queries `v_sales_invoice_delivery_status` filtered to `delivery_status IN ('PENDING','PARTIALLY_DELIVERED')` — columns Invoice No, Date, Customer Name, Location, Pending Qty. Selecting one loads customer/location (read-only, inherited — nothing left to choose, same rule Sales Invoice's own AGAINST_* modes established) and every line with its remaining-pending qty (`base_qty - delivered_qty`) as the suggested default.
- Zero-qty lines cannot be saved — button disabled / line auto-removed client-side; backend also rejects as defense-in-depth (`fn_save_sales_delivery`).
- Delivery Date: no future dates (client + server enforced), and must not be before the invoice's own date (server enforced, `DELIVERY_DATE_BEFORE_INVOICE_DATE`).
- Ship To section: autocomplete of the customer's saved `rim_customer_delivery_locations` rows (default pre-selected if one exists), copies into editable snapshot fields on the delivery header; user may also type an ad-hoc address not saved to master. A "+ New Location" shortcut lets the user save the current entry back to the customer's master list without leaving this screen.
- Save/Approve are two separate actions (unlike Sales Invoice's "Save is Approve" UX) — a delivery can be genuinely staged as DRAFT and approved later by anyone, matching Sales Return's own resolved open question (keep the two-function shape, allow a real DRAFT stage).

---

## 4. Screen Functionality

### Header fields

| Field | Behavior |
|---|---|
| Delivery No | Auto-assigned on save, format `SDEL/{LOC}/{YYYY}/{SEQ5}` (`fn_next_trans_no`, voucher type `SDEL`, numbering only). |
| Delivery Date | Defaults to today. Hard future-date block (unconditional, not company-configurable — req from planning) + `fn_check_period_open`/`fn_check_backdate_allowed('SALES_DELIVERY', ...)` + must be `>= invoice_date`. |
| Invoice No/Date | Picked once at creation, read-only after. |
| Customer / Location | Inherited from invoice, read-only, never client-trusted server-side either. |
| Received By | Free text, printed on the delivery slip, distinct from the internal `authorised_by` approver signature. |
| Ship To | Snapshot fields (`ship_to_location_name`/`address_line1/2`/`city_id`/`contact_person`/`contact_phone`), optionally provenance-linked to `rim_customer_delivery_locations.id` via `ship_to_location_id` (nullable, traceability only — never re-read live). |

### Line behavior

- Suggested Delivery Qty per line = invoice line's `base_qty` − that line's own `delivered_qty` (denormalized counter, §5). Computed client-side for display, **re-validated authoritatively server-side at Approve** against the same column, freshly read under the invoice row lock — same "picker is UX only, the locked check is authoritative" precedent as every prior module.
- Batch/serial-tracked lines: candidates from **live stock** (`v_batch_stock_balance`/`v_serial_stock_status`, same calls Sales Invoice's own DIRECT-mode dispatch uses) — FEFO auto-allocated on load and on qty change (earliest-`expiry_date`-first via the view's own sort, greedy-fill, capped per candidate at its available balance), fully user-editable, "Reset to FEFO" re-triggers. Mandatory allocation whenever delivery qty > 0 on a tracked line (same strictness as every consolidation-shaped module in this schema).
- Barcode: carried forward read-only from the source invoice line's own `rid_sales_invoice_lines.barcode` — no scan UI on this screen (consolidation-document convention).
- No charges, no tax, no rate — structurally absent (§2 decision 1).

### GL/Stock Posting Design (`fn_approve_sales_delivery`)

Single voucher per approval, tagged `source_doc_type='SALES_DELIVERY'`/`source_doc_no=delivery_no` (Posted Journal Entries section finds it for free, same convention as every other module):

**`COS` (Cost of Sales) voucher — always posted (unlike Sales Return, where COS is conditional on the source invoice having dispatched stock; here dispatch is the entire point of the document):**

- Unit cost is the **CURRENT** `rim_product_location.cost_price` at delivery-approval time, read `FOR UPDATE` — **not** historical, unlike Sales Return's reversal (which must symmetrically match what the original invoice posted). This is a fresh outward movement, same as Sales Invoice's own IMMEDIATE-mode dispatch; there is no prior movement to stay symmetric with.
- Per line: **DR `COST_OF_SALES_ACCOUNT`** / **CR `STOCK_ACCOUNT`**, both resolved via `fn_resolve_account_link` (already-existing link types, no new ones needed), base currency, self-referential party (purely internal voucher, same convention as every prior COS/MIC-style entry). Tagged `source_line_type='COGS'`/`'STOCK'`, `source_line_no=<delivery line serial_no>` — full bidirectional traceability from delivery line → finance line → stock ledger row, satisfying the "clear relation for future amendment" requirement from planning.
- Stock: `fn_post_stock_movement(..., 'SALES_DELIVERY', -qty, ...)` — **negative** qty_change (outward), batch/serial loop mirrors Sales Invoice's own dispatch loop exactly. Negative-stock enforcement (item+location `allow_negative_stock` AND for untracked products, unconditional block for batch/serial-tracked) is inherited free, zero new logic.
- `SALES_DELIVERY` is a **new, distinct** `ril_stock_ledger.trans_type` (both CHECK constraints updated, same two-constraint pattern as Material Issue's own retrofit, migrations 069/070) — kept separate from `SALES_INVOICE` so stock-ledger reporting can tell "dispatched at invoice time" apart from "dispatched later via Delivery."
- Posted via `fn_post_voucher(..., 'COS', p_delivery_date, v_cos_lines, 'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by)` — reuses the existing `COS` voucher type as-is, no new posting code.

### Approve-time validation

1. `fn_check_period_open` / `fn_check_backdate_allowed('SALES_DELIVERY', ...)` **plus an unconditional hard future-date guard** (`p_delivery_date > CURRENT_DATE` → `FUTURE_DATE_NOT_ALLOWED`, not a company-configurable opt-in — Material Issue's belt-and-suspenders pattern, not Sales Return's config-only check).
2. Source invoice must be `status='APPROVED'` AND `stock_dispatch_mode='DEFERRED'`, locked `FOR UPDATE` — this lock is what serializes concurrent Delivery approvals against the same invoice (§2 decision 3).
3. Per line: `invoice_line.delivered_qty + this_delivery_qty <= invoice_line.base_qty`, else `DELIVERY_QTY_EXCEEDS_PENDING`.
4. Batch/serial-tracked lines: mandatory allocation, strict flag-independent balance check — inherited from `fn_post_stock_movement`.
5. `delivery_date >= invoice_date` — also checked at Save time for fast feedback, re-checked at Approve as defense-in-depth.

---

## 5. Data Flow / Backend Objects

**New `rim_voucher_types` row:** `SDEL` (Sales Delivery, numbering only). `COS` is reused as-is, no new posting code.

**New `ril_stock_ledger` CHECK constraint value:** `'SALES_DELIVERY'` added to both the column whitelist and `chk_stock_ledger_direction`'s outward group.

**New tables:**
- `rim_customer_delivery_locations` (migration 100) — `id, client_id, company_id, customer_id, location_name, address_line1, address_line2, city_id, contact_person, contact_phone, is_default, is_active, is_deleted, audit columns`. Partial unique index: at most one `is_default=true` per customer.
- `rid_transport_details` (migration 101, generic) — `id, client_id, company_id, source_doc_type, source_doc_no, source_doc_date, vehicle_no, transporter_name, driver_name, driver_phone, remarks, audit columns`. `UNIQUE (client_id, company_id, source_doc_type, source_doc_no, source_doc_date)`.
- `rih_sales_delivery_headers` (migration 102) — `id, client_id, company_id, location_id, delivery_no, delivery_date, invoice_no, invoice_date, customer_id, ship_to_location_id (nullable, provenance), ship_to_location_name, ship_to_address_line1/2, ship_to_city_id, ship_to_contact_person/phone, received_by_name, reason, remarks, status (DRAFT/APPROVED), approved_by, approved_at, cos_voucher_no/date, is_deleted, audit columns`. `UNIQUE (client_id, company_id, delivery_no, delivery_date)`. No financial columns at all.
- `rid_sales_delivery_lines` (migration 102) — `id, client_id, company_id, delivery_no, delivery_date, serial_no, invoice_line_serial, product_id, barcode, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty (DELIVERY qty), is_deleted, audit columns`. No `rate`/`tax_group_id`/`gross_amount`/`final_amount` — structurally non-financial.
- **No new batch/serial tables** — reuses `rid_transaction_line_batches`/`rid_transaction_line_serials` with `source_doc_type='SALES_DELIVERY'`.

**Altered existing table:** `rid_sales_invoice_lines` gains `delivered_qty NUMERIC(18,4) NOT NULL DEFAULT 0` (migration 102) — mirrors the already-existing, previously-unwired `rid_sales_order_lines.delivered_qty` naming precedent. **Design choice**: a denormalized running counter (incremented under the invoice-row lock at Approve time), not a live `SUM()` like Sales Return's `v_already_returned` — chosen because the Delivery picker modal needs a fast "which invoices still have pending qty" query across many invoices, which a live per-check SUM doesn't serve well through PostgREST. Safe specifically because the increment happens inside the same locked transaction that validates the cap.

**New view:** `v_sales_invoice_delivery_status` — per-invoice rollup (`total_qty`, `delivered_qty`, `pending_qty`, `delivery_status` ENUM-like text `PENDING`/`PARTIALLY_DELIVERED`/`DELIVERED`), filtered to `stock_dispatch_mode='DEFERRED' AND status='APPROVED'`. Serves both the Delivery picker and the Sales Invoice screens' new status badge.

**New functions:**
- `fn_save_sales_delivery(p_header JSONB, p_lines JSONB, p_batches JSONB, p_serials JSONB, p_transport JSONB, p_user_id UUID) RETURNS TEXT` — DRAFT-only, same shape as `fn_save_sales_return`, plus the optional transport upsert.
- `fn_approve_sales_delivery(p_client_id, p_company_id, p_delivery_no, p_delivery_date, p_approved_by UUID) RETURNS VOID` — single-voucher (COS-only) orchestration described in §4.

**Existing functions reused unchanged:** `fn_post_voucher`, `fn_post_stock_movement` (outward call, current-cost — no historical-cost complexity, unlike Sales Return), `fn_resolve_account_link`, `fn_next_trans_no`, `fn_check_period_open`, `fn_check_backdate_allowed`.

**Downstream — what consumes this screen's output:** the new unified Pending Approvals screen (offline-queued DRAFT backlog), the new Sales Invoice delivery-status badge, and (future, not built) a Delivery Amendment feature — enabled by the `source_line_type`/`source_line_no` traceability tagging described in §4, deliberately built in now even though nothing consumes it yet.

**What is NOT in this screen (scope exclusions):** no financial figures anywhere (structural, §2); no CANCELLED status/reversal path (Immutability principle — a mistaken delivery has no clean "un-deliver," same limitation Sales Return already carries for its own APPROVED documents); no multi-invoice-per-delivery (one invoice per delivery, by design, matching Sales Return's own simplification); no batch/serial line-level printing (inherited, already-documented app-wide gap, see CLAUDE.md Manufacturing Date section); no Delivery Run / multi-vehicle-trip consolidation (flagged as a future v2 of the generic Transport Details table, not built here).

---

## 6. Open Questions / Known Gaps

1. **Offline batch/serial allocation is not cached locally** — an offline-created Delivery DRAFT loses its batch/serial picks on reopen while still offline (same documented limitation Sales Invoice/Sales Return already accept for their own offline paths). Re-allocation is needed on reopen; acceptable trade-off to keep the retrofit small.
2. **Transport Details are not cached locally either** — optional field, low-risk to lose on reopen-while-offline; user can re-enter.
3. **`v_sales_invoice_delivery_status`'s `delivered_qty` counter vs. Sales Return's live-`SUM()` pattern** — a deliberate, stated divergence (§5); flagged here so a future reviewer doesn't assume it's an oversight relative to Sales Return's own approach.

---

## 7. Build Checklist (Definition of Complete)

1. **Permissions** — `ScreenPermissionMixin`, `screenName = RouteNames.salesDeliveries` on both list and entry screens.
2. **Security** — `auth_rw_<table>` RLS policy on all new tables (`rim_customer_delivery_locations`, `rid_transport_details`, `rih_sales_delivery_headers`, `rid_sales_delivery_lines`), `REVOKE ALL FROM anon`, `GRANT` to `authenticated` only.
3. **Responsiveness** — `SakalAdaptiveList` on list screen; `SakalFieldCard`/`SakalFieldRow`/`SakalLineItemCard` on entry screen from the start.
4. **Offline support** — Save works offline (SyncEngine queue, Drift cache, schema v23), Approve is online-only, deferred to the unified Pending Approvals screen.
5. **Print support** — `print_field_registry.dart`'s 4 switches + `documentTypes` list, `sales_delivery_default_template.dart`, `print_template_provider.dart`, `print_sample_data.dart`, entry screen's `_buildPrintDocument`/`_printDelivery`/`_buildPrintButton`. `signatures` map resolved from real `created_by`/`approved_by` user names (follow Sales Invoice's correct pattern, not Material Issue's known-broken silent-blank one).
6. **Company-configurable line fields** — `showLooseQty` gating wired through the line card; barcode carries forward read-only (consolidation-document convention, no scan UI needed).
7. Run the **MANDATORY pre-completion self-check** from CLAUDE.md before declaring this screen done.

---

## 8. Build Session Notes (2026-07-21)

**Full build in one session**, per the plan approved the same day (`C:\Users\manglu.singh\.claude\plans\act-as-a-senior-cheerful-hickey.md`). Scope grew beyond the original 19 requirements during planning review — Customer Delivery Location master, generic Transport Details table, Sales Invoice delivery-status badge, and a full offline-first pass (Sales Return retrofit + Sales Delivery from day one + unified Pending Approvals screen) — all approved before building began; see the plan file's own "Deferred / Follow-Up Work Register" for what was deliberately left out (Sales Executive Master is next, immediately after this).

**Backend** — migrations 100/101/102:
- `rim_customer_delivery_locations` (100), `rid_transport_details` (101, generic — reusable by a future GRN/Transfer module via a new `source_doc_type` tag).
- `rih_sales_delivery_headers`/`rid_sales_delivery_lines` (102) — structurally non-financial, no rate/tax/amount column anywhere.
- `rid_sales_invoice_lines.delivered_qty` (denormalized counter, incremented under the invoice-row lock at Approve — a deliberate divergence from Sales Return's live-`SUM()` pattern, documented in §5).
- `v_sales_invoice_delivery_status` view — pending-delivery rollup, drives both the Delivery picker and the new Sales Invoice badge.
- `SDEL` voucher type (numbering only); `COS` reused for GL posting.
- `SALES_DELIVERY` added to both `ril_stock_ledger` CHECK constraints in one migration (mirrors the two-constraint lesson from Material Issue's 069/070 retrofit, done right the first time here).
- `fn_save_sales_delivery`/`fn_approve_sales_delivery` — mirror `fn_save_sales_return`/`fn_approve_sales_return`'s shape; concurrency via locking the source invoice row, exactly Sales Return's proven mechanism.
- Menu: `SL-DEL` added (no prior placeholder existed — confirmed against `ric_master_menus` first), `SL-INR` repurposed from "Sales Invoice - Manager Review" to "Pending Approvals" (`/sales/pending-approvals`) — both in the migration's existing-company UPDATE/INSERT block AND `fn_seed_client_modules.sql` for future clients.

**Flutter** — full data/domain/repository/provider/screen layer for Sales Delivery; offline-SAVE retrofit onto Sales Return (new Drift cache tables, `schemaVersion => 23`, entry-screen offline branch + an online-only Approve guard mirroring the one built for Sales Delivery); `SyncEngine._renameLocalDocument` gained `'SALES_RETURN'` and `'SALES_DELIVERY'` cases; both list screens gained a "Pending sync" badge. Old `sales_invoice_manager_review_screen.dart` deleted outright — replaced by `sales_pending_approvals_screen.dart`, which fans out to all three repositories' `listDraftXForReview`/`getLines`/`approve` methods (a new `listDraftReturnsForReview` was added to Sales Return for this, mirroring Sales Invoice's existing one).

**Print support**: full 4-switch registry registration + default template + sample data, `received_by_name` kept as its own `header.received_by_name` scalar distinct from `signatures.authorised_by` (an internal approver is a different concept from an operator-typed recipient name).

**Simplification made explicit, not hidden**: the Customer Master's new "Delivery Locations" section does NOT capture `city_id` — that column exists on `rim_customer_delivery_locations` but the customer's own address `city_id` picker is a cascading country→division→city widget tightly coupled to that one field's state; reusing it for a repeatable sub-list was out of scope for this pass. `address_line1`/`address_line2` can carry city info textually in the meantime. Not a data-loss risk (the column is nullable) — just an unbuilt input.

**2026-07-21, later same day**: migrations 100/101/102 run against Supabase — clean, no errors. Full pgTAP suite (`102_sales_delivery_test.sql`, 17 assertions) executed — **17/17 passing**, including the concurrency-cap test (mirrors 099's own proven test 11/12 shape) and the batch-insufficient-stock negative test. Backend is now verified, not just mechanically self-consistent.

**Still not yet done**: `flutter analyze`/`flutter test` haven't run (no local Flutter/Dart toolchain this session — see `feedback_no_flutter_toolchain_verification.md`); the four new/changed Drift table files need a `dart run build_runner build` pass in Codespace to regenerate `app_database.g.dart` before anything referencing `SalesDeliveriesCacheCompanion`/`SalesReturnHeadersCacheCompanion` etc. will actually compile; no manual click-through.

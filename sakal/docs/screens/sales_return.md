# Sales Return

## Screen Requirement Document

**Module:** Sales (fifth screen — after Sales Quotation, Sales Price Master, Sales Order, Sales Invoice)
**Route:** `/sales/returns` (list), `/sales/return-entry` (entry)
**Status:** ✅ **Built, migration 099, not yet run against Supabase or validated by `flutter analyze`.** Backend (tables, `fn_save_sales_return`, `fn_approve_sales_return`), full Flutter layer (data/domain/repository/providers, list + entry screens, batch/serial candidate picker, cash refund UI), routes, and print support (registry/template/provider/sample data) are all written. pgTAP suite (`099_sales_return_test.sql`, 16 assertions) written but not yet executed. See §8 for what changed from the original plan and what's still open.

This document is the single source of truth for this screen — kept up to date across sessions, same convention as `sales_invoice.md`. Update it whenever anything below changes.

---

## 1. Screen Name

**Sales Return** — two screens, same shape as every other transaction module:

- **Sales Return — Entry/List** — pick a customer's APPROVED invoice, return some/all of its lines, approve.
- No separate "Manager Review" screen (unlike Sales Invoice) — Sales Return is always online-only (see §2), so there is no offline-DRAFT backlog needing a review step.

---

## 2. Screen Description

### Why this screen is needed

Sales Invoice's own doc and CLAUDE.md both flag this explicitly: once an invoice is `APPROVED`, its GL/stock impact is real and — per this project's Immutability principle — can never be edited or cancelled in place. Sales Return is the only way to unwind a delivered/posted invoice: goods physically come back (or a data-entry mistake needs correcting), cash may need to be refunded, and the books need a clean reversing entry, not a silent edit.

### Where it sits in the ERP

```
Sales Invoice (APPROVED) ──(Return, one or more times)──▶ Sales Return ──▶ GL + Stock (+ Cash Refund)
```

### Decisions confirmed live (this session)

1. **"Return" and "reverse" are ONE feature** — same as Purchase Return. The human reason (defective goods vs. data-entry mistake) is a free-text `reason` label only, never a different code path.
2. **One return references exactly ONE invoice** (not multi-invoice like Purchase Return's multi-GRN) — but **that same invoice can be the source of many separate Sales Return documents over time**, each returning some remaining portion, until every line is fully returned. Enforced via a cumulative-qty cap check at Approve time (identical mechanism to Purchase Return's `v_already_returned` pattern, scoped per invoice-line instead of per-GRN-line).
3. **A real cash refund IS posted** when the source invoice was a `CASH` sale that was actually collected (`cash_collection_mode='IMMEDIATE'` on that invoice) — a `CPV` (Cash Payment Voucher) settles the credit balance the return creates on the cash customer's account, mirroring Sales Invoice's own `CRV` collection logic in reverse. See §4's GL Posting Design for the full mechanics — this is the most novel part of this design and deserves a close read.
4. **Online-only, no offline support (v1)** — same reasoning as Sales Invoice's own AGAINST_QUOTATION/AGAINST_ORDER modes: approving a return needs a live, authoritative "how much of this invoice line has already been returned" check (cross-device), which an offline replica cannot safely guarantee. Unlike Sales Invoice, there is no Direct/no-source-document mode here to fall back to offline for — every return has a source invoice by definition.
5. **DRAFT / APPROVED only, no CANCELLED** — same as Purchase Return. Once approved, a return is as immutable as the invoice it reverses; a mistaken return has no clean "un-return" path in v1 (flagged as a known limitation, not a gap to silently paper over).

---

## 3. Screen Layout

### 3.1 List Screen

`SakalAdaptiveList` — Return No, Date, Invoice No (source), Customer, Status (`DRAFT`/`APPROVED` chip), Return Total, Reason. Filters: Location, Status, Date range. `+ New Return` opens the invoice picker directly (no mode choice needed — every return has exactly one path).

### 3.2 Entry Screen

```
┌──────────────────────────────────────────────────────────────────────┐
│  ← Sales Return                                    [Save & Approve]  │
│  SRET/KIN/2026/00001                                        [Print]  │
├──────────────────────────────────────────────────────────────────────┤
│  Customer: [code] name  (read-only, from invoice)                    │
│  Invoice: INV/KIN/2026/00042 · 2026-07-10 · Cash        [Change]     │
│  Return Date: [____]   Reason: [__________________] (free text)      │
├──────────────────────────────────────────────────────────────────────┤
│  Lines (pre-filled from invoice, remaining-returnable qty as default)│
│  # | Product | UOM | Invoiced Qty | Already Returned | Return Qty |  │
│    Rate🔒 | Tax | Line Total | [x remove]                            │
│    ↳ Batch/Serial to return — candidate picker, scoped to exactly    │
│      what THIS invoice line sold, minus what's already been returned │
├──────────────────────────────────────────────────────────────────────┤
│  Charges (read-only, carried forward proportionally from the invoice │
│  if it had any — same "nothing left to choose" rule as Sales         │
│  Invoice's AGAINST_* modes)                                          │
├──────────────────────────────────────────────────────────────────────┤
│  Remarks: [_______________________________________] (optional)      │
├──────────────────────────────────────────────────────────────────────┤
│  Taxable:  Tax:  Charges:  RETURN TOTAL                              │
│  Refund (shown only if this invoice was CASH + collected):  N        │
└──────────────────────────────────────────────────────────────────────┘
```

- Header buttons top-right (standard convention); mobile stacks below; in-content back arrow next to title (standard convention).
- Invoice picker (`+ New Return`) filters to `status='APPROVED'` invoices with at least one line not yet fully returned. Selecting one loads the customer (read-only), sale type, currency/rate (all inherited, read-only — nothing left to choose, same rule as Sales Invoice's own AGAINST\_\* modes), and every line with its remaining-returnable qty as the suggested default.
- Each line shows Invoiced Qty and Already Returned (both read-only, computed) alongside the editable Return Qty — critical so the user can see at a glance what's left, especially on a repeat return against the same invoice.
- Rate/tax group/UOM are all inherited read-only from the invoice line — never re-entered or re-picked.
- "Save & Approve" is a single action, same auto-approve UX convention as Sales Invoice ("Save" _is_ approve) — there's no meaningful DRAFT state for a return that needs separate manager sign-off, and per §2 decision 4, this screen is online-only anyway so there's no offline-DRAFT-then-review need. (Open question for review: should DRAFT literally still exist as a save-without-posting option for a user who wants to prepare a return and approve it later? Recommend **yes**, keep the two-function `fn_save_sales_return`/`fn_approve_sales_return` shape identical to every other module for consistency, even though the UI defaults to chaining them like Sales Invoice does.)

---

## 4. Screen Functionality

### Header fields

| Field                 | Behavior                                                                                                                                                                                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Return No             | Auto-assigned on save, format `SRET/{LOC}/{YYYY}/{SEQ5}` (`fn_next_trans_no`, voucher type `SRET`).                                                                                                                  |
| Return Date           | Defaults to today. Subject to `fn_check_period_open`/`fn_check_backdate_allowed('SALES_RETURN', ...)` at Approve — `SALES_RETURN` is already a recognized transaction type in `backdated_entry_control_screen.dart`. |
| Invoice No/Date       | Picked once at creation, read-only after.                                                                                                                                                                            |
| Customer              | Inherited from invoice, read-only.                                                                                                                                                                                   |
| Return Currency/Rates | Inherited from invoice (`invoice_currency_id`/`rate_to_base`/`rate_to_local`), read-only.                                                                                                                            |
| Reason                | Free text, audit label only — never branches logic (per decision 1).                                                                                                                                                 |

### Line behavior

- Suggested Return Qty per line = `invoice line's base_qty` − `SUM(base_qty) across every prior APPROVED Sales Return line referencing this same invoice_no + source line serial)`. Computed for display client-side (a plain fetch), **re-validated authoritatively server-side at Approve** — same "picker is UX only, the row-locked/summed check is authoritative" precedent as every prior module.
- Batch/serial-tracked lines: candidate picker sourced from `rid_transaction_line_batches`/`rid_transaction_line_serials` WHERE `source_doc_type='SALES_INVOICE' AND source_doc_no=<invoice_no> AND source_doc_date=<invoice_date> AND line_serial=<that invoice line's serial>` — i.e., exactly what this specific invoice line sold — **minus** whatever batch qty / serial has already been consumed by a prior APPROVED Sales Return against the same invoice line. Mandatory allocation whenever return qty > 0 on a tracked line (same strictness as Purchase Return, stricter than GRN's own free-text entry) — a batch or serial is a specific identifiable unit, `allow_negative_stock` never applies.
- Barcode: this is a **consolidation document** in the established sense (lines copied from a prior document, no independent product-selection step) — each return line's `barcode` is carried forward from the source invoice line's own saved `barcode` column (`rid_sales_invoice_lines.barcode`), never freshly scanned. No `showBarcode`/company-flag gating needed (same reasoning as Purchase Return ← GRN, Material Issue ← Requisition): there's no scan UI to gate, just a value threaded through `fn_save_sales_return`'s line payload. The source invoice line's own `getLines`-equivalent read must actually select `barcode`, or there's nothing to carry (same "resume/consolidation must select what it carries forward" rule as every prior barcode retrofit).
- Charges: if the source invoice had `rid_sales_invoice_charges`, this return carries them forward **proportionally** (return line value ÷ invoice line value, same apportionment idiom used everywhere else in this schema) as **read-only** defaults — never freely re-edited, matching the "nothing left to legitimately choose" rule Sales Invoice itself established for AGAINST_QUOTATION/AGAINST_ORDER.

### GL Posting Design (`fn_approve_sales_return`)

Mirrors Purchase Return's structure but is simpler in one respect (Sales Invoice always fully posts GL at Approve — there is no GRN-style "provisional vs. billed" split to branch on) and adds one genuinely new piece (the cash refund). Three possible vouchers per approval, all tagged `source_doc_type='SALES_RETURN'`/`source_doc_no=return_no` so the Posted Journal Entries section finds all of them for free:

**1. `CRN` (Credit Note) voucher — always posted, one per return:**

- Per-line: **DR `SALES_RETURNS_ACCOUNT`** (new contra-revenue account-link type, mirrors `PURCHASE_RETURNS_ACCOUNT`'s precedent — deliberately NOT the plain `SALES_ACCOUNT`, so Gross Sales and Sales Returns report as separate P&L lines, standard practice) for the line's taxable value, resolved via `fn_resolve_account_link(..., 'SALES_RETURNS_ACCOUNT')` per product (same per-product resolution as every other line-level account link).
- Per-tax: **DR** the same `gl_output_account_id` the original tax posted to, weighted the same rate-apportionment way `fn_approve_sales_invoice` already does.
- Per-charge (if any carried forward): reversed direction from the original (`ADD` reversed → DR; `DEDUCT` reversed → CR), same charge's own `gl_account_id`, plus its tax leg reversed the same way.
- **CR Customer** — one aggregate line for the whole return, tagged `inv_bill_no=<this CRN voucher's own trans_no>` (self-reference, corrected post-hoc via the same `UPDATE rid_finance_lines` trick `fn_approve_sales_invoice` uses, since the real `trans_no` isn't known until `fn_post_voucher` returns) — this is what makes the return refund-settleable via the existing pending-bills/Against-Bill mechanism, for free.
- Posted via `fn_post_voucher(..., 'CRN', ...)` — a new `voucher_type_code` needed (`rim_voucher_types` insert, nature `SALES`).

**2. `COS` (Cost of Sales) voucher — posted only if the source invoice actually dispatched stock for the returned line(s):**

- Only runs when the source invoice's `stock_dispatch_mode='IMMEDIATE'` (check `rih_sales_invoices.stock_dispatch_mode` via the locked source-invoice row) — if it was `DEFERRED`, no stock ever left and there's nothing to reverse; the return is GL-only (Credit Note voucher alone).
- **Unit cost is the ORIGINAL invoice's own historical per-unit COGS, never a fresh current-average lookup.** Looked up from that invoice's own already-posted `COS` voucher: `rid_finance_lines WHERE source_doc_type='SALES_INVOICE' AND source_doc_no=<invoice_no> AND source_line_type='STOCK' AND source_line_no=<that line's serial>` → that row's `base_amount` ÷ the invoice line's own `base_qty` = original unit cost. This is what keeps the return's Stock-DR and COGS-CR symmetric with what was originally reversed — using a fresh current average would break that symmetry (moving average may have drifted since the sale) and is the one genuinely novel wrinkle in this whole design (no prior module has needed to post an INWARD movement at a caller-supplied _historical_ cost before; every prior `+` movement, e.g. Stock Adjustment, uses the _current_ average deliberately).
- Per returned unit: **DR `STOCK_ACCOUNT`** / **CR `COST_OF_SALES_ACCOUNT`** (exact reverse of the invoice's own DR COGS/CR Stock), same accounts resolved via `fn_resolve_account_link`, at the historical unit cost above.
- Stock: `fn_post_stock_movement(..., 'SALES_RETURN', +qty, p_unit_cost_base=<historical cost>, p_unit_cost_specific=..., p_batch_no/p_serial_no=..., ...)` — **positive** qty_change (inward). `SALES_RETURN` is already a valid `trans_type` in both `ril_stock_ledger` CHECK constraints (036/069/070) and already classified as an inward type in `chk_stock_ledger_direction` — no new stock-engine migration needed. Batch/serial loop mirrors the invoice's own dispatch loop (one call per batch row / one call per serial), same `v_has_batches`/`v_has_serials` branch pattern as `fn_approve_sales_invoice`.
- Posted via `fn_post_voucher(..., 'COS', ...)` — **reuses** the existing `COS` voucher type code (no new type needed); `source_doc_type='SALES_RETURN'` already disambiguates a return's COS entries from an invoice's own in any report/filter.

**3. `CPV` (Cash Payment Voucher) — the refund, posted only when the source invoice was CASH + actually collected:**

- Condition: source invoice `sale_type='CASH'` AND `cash_collection_mode='IMMEDIATE'` AND (`collected_amount_local`/`collected_amount_base` > 0).
- **Refund pool, capped cumulative per invoice** (mirrors the qty-cap pattern exactly, applied to cash instead of quantity): `remaining_refundable = original collected_amount_{local,base} − SUM(already refunded on prior APPROVED Sales Returns against this same invoice)`. This return's own refund request (its `return_total`, converted into local/base using the SAME proportional local/base split the ORIGINAL collection used) is capped against that remaining pool per currency leg — never over-refunds beyond what was actually collected.
- Posted via `fn_save_finance_voucher` + `fn_post_finance_voucher` **directly** (never `fn_post_voucher`, which hardcodes `is_on_account=true`) — same reasoning Sales Invoice's own `CRV` collection uses. **DR Customer** (clears the credit balance the CRN voucher created) / **CR Cash account** (local and/or base, from `fn_quick_cash_account_local`/`fn_quick_cash_account_base`, keyed off **this return's own `created_by`** — whoever is physically at the till processing the refund right now, not necessarily the original invoice's cashier). Customer leg tagged `inv_bill_no=<the CRN voucher's own trans_no>`, `is_on_account=false` — settles directly against the CRN's own bill, exact mirror of how Sales Invoice's `CRV` settles against its own `SLS` bill.
- A cashier processing the return with no `ric_user_quick_invoice_setup` row is a clear `QUICK_INVOICE_NOT_CONFIGURED` error (same precedent as Sales Invoice's own collection-account resolution), not a silent skip.
- If the source invoice was CREDIT (or CASH but never actually collected), **no refund voucher posts** — the CRN's own Customer CR line simply reduces whatever the customer still owes, which is correct and needs no further settlement action from this function.

### Approve-time validation (mirrors Purchase Return's own checklist)

1. `fn_check_period_open` / `fn_check_backdate_allowed('SALES_RETURN', ...)` — first, before anything else.
2. Source invoice must be `status='APPROVED'` (never DRAFT/CANCELLED), locked `FOR UPDATE`.
3. Per line: `already_returned + this_return_qty <= invoice_line.base_qty`, else `RETURN_QTY_EXCEEDS_INVOICED`.
4. Batch/serial-tracked lines: mandatory allocation, strict (flag-independent) balance check — same as Purchase Return.
5. Refund cap check per currency leg (§ above) — never raises an error on its own, just clamps; but if the user's confirmed refund amount on the header exceeds the computed cap, that IS a hard error (`REFUND_EXCEEDS_COLLECTED`), not a silent clamp, so the user isn't surprised by a smaller-than-expected refund actually posting.

---

## 5. Data Flow / Backend Objects (planned — migration 099)

**New `rim_voucher_types` rows:** `SRET` (Sales Return, numbering only — mirrors `PRET`), `CRN` (Credit Note, nature `SALES` — mirrors `SDN`). `COS`/`CPV` are reused as-is, no new type.

**New `rim_account_link_types` row:** `SALES_RETURNS_ACCOUNT` (mirrors `PURCHASE_RETURNS_ACCOUNT`, migration 061's precedent).

**New tables:**

- `rih_sales_return_headers` — `id, client_id, company_id, location_id, return_no, return_date, invoice_no, invoice_date, customer_id, return_currency_id, rate_to_base, rate_to_local, taxable_amount, tax_amount, charges_amount, return_total, refund_amount_local, refund_amount_base, reason, remarks, status (DRAFT/APPROVED), approved_by, approved_at, credit_note_voucher_no/date (CRN), cos_voucher_no/date, refund_voucher_no/date, is_deleted, audit columns`. `UNIQUE (client_id, company_id, return_no, return_date)`. FK-style soft link to invoice via `(client_id, company_id, invoice_no, invoice_date)` (not a hard FK across tables with composite keys — same convention as GRN→PO, Purchase Bill→GRN).
- `rid_sales_return_lines` — `id, client_id, company_id, return_no, return_date, serial_no, invoice_line_serial, product_id, barcode, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty (RETURN qty), rate, tax_group_id, gross_amount, tax_amount, final_amount, charge_amount, landed_amount, is_deleted, audit columns`. `UNIQUE (client_id, company_id, return_no, return_date, serial_no)`, header FK same composite-key pattern as every other line table. **Naming note**: no `source_` prefix anywhere — the header already stores the one-and-only `invoice_no`/`invoice_date` this return is against, so the line only needs `invoice_line_serial` (which line of that invoice this row corresponds to), never a repeated `source_invoice_no`/`source_invoice_date` per line. Keep this plain naming in the actual migration too — don't reintroduce a `source_` prefix by copying Purchase Return's `source_grn_no`/`source_grn_line_serial` column names verbatim (those exist there because Purchase Return can reference MULTIPLE GRNs per return; Sales Return can't, so the prefix would be misleading dead convention).
- `rid_sales_return_charges` — mirrors `rid_purchase_return_charge_lines`'s shape (pulled-forward-as-default, proportionally apportioned, same `gl_account_id`/`nature`/`tax_id` columns as `rid_sales_invoice_charges`).
- **No new batch/serial tables** — reuses `rid_transaction_line_batches`/`rid_transaction_line_serials` with `source_doc_type='SALES_RETURN'`, same as every prior module.

**New view:** `v_sales_return_links` — "which invoice has this return touched," mirrors `v_grn_return_links` exactly (`DISTINCT client_id, company_id, return_no, return_date, invoice_no, invoice_date` off the header, since it's 1:1 not many:many, this view may be unnecessary — **open question**: probably simpler to just query `rih_sales_return_headers` directly by `invoice_no`/`invoice_date` for the "already returned" sums, no view needed at all given the 1-invoice-per-return simplification. Recommend dropping this view from the plan unless a concrete UI need emerges.)

**New functions:**

- `fn_save_sales_return(p_header JSONB, p_lines JSONB, p_batches JSONB, p_serials JSONB, p_charges JSONB, p_user_id UUID) RETURNS TEXT` — DRAFT-only, same shape as `fn_save_purchase_return` (batch/serial included from day one per the param list, unlike Purchase Return's follow-up-migration history — Material Issue/Stock Adjustment's precedent of "build it in from day one" applies here since the design is already known upfront).
- `fn_approve_sales_return(p_client_id, p_company_id, p_return_no, p_return_date, p_approved_by UUID) RETURNS VOID` — the three-voucher orchestration described in §4.

**Existing functions reused unchanged:** `fn_post_voucher`, `fn_post_stock_movement` (inward call, new for this module — first inward caller supplying a historical rather than current cost), `fn_resolve_account_link`, `fn_get_exchange_rate`, `fn_get_active_tax_rate`, `fn_next_trans_no`, `fn_check_period_open`, `fn_check_backdate_allowed`, `fn_save_finance_voucher`, `fn_post_finance_voucher`, `fn_quick_cash_account_local`/`fn_quick_cash_account_base`.

---

## 6. Open Questions For Review (before implementation starts)

1. **Refund proportional-split mechanics** (§4, voucher 3) is the most novel and intricate piece of this design — worth a careful second read. Simpler v1 fallback if this feels over-built: refund the FULL return_total from whichever single cash account (local or base) the original invoice collected the LARGER amount from, capped at that account's own remaining pool, and simply don't support a split refund across both legs in v1. Flagging both options for a decision at build time.
2. **`v_sales_return_links` view** — recommend dropping it (see §5); a direct header query by `invoice_no`/`invoice_date` covers the same need with no extra schema object, since (unlike Purchase Return's many-GRNs-per-return) this is 1 invoice per return.
3. **Should DRAFT be a real, separately-savable stage**, or should the entry screen only ever call save-then-approve in one click (no visible DRAFT state at all)? Recommended: keep the two-function shape and allow a genuine DRAFT save (consistent with every module except Sales Invoice's deliberate UX deviation) — a return being prepared but not yet approved (e.g., awaiting a supervisor) is a reasonable real-world flow, unlike Quick Invoice's speed-at-the-till requirement.
4. **Serial-tracked returned units** — do they go back into stock as immediately re-sellable, or should there be a "condition" flag (e.g., damaged vs. resalable) gating whether the unit re-enters `IN_STOCK` status? Recommend **out of scope for v1** — same simplification precedent as Stock Count's "unknown serial" handling; a `condition`/quarantine-location concept would be a separate future module, not bolted onto this one.

---

## 7. Build Checklist (Definition of Complete)

1. **Permissions** — ✅ `ScreenPermissionMixin`, `screenName = RouteNames.salesReturns` on both list and entry screens (entry is not itself a menu item, matches ERP Navigation Pattern convention).
2. **Security** — ✅ `auth_rw_<table>` RLS policy on all 3 new tables, `REVOKE ALL FROM anon`, `GRANT` to `authenticated` only.
3. **Responsiveness** — ✅ `SakalAdaptiveList` on list screen; `SakalFieldCard`/`SakalFieldRow`/`SakalLineItemCard` on entry screen from the start.
4. **Offline support** — ✅ deliberately NONE for v1 (§2 decision 4) — no Drift cache, no `SyncEngine` enqueue, repository is a thin pass-through to the remote datasource (same shape as Stock Count Review's own online-only precedent).
5. **Print support** — ✅ `print_field_registry.dart`'s 4 switches + `documentTypes` list, `sales_return_default_template.dart`, `print_template_provider.dart`, `print_sample_data.dart`, entry screen's `_buildPrintDocument`/`_printReturn`/`_buildPrintButton`. `signatures` map supplied as `{prepared_by: null, authorised_by: null}` placeholders — **known gap**: not yet resolved from actual created_by/approved_by user names (would need a `_users` list fetch the screen doesn't currently load); low-risk, same fix pattern as every other module's signature wiring when picked up.
6. **Company-configurable line fields** — ✅ `showLooseQty` gating wired through `_buildLineCard`; barcode carries forward read-only from the invoice line (consolidation-document convention, no scan UI).
7. ✅ Ran the **MANDATORY pre-completion self-check** — see §8.

---

## 8. Build Session Notes (2026-07-20)

**Real bugs caught by self-review before this ever ran anywhere** (same spirit as every prior module's pre-launch review):

1. **`p_unit_cost_specific` was originally set equal to the historical base cost** — wrong; that parameter feeds `rim_product_location.cost_price_specific`'s own weighted average (a secondary reporting field, never part of the GL amounts), which has no historical equivalent to read back (the invoice's own outward movement never captured a specific-currency cost in the first place). Fixed to fetch the CURRENT `cost_price_specific` as an approximation, while keeping the base cost historical — the two fields serve genuinely different purposes and don't need to agree.
2. **`rid_finance_lines` does not have `source_doc_type`/`source_doc_no`/`source_doc_date` columns** — those live on `rih_finance_headers` only (migration 037); `rid_finance_lines` carries `source_line_type`/`source_line_no` (migration 050) plus `trans_no`/`trans_date` (migration 021, NOT the original 019 shape). The historical-cost lookup query and the Flutter `getPostedVoucherLines` datasource method both originally filtered `rid_finance_lines` directly by `source_doc_type` — fixed to a `JOIN rih_finance_headers` (SQL) / two-step header-then-lines fetch (Flutter), the same pattern `purchase_return_remote_ds.dart`'s own `getPostedVouchers`/`getPostedVoucherLines` pair already uses. **Lesson: before filtering any table by a column name recalled from memory, grep the actual `CREATE TABLE`/`ALTER TABLE` statements — a column's home table can differ from where the business logic conceptually "belongs."**
3. **Flutter's `getAlreadyReturnedByLine`/`getPriorReturnLineKeys` originally used a PostgREST embedded-resource filter (`header:table!inner(...)` + dotted-path `header.column=eq.X` params)** — a real PostgREST feature, but with **zero precedent anywhere else in this codebase** (confirmed via `grep -rn "!inner"` across `lib/`). Replaced with the codebase's actual proven pattern: a two-step lookup (fetch matching parent keys first, then filter the child table with `in.(...)`, which IS used dozens of times app-wide). **Lesson: an unverified-but-technically-valid API is still a risk when there's no toolchain to test it locally — prefer the pattern already proven elsewhere in the app over a "should work" alternative.**
4. **pgTAP test structure**: first draft put `ok()`/`is()` calls directly inside the same `DO $$ ... END $$` block as the setup/action code, referencing PL/pgSQL local variables directly. Re-reading `089_sales_invoice_test.sql` closely showed its REAL structure is multiple separate `DO $$ ... END $$` blocks (setup/action only) bridged by `PERFORM set_config('pgtap.x', ...)`, with `ok()`/`is()` calls as separate top-level statements between blocks using `current_setting('pgtap.x')` — never `ok()` inside a DO block. Rewrote to match. **Lesson: CLAUDE.md's own documented pgTAP pattern ("hardcoded UUIDs, no variable passing") is the simple case; a test needing a genuinely dynamic value (an auto-generated document number) needs the `set_config`/`current_setting` bridge, confirmed by reading an existing multi-scenario test file's actual structure, not just its opening comment.**

**Simplification vs. the original plan**: §4/§5's GL Posting Design assumed a header-confirmed-total-apportioned-down-to-lines indirection (mirroring Purchase Return). Building it, this proved unnecessary — Sales Return references exactly ONE already-approved invoice whose own line-level amounts are already fixed and trustworthy (no external debit note to reconcile against, unlike Purchase Return's multi-GRN case), so `fn_approve_sales_return` posts each line's own stored `gross_amount`/`tax_amount`/`final_amount` directly. Simpler than planned, not a scope cut.

**Not yet done**: migration 099 has not been run against Supabase; the pgTAP suite has not been executed; `flutter analyze`/`flutter test` have not been run against the new Flutter files (no local toolchain — see `feedback_no_flutter_toolchain_verification.md`); no manual click-through in a browser. Signature-name resolution (see §7 item 5) is a known, low-risk gap. The `docs/screens/sales_return.md` §6 open questions (refund split mechanics, DRAFT-as-real-stage, serial condition-flagging) were resolved as documented there — no changes needed based on the build itself.

Everything's in place and self-consistent. Summary of what's done:

Back button — removed entirely from all 19 entry screens (navbar-only, all platforms), including cleanup of the now-dead go_router imports it left behind.

Sales Return — full build:

Backend: 099_sales_return.sql (tables, fn_save_sales_return, fn_approve_sales_return, new CRN/SRET voucher types, new SALES_RETURNS_ACCOUNT link)
Flutter: complete data/domain/repository/provider layer, list screen, and a full entry screen (invoice picker, remaining-returnable qty tracking, mandatory batch/serial allocation, read-only proportional charges, conditional cash-refund fields)
Routes wired in, replacing the old placeholder
Print support (registry, template, provider, sample data)
pgTAP test suite (16 assertions)
Four real bugs caught and fixed during self-review (not just written blind):

Wrong cost field used for the secondary specific-currency stock average
rid_finance_lines doesn't carry source_doc_type/no/date (those live on the header table) — both the SQL and a Flutter datasource method had this wrong
A Flutter query used an unproven PostgREST embedded-filter syntax with zero precedent in this codebase — replaced with the proven two-step pattern used everywhere else
First pgTAP draft didn't match this repo's actual proven test structure — rewritten to match
Not yet done (flagged in the doc and memory, not hidden): migration hasn't run against Supabase, pgTAP suite hasn't executed, no flutter analyze/flutter test, no manual click-through. Everything's mechanically balance-checked but this is a from-scratch build in one sitting — treat it like any first-run migration.

Let me know when you want to run it against Supabase, or if you'd like me to keep going (e.g., resolving the signature-name placeholder gap, or starting on the flutter analyze pass once you're in Codespace).

please cose todays session . Please perform closing activities. Do not forget any thing. Please make notes of what's the important point..

Session closed out. Memory updated with two files:

project_session_close_2026_07_20_pt2.md (new "read first" entry) — indexes this session: back button removed app-wide, full Sales Return module built, and flags the one critical fact for next time.
MEMORY.md — index updated (session recap line + read-first pointer).
The one thing I don't want you to miss: nothing from this session is committed. git status shows 24 modified files (back-button removal) + 10 new untracked files (the Sales Return module) — all sitting uncommitted in the working tree. I didn't commit because you didn't ask me to (per this project's git rules), but that means if this session's context is lost, the only record of today's work is the working-tree files themselves plus these memory notes.

Do you want me to commit before we stop? I'd suggest two separate commits matching the two independent things you asked for:

Back button removed app-wide (19 files)
Sales Return module (migration 099 + full Flutter layer + print + pgTAP)
Everything else from the closing checklist is captured in memory: what's verified (mechanical balance checks only, no toolchain here) vs. not (no flutter analyze, no Supabase run, no pgTAP execution, no manual click-through), the 4 real bugs caught during self-review, and the concrete next-step order (commit → run migration 099 → run pgTAP → flutter analyze/test → manual click-through → fix the signature-placeholder gap).

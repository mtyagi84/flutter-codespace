# Credit Sales Invoice — new screen, reusing the Quick Invoice engine

Status: Implemented 2026-08-20 (migration `146_credit_sales_invoice.sql`). Not yet run in Supabase.

## Context

SAKAL had one Sales Invoice document type before this: "Quick Invoice" — a POS-style, single-click
checkout flow where Save always immediately approves, Cash sales force the customer to a per-user
"cash customer", and stock/cash typically move at the same moment as the sale. This adds a second,
dedicated entry point for genuine trade-credit sales: a proper document with its own Save Draft /
Approve lifecycle, an operator-chosen Customer and Location, a hard future-date block, and a date that
locks once first saved — followed later by a separate Sales Delivery (already built) and a separate
Payment/Receipt Voucher collection (already built). The stated flow: **Credit Sales Invoice → Sales
Delivery → Cash/Bank Collection**.

Deliberately NOT a mode toggle on the existing Quick Invoice screen — a genuinely new screen, reusing
the existing `rih_sales_invoices` backend engine (confirmed by reading `fn_save_sales_invoice`/
`fn_approve_sales_invoice`/`fn_cancel_sales_invoice` in full before writing any code: `sale_type=
'CREDIT'` already worked end-to-end — client-chosen customer, no cash-collection dependency, deliver-
later already wired through the existing Sales Delivery module).

## Decisions (confirmed via AskUserQuestion before implementation)
1. **Same `rih_sales_invoices` table + `fn_save_sales_invoice`/`fn_approve_sales_invoice`/
   `fn_cancel_sales_invoice` functions** — one shared engine, one single continuous invoice numbering
   sequence (`fn_next_trans_no(...,'SI')`) shared by BOTH Cash and Credit invoices regardless of which
   screen created them (explicitly confirmed — no separate number series per sale_type).
2. **Quick Invoice's existing behavior must not change at all** — every new rule is scoped behind one
   new trailing `p_credit_invoice_screen BOOLEAN DEFAULT false` parameter; Quick Invoice's own call
   sites never pass it (default `false`), so its behavior is byte-for-byte identical to before.
3. **Save Draft + Approve as two separate buttons** (matching PO/GRN/Sales Order's standard document
   pattern) — not Quick Invoice's single auto-approving Save.
4. **New dedicated list screen + menu entry** (`SL-CINV`), not folded into the existing Sales Invoice
   list.

## Design

### Backend — one additive, backward-compatible migration (146)
- **`fn_save_sales_invoice`**: old 7-param signature (`p_header, p_lines, p_charges, p_batches,
  p_serials, p_user_id, p_enforce_cost_check` — confirmed live via migration 121, not the original 089
  6-param shape) explicitly `DROP FUNCTION`'d before appending `p_credit_invoice_screen BOOLEAN DEFAULT
  false` as the 8th param (same safety pattern migration 080 established — appending without dropping
  first silently creates a second overload instead of replacing the function). Three new checks, all
  gated `IF p_credit_invoice_screen THEN`:
  1. **Forced DEFERRED dispatch** — a single-point override (`v_dispatch_stock := false` right after
     it's read from `ric_companies`) that every downstream `coalesce(v_dispatch_stock, true)` usage
     (the `stock_dispatch_mode` column, both batch/serial mandatory checks) inherits for free, with zero
     other line changes.
  2. **Hard future-date block** (`FUTURE_DATE_NOT_ALLOWED`) — non-configurable, enforced at SAVE (not
     just approve, unlike Material Requisition/Issue's own hard block) since a Credit Invoice can sit in
     DRAFT indefinitely and must never even be creatable with a future date.
  3. **Date locked after first save** (`INVOICE_DATE_LOCKED_AFTER_FIRST_SAVE`) — genuinely new to this
     schema (no field-level partial-DRAFT lock precedent existed before). `invoice_no` was already
     immutable by construction (the UPDATE's WHERE-key, never its SET list).
- **`fn_approve_sales_invoice`/`fn_cancel_sales_invoice`**: a real gap found during planning, not
  originally requested — both hardcoded their approve-permission check to feature_code `'SL-INV'`
  (migration 114), meaning a user who can approve Credit Invoices but was never separately granted Quick
  Invoice's own `SL-INV` permission would be silently blocked. Fixed with a body-only change (signatures
  unchanged, no DROP FUNCTION needed): `CASE WHEN v_header.sale_type = 'CREDIT' THEN 'SL-CINV' ELSE
  'SL-INV' END`, ties the permission check to the document's real nature rather than which screen
  created it. Both full function bodies were extracted byte-exact from their live source migrations
  (122, 114) via `sed` before this one-line patch, to guarantee zero accidental drift from the true
  current signature — not retyped from memory.
- **Registry**: new `SL-CINV` "Credit Sales Invoice" feature code, `serial_no=7` (appended after Cash
  Receipt's `6`, no downstream serial shift needed), reused for both menu/screen access AND the
  approve-permission check above. `fn_seed_client_modules.sql` updated for future clients.

### Frontend
- **`lib/features/sales/presentation/screens/credit_sales_invoice_entry_screen.dart`** — a new file,
  started as an exact copy of `sales_invoice_entry_screen.dart` (2587 lines) then surgically adapted
  rather than hand-authored from scratch, so all the proven Quick Invoice machinery (line-item grid,
  batch/serial + FEFO, charges, tax computation, AGAINST_QUOTATION/AGAINST_ORDER mode switching, print)
  transfers unmodified. Changes:
  - `sale_type` is a `final` constant `'CREDIT'` — no Cash/Credit toggle at all.
  - **Location** is now a real, editable `DropdownButtonFormField` (unlike Quick Invoice's read-only
    quick-setup location), sourced from a new `accessibleLocationsProvider`
    (`lib/core/providers/master_cache_providers.dart` — queries `v_user_accessible_locations`, migration
    127's existing JWT-scoped view: zero active `ric_user_location_access` rows for this user =
    unrestricted, any rows = limited to that set). Reusable by any future screen; not yet retrofitted to
    Sales Order's own unrestricted location dropdown (out of scope here).
  - **Customer** picker is always visible/editable in DIRECT mode (the same `SakalAutocomplete` +
    `accountsProvider` filter Quick Invoice's own Credit-mode picker already used) — no longer gated
    behind a Cash/Credit check, since there's no Cash mode on this screen. Still read-only/server-forced
    in AGAINST_QUOTATION/AGAINST_ORDER mode, matching Quick Invoice's own behavior.
  - **Invoice Date** changed from a plain read-only display to a real `showDatePicker` field
    (`lastDate: DateTime.now()`, client-side mirror of the new hard server-side block), which becomes
    read-only client-side once the invoice has been saved once (`_dateLocked`), with helper text
    explaining why.
  - Removed entirely: the Cash/Credit `SegmentedButton`, the walk-in party name/phone/address row, the
    cash-collection card/validation, the `ric_user_quick_invoice_setup` dependency (`_quickSetup`,
    `_cashSetupMissing`, `_applyCashCustomer` all deleted as genuinely dead code once `sale_type` could
    no longer be `'CASH'`).
  - **Save Draft + Approve** are two separate methods (`_saveDraft()`/`_approveInvoice()`) and two
    separate header/mobile action buttons, replacing the old single `_saveAndApprove()` that always
    chained Save→Approve. Both `ds.save(...)` call sites (online and the offline-queued payload) now
    pass `creditInvoiceScreen: true` / `p_credit_invoice_screen: true`. Offline save (DIRECT mode only,
    same restriction Quick Invoice's own Against-* modes already have) still only ever queues `Save`,
    never auto-chains Approve — Approve stays online-only, standard convention across every module.
- **`lib/features/sales/presentation/screens/credit_sales_invoice_list_screen.dart`** — a new, smaller
  file (~330 lines) modeled on `sales_invoice_list_screen.dart`, calling the same `listInvoices(...,
  saleType: 'CREDIT')` repository method with the filter hardcoded — no Type filter dropdown at all
  (every row is already Credit by construction). Delivery-status badge is unconditional here (every
  Credit Invoice is DEFERRED-dispatch by construction), unlike Quick Invoice's own conditional check.
- **Repository plumbing**: `SalesInvoiceRepository.save()` (interface, impl, remote_ds) gained an
  optional `creditInvoiceScreen = false` param threaded straight into the RPC's `p_credit_invoice_screen`
  key — Quick Invoice's own three call sites never pass it, so its behavior is unaffected.
- **Routing**: `RouteNames.creditSalesInvoices`/`creditSalesInvoiceEntry` + two new `GoRoute`s in
  `app_router.dart`, same `extra`-map shape as Quick Invoice's own entry route.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/146_credit_sales_invoice.sql` | **New** — the whole backend |
| `backend/functions/fn_seed_client_modules.sql` | New `SL-CINV` row for future clients |
| `lib/features/sales/presentation/screens/credit_sales_invoice_entry_screen.dart` | **New** |
| `lib/features/sales/presentation/screens/credit_sales_invoice_list_screen.dart` | **New** |
| `lib/core/providers/master_cache_providers.dart` | New `accessibleLocationsProvider` |
| `lib/core/router/route_names.dart` / `app_router.dart` | Two new routes |
| `lib/features/sales/domain/repositories/sales_invoice_repository.dart` | `save()` gained `creditInvoiceScreen` param |
| `lib/features/sales/data/datasources/sales_invoice_remote_ds.dart` | `save()` passes `p_credit_invoice_screen` |
| `lib/features/sales/data/repositories/sales_invoice_repository_impl.dart` | `save()` threads the new param |

## Verification

No local Flutter/Postgres toolchain. After the user runs the migration and pulls, in priority order:
1. **Quick Invoice regression check first** — Cash and Credit sale_type both still behave byte-for-byte
   identically to before: normal Save-and-approve flow, stock dispatch timing still follows the
   company's `quick_invoice_dispatch_stock` flag, no future-date/date-lock errors ever appear (Quick
   Invoice never passes `p_credit_invoice_screen: true`).
2. Credit Sales Invoice: Save Draft with a future date → `FUTURE_DATE_NOT_ALLOWED`. Save Draft, then
   re-save with a different date → `INVOICE_DATE_LOCKED_AFTER_FIRST_SAVE`; re-save with everything else
   changed but the same date → succeeds.
3. Approve a DRAFT Credit Invoice → stock stays undispatched (`stock_dispatch_mode='DEFERRED'`
   regardless of the company's own dispatch flag) and the Customer DR bill appears in Payment/Receipt
   Voucher's Against-Bill picker, unsettled.
4. Raise a Sales Delivery against the APPROVED Credit Invoice (existing screen) → stock actually
   dispatches at that point, not before.
5. A user with `SL-CINV` approve-permission but NOT `SL-INV` can approve a Credit Invoice; a user with
   only `SL-INV` cannot (confirms the permission-code fix, and that Quick Invoice's own approve
   permission for CASH invoices hasn't regressed).
6. Location dropdown only lists locations the logged-in user has `ric_user_location_access` for (or
   all, if they have no access rows at all).
7. AGAINST_QUOTATION/AGAINST_ORDER picker + mode switch works identically to Quick Invoice's own (source
   doc's lines/charges copied verbatim, customer forced from source, fields locked).
8. `flutter analyze` clean on both new screen files and every touched shared file.

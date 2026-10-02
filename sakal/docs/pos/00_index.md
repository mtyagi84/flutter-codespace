# SAKAL POS (Supermarket) — Documentation Index

Status: In progress, 2026-10-01. This folder is the working requirements +
design set for the new POS module family. Supermarket POS is being specified
first; Restaurant POS is a later phase that reuses the terminal/shift/tender/
loyalty backbone built here and adds a table/order/kitchen-ticket layer not
covered by these documents.

**How this module relates to what already exists**: SAKAL already has a
cash-first, fast-entry sales screen — "Quick Invoice" (`rih_sales_invoices`,
migrations 088-090, `sales_invoice_entry_screen.dart`,
`docs/screens/sales_invoice.md`). POS is not a parallel system — a POS sale
**is** a Sales Invoice row (`sale_type='CASH'`), tagged with a new
`pos_shift_id`, sharing its tax engine, discount governance, FEFO batch/serial
allocation, charges, printing and offline save logic. POS returns are Sales
Return rows (migration 099) the same way. What's genuinely new is everything
around the sale: terminals/devices, shifts/cash-up, split multi-currency
tender, hold/resume, payouts, loyalty, schemes, and bundles.

## Reading order

1. [`01_data_model.md`](01_data_model.md) — every new table, and which
   existing SAKAL table each POS concept extends vs. sits beside.
2. [`02_pricing_promotions_loyalty.md`](02_pricing_promotions_loyalty.md) —
   pricing/discount/tax/rounding sequence, the promotion/scheme engine,
   bundle sales, loyalty program design.
3. [`03_payments_multicurrency.md`](03_payments_multicurrency.md) — split
   multi-tender, multi-currency, payment state machine.
4. [`04_shift_cash_management.md`](04_shift_cash_management.md) — shift
   lifecycle, cash-up, variance, cash-in/out/payout/drop.
5. [`05_returns_exchange_void_approvals.md`](05_returns_exchange_void_approvals.md)
   — POS returns/exchange, void/cancel, the approval-record shape.
6. [`06_access_security.md`](06_access_security.md) — POS user/terminal/
   device access model and permissions.
7. [`07_offline_sync.md`](07_offline_sync.md) — offline strategy.
8. [`08_reporting_audit.md`](08_reporting_audit.md) — reports and audit trail.
9. [`09_screens_and_mockups.md`](09_screens_and_mockups.md) — the 12-screen
   map, responsive breakpoints, mockup files and published Artifact links.
10. [`10_phase_plan.md`](10_phase_plan.md) — delivery phases, already-built
    vs. net-new.
11. [`11_open_decisions.md`](11_open_decisions.md) — business decisions to
    confirm before build starts.
12. [`12_feature_checklist.md`](12_feature_checklist.md) — a scan-and-check
    list of every feature, grouped by done/reused/Phase 2/gap, for a quick
    completeness review.

## Already built in SAKAL — reused, not rebuilt

| Capability | Reused asset |
|---|---|
| Tenancy / RLS | `ric_clients`/`ric_companies`/`ric_locations`, `auth_rw_<table>` pattern |
| Multi-location access | `ric_user_location_access`, `v_user_accessible_locations` |
| Products, barcoding, pack/loose | `rim_products`, `rim_product_uom` (per-UOM barcode) |
| Pricing | `fn_get_active_price` (currency-aware, migration 086) |
| Tax | `rim_tax_groups`/`rim_taxes`/`rim_tax_rates`, `fn_get_active_tax_rate` |
| Discount governance | `ric_user_sales_controls`, `fn_verify_discount_override` |
| Batch/serial + FEFO | `rid_transaction_line_batches/serials`, `v_batch_stock_balance`/`v_serial_stock_status` |
| Currency / FX | `rim_currencies`, `rim_exchange_rates`, `fn_get_exchange_rate` |
| GL account resolution | `rim_account_link_types`, `fn_resolve_account_link`/`fn_resolve_company_account_link` |
| Sale posting engine | `fn_save_sales_invoice`/`fn_approve_sales_invoice` (`rih_sales_invoices`) |
| Return posting engine | `fn_save_sales_return`/`fn_approve_sales_return` (migration 099) |
| Offline | `SyncEngine`, `generateLocalId()`, Drift cache tables |
| Reporting | Generic reporting engine (migration 116: `ric_report_definitions`/`columns`/`filters`) |
| Permissions | `ric_master_menus`/`ric_user_menus` (`feature_code`, `approve_allowed`) |
| Common pick-lists | `rim_common_master_types`/`rim_common_masters` |
| Printing | `PrintEngine`, `PaperProfile` (58/80mm already modeled, no default template yet) |

## Genuinely new for POS

Terminals/devices, shifts (open/cash-up/close), denomination counting,
multi-currency split tender lines, cash payouts/drops, hold/resume sale,
loyalty program + ledger, schemes/promotions engine, bundles, POS-specific
access/device-binding, a 58/80mm receipt default print template, and a POS
audit log.

Status: Implemented 2026-09-13 (Phases 1-5 of the "new-tenant bare-minimum
starter kit" initiative). Phase 6 (India real dual-GST) intentionally
deferred — see its own section at the bottom.

# New-Tenant Master Data Checklist

What a brand-new tenant gets automatically today, versus what stays a
deliberate manual step, and why. Re-check this list whenever a new
master-data category is added anywhere in the app — the recurring bug
this whole initiative exists to prevent is a migration seeding default
data only for companies that already existed at the time it ran, never
wired into ongoing registration (`fn_register_client`).

## Automatic at registration (`fn_register_client` → `fn_seed_client_modules` → `fn_seed_report_definitions_for_company` → `fn_seed_common_masters_for_company`)

| What | Mechanism |
|---|---|
| System Modules + Master Menus | `fn_seed_client_modules` |
| Report Definitions/Columns/Filters/Group Levels (~75 reports) | `fn_seed_report_definitions_for_company` (copies an existing company as template) |
| Purchase Return Reason, Stock Adjustment Reason, Incoterm, Customer/Supplier Category default values | `fn_seed_common_masters_for_company` |
| Bare-minimum UOM (PCS/KG/LTR/BOX), Brand (Generic), Color (N/A) | `fn_seed_common_masters_for_company` |
| Category Level 1 + 8 standard Product Flag Types + one "General" item category | `fn_seed_common_masters_for_company` |
| Currencies (all, base/local activated) | `fn_seed_company_currencies` — `AFTER INSERT ON ric_companies` trigger |
| Countries (~200, inactive except relevant ones activated manually) | `fn_seed_company_countries` — same trigger pattern |

## Automatic at the Accounting Setup wizard step (`fn_complete_accounting_setup`)

Chained into the registration wizard itself (Step 3, pre-selected from
the chosen local currency) as of 2026-09-13 — previously a wholly
separate, easy-to-miss post-login screen. `accounting_setup_screen.dart`
still exists as a fallback for any tenant that skips the wizard step.

| What | Mechanism |
|---|---|
| Chart of Accounts tree | `fn_seed_chart_of_accounts` — OHADA / INDIAN / **ZAMBIA** (new) |
| Stock / Cost of Sales / Purchase Accrual leaf accounts | `fn_seed_default_leaf_accounts_and_links` |
| Account Link Setup + Defaults for the 4 link types `fn_approve_grn`/`fn_approve_sales_invoice` actually require (STOCK_ACCOUNT, PURCHASE_ACCRUAL_ACCOUNT, SALES_ACCOUNT, COST_OF_SALES_ACCOUNT) | `fn_seed_default_leaf_accounts_and_links` |
| First Financial Year | `fn_complete_accounting_setup` (FY start month asked in the wizard) |
| Default Tax Setup: 16%/0% VAT for **OHADA (DR Congo)** and **ZAMBIA** | `fn_seed_default_tax_setup` — **INDIA deliberately skipped, see Phase 6 below** |

The other 9 Account Link Types (Stock Adjustment, Depreciation, Sales
Discount, Stock in Transit, Exchange Gain/Loss, Plant Stock ×2, Stock
Account FG, Stock Consumption) are left unconfigured — a brand-new tenant
won't reach those modules on day one; configure them via the Account
Link Setup screen when/if the tenant needs them.

## Deliberate manual steps (by design, not gaps)

| What | Why manual |
|---|---|
| Tax rates for India (real GST) | See Phase 6 below |
| Bank Statement Formats | Bank-specific column mappings, can't be defaulted |
| Payment Terms | Business-specific credit terms |
| Product-specific Brand/UOM/Color beyond the bare-minimum starter values | Business-specific catalog data |
| `tracking_type` (Batch/Serial) per product | Per-product attribute, never a company-level default |

## Phase 6 (not yet built): India's real dual-GST

India's GST needs CGST+SGST (intra-state) vs IGST (inter-state), which
requires knowing whether a transaction crosses a state boundary — this
schema has **zero state/province tracking anywhere** (no `state`/
`state_code` column on `ric_companies` or `rim_accounts`, confirmed via
grep, 2026-09-13). Building this needs, in order:
1. Add `state`/`state_code` to `ric_companies` (the company's own "home
   state") and `rim_accounts` (customer/supplier's state).
2. Add intra/inter-state determination logic to every `fn_save_*`/
   `fn_approve_*` that currently picks a tax group, comparing the two.
3. Only then seed real `rim_taxes` for CGST/SGST/IGST at 0%/5%/18%/40%
   (per the Sept-2025 GST reform) using `rim_tax_compound_sources`
   (schema support already exists, unused).

Until this lands, a new INDIAN-standard tenant gets no default tax setup
at all (`fn_seed_default_tax_setup` no-ops for `accounting_std = 'INDIAN'`)
— same as any tenant before this whole initiative; the Tax Master screen
is available to configure it manually in the meantime.

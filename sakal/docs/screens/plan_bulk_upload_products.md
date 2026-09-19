# Bulk Upload Products v2 — Dedicated Screen, Auto-Create Masters

Status: Implemented 2026-09-19 (migrations 189/190/191 deployed and
verified live; `flutter analyze` clean on every touched file). Supersedes
the simple "Upload Excel" button added to Product Master in an earlier
same-session plan (`plan_shanju_tenant_onboarding.md`) — that button was
removed as part of this work.

## Context

After trying the simple Product Master "Upload Excel" button built for
Shanju's onboarding, the user asked for a genuinely complete, reusable
version — a dedicated screen that not only creates products but also
auto-creates whatever Category/Sub-Category/Item Size/Item Color/Unit
master data a row needs (so a Data Operator never has to stop and go set
up masters by hand first), shows the parsed rows in an editable grid for
review before saving (like Opening Balance Entry already does), and
leaves every future tenant's onboarding needing zero code changes. Two
research passes (Tax Master/Tax Groups structure; new-screen/menu wiring +
Item Category internals) confirmed the exact constraints this needs to
respect.

## Key structural finding — Tax Groups CANNOT be auto-created like the others

Category/Unit/Item Size/Item Color/Brand are all safe to auto-create from
a bare name (`rim_item_categories`/`rim_common_masters` need nothing else).
A Tax Group is structurally different: a real, useful one needs actual
`rim_taxes` rows (with `rim_tax_rates` — a separate child record with its
own `effective_from` date, entered through a two-step edit-mode-only UI
flow) linked via `rim_tax_group_members`, plus GL accounts for posting.
Nothing about that can be inferred from an Excel cell.

## Second finding — plain (non-partial) UNIQUE constraints mean soft-deleted masters must be REUSED, not re-created

`rim_item_categories`'s `(client_id, company_id, parent_id, category_name)`
and `rim_common_masters`'s `(client_id, company_id, type_id, description)`
UNIQUE constraints are **not** partial on `is_deleted=false` (confirmed by
reading both migrations directly) — the exact same recurring gotcha class
already documented elsewhere in this project (`uq_users_client_username`).
Practical effect: if a prior upload run soft-deleted an unused
auto-created Category/Unit/Size/Color/Brand (see Cleanup below), and a
LATER upload needs that same name again, inserting a fresh row would hit
a 409 unique-violation — the ONLY working option is to find the
soft-deleted row by name and flip `is_deleted` back to `false` (reuse/
"undelete" it), never attempt a second insert. Every auto-create lookup
in this feature searches **regardless of `is_deleted`**, and reuses
(undeleting if needed) rather than ever assuming "not found among active
rows" means "safe to insert."

## Decisions (confirmed)

1. **Removed the simple upload button** from `product_list_screen.dart`
   — this new screen is the one path, avoiding two divergent bulk-import
   mechanisms to maintain.
2. **Unmatched Tax Group → one-time BATCH confirmation, not silent
   either way.** A per-row popup across hundreds of rows isn't practical,
   and both silent extremes have a real downside: silently skipping risks
   "why did half my file not upload?" surprise, silently creating risks
   products quietly missing tax config until someone notices during a
   real sale (`sales_tax_group_id`/`purchase_tax_group_id` are nullable,
   so creating-without-tax is always technically possible — the real
   question is visibility). After parsing, if any rows have an unmatched
   Sales/Purchase Tax Group name, one dialog lists the distinct missing
   names and how many rows each affects, with two choices applied to the
   whole batch: "Skip these N rows" or "Create them anyway without that
   tax field" — the user decides once, before Save actually runs.
3. **Added Brand** to the template with the same auto-create/N/A-if-blank
   treatment as Item Size/Item Color (full parity with the single-product
   entry screen).
4. **Cleanup uses soft-delete**, and reuses (undeletes) a soft-deleted
   match instead of ever re-inserting a duplicate name.

## New screen + menu wiring

- **Feature code**: `MST-BUP`, `screen_name = '/master/bulk-upload-products'`,
  group `IN-MST` (Inventory Masters — same group as `MST-PRD`/`MST-ITC`,
  serial_no 5), `excel_upload_allowed = true`.
- **Migration 191**: `INSERT ... ON CONFLICT` into `ric_master_menus`
  (exact shape from migration 133's own Opening Balance rollout) +
  `ric_user_menus` backfill for existing users with edit access to any
  other AD-module feature (same join pattern). Also reverts `MST-PRD`'s
  `excel_upload_allowed` (set `true` by migration 190) back to `false`,
  since the simple button it gated was removed.
- **`fn_seed_client_modules.sql`**: `MST-BUP` row added to the existing
  Inventory Masters block (alongside `MST-PRD`/`MST-ITC`/`AD-PCS`/
  `AD-PGS`/`IN-DCA`), `MST-PRD`'s own seed value reverted to `false`.
- **Flutter routing**: `RouteNames.bulkUploadProducts = '/master/bulk-upload-products'`
  in `route_names.dart`; `GoRoute` in `app_router.dart` alongside the
  other `/master/*` entries.
- **New file**: `lib/features/master/presentation/screens/bulk_upload_products_screen.dart`,
  built on the same `ScreenPermissionMixin`/`ScreenHeaderMixin`/
  `DeferredRowDisposal` combination as `opening_balance_entry_screen.dart`.

## Excel template columns

`Product Name*`, `Description`, `Product Nature` (must match the
`rim_products.product_nature` enum — blank defaults `TRADING`), `HSN/SAC
Code`, `Category L1*`, `Category L2`, `Category L3`, `Category L4` (L1
required if any category given at all; L2 required if L3 given; L3
required if L4 given — a gap in the chain skips the row with a clear
error), `Item Size` (blank → auto-create/reuse "N/A"), `Item Color` (same),
`Brand` (same), `Unit of Measure*`, `Unit Cost`, `Maintain Price In`
(blank → company's own base currency id), `Allowed Cost Variance %`
(blank → 0), `Sales Tax Group`, `Purchase Tax Group` (both must match an
EXISTING tax group by name AND `applicable_on` — SALES/BOTH for the Sales
column, PURCHASE/BOTH for the Purchase column — see the Tax Group finding
above).

## Staging grid (before Save)

Same shape as `opening_balance_entry_screen.dart`: Upload Excel replaces
the current `_lines` (not append); every row loads into an editable
line-item row (`SakalScrollableTable` for the desktop grid); the user can
edit any cell inline before Save. Nature is a real dropdown (not free
text) to rule out a whole class of invalid-enum row errors up front.

## Save — the per-row processing pipeline

Runs sequentially (not in parallel), since later rows may depend on
masters created earlier in the SAME save pass:

1. **Fetch once, up front**: all existing product names (for dedup), all
   existing categories (all 4 levels, regardless of `is_deleted`), all
   existing common masters for UNIT/BRAND/ITEM_SIZE/COLOR (regardless of
   `is_deleted`), all existing active tax groups, the company's base
   currency id, and `rim_product_flag_types` (calling the same "Load
   Defaults" mechanism `ProductFlagTypeModel.defaults()` +
   `loadDefaultFlags()` already use, if this company has zero flag-type
   rows yet).
2. **Per row**: dedup by `upper(trim(product_name))`; resolve/auto-create
   the Category chain (L1→L4, reusing a soft-deleted match rather than
   inserting a duplicate, also ensuring a `rim_category_levels` row exists
   for every level used so the ordinary Item Categories screen stays
   usable); resolve/auto-create Item Size, Item Color, Brand (blank →
   "N/A"), Unit of Measure; resolve Sales/Purchase Tax Group by exact
   name+`applicable_on` match against EXISTING groups only, recording (not
   yet actioning) an unmatched name; build the `rim_products` insert
   payload + the mandatory base `rim_product_uom` row, with `flags` seeded
   from `rim_product_flag_types.default_value`; track every NEWLY
   auto-created (not reused) master id for the cleanup pass.
3. **Batch tax-group confirmation** (only if any row hit an unmatched
   name): one dialog, applied to the whole batch — drop those rows, or
   clear just the unmatched tax field(s) and keep them.
4. **Commit** every surviving row.
5. **End-of-run cleanup**: for every id tracked as newly auto-created this
   run, check whether ANY product (existing or just-created) actually
   references it; if zero references, soft-delete it.
6. **Summary dialog**: N products created, M rows skipped (with reasons),
   P masters auto-created, Q auto-created masters cleaned up as unused.

## Files touched
- New: `lib/features/master/presentation/screens/bulk_upload_products_screen.dart`.
- New: `backend/migrations/191_bulk_upload_products_menu.sql`.
- Edit: `lib/core/router/route_names.dart`, `lib/core/router/app_router.dart`,
  `backend/functions/fn_seed_client_modules.sql`.
- Edit: `lib/features/master/presentation/screens/product_list_screen.dart`
  — removed the simple Upload Excel button/methods from the earlier plan.
- Updated `sakal/docs/Tenant/Shanju_Onboarding_Runbook.md` and
  `Shanju_Staging.xlsx`'s `Products` tab to the new template/flow.

## Verification
- `flutter analyze` clean on every touched file, and on the whole project.
- Migrations 189 (Zambia COA additions), 190 (original Chart of
  Accounts + Product Master upload permission), and 191 (this screen's
  menu wiring + `MST-PRD` reversion) all deployed and confirmed live
  directly against the database (`ric_master_menus`/`ric_user_menus` rows
  checked for both `MST-BUP`=true and `MST-PRD`=false).
- **Not yet done**: an actual end-to-end manual upload through the
  deployed app (the smoke test described in the original plan — a
  brand-new category, a brand-new Item Size, an unmatched Tax Group, and a
  second run reusing a soft-deleted master) — pending the next Cloudflare
  redeploy and the user's own walkthrough.

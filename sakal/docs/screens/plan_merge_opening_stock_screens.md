Status: Approved, not yet implemented (2026-09-20)

# Merge Opening Stock + Opening Stock Value Upload into one screen

Supersedes building/keeping "Opening Stock Value Upload" as a separate screen
(see `plan_opening_stock_value_upload.md`, now marked superseded) — that
screen shipped, works, but the user correctly flagged it as functionally
duplicating the existing Opening Stock screen. This plan retires it and
folds its unique value into the original screen instead.

## Context

Two screens currently establish opening stock for a product/location:
`opening_stock_entry_screen.dart` (`/inventory/opening-stock-entry`, feature
`IN-OPN` — manual/scan/small-Excel entry, full batch/serial support,
Pack/Loose qty split, Save Draft → separate Approve, offline-capable, never
posts GL) and `opening_stock_value_upload_screen.dart`
(`/inventory/opening-stock-value-upload`, feature `IN-OSV`, built
yesterday — bulk-Excel-only, pre-filled template from Product Master, posts
GL (Dr Stock Account / Cr Opening Stock Equity Account), date locked to FY
start, one-click Save+Approve, online-only). Both write to the exact same
tables (`rih_opening_stock_headers`/`rid_opening_stock_lines`) via the exact
same functions (`fn_save_opening_stock`/`fn_approve_opening_stock`,
migration 193's `post_gl` extension) — the difference is entirely in the
UI/workflow layer, not the data model. The user wants ONE screen, better
UI/UX, not slow, both scrollbars, covering both sets of functionality.

## Design decisions

1. **Base the merged screen on the Value Upload screen's grid architecture**
   (`ListView.builder` + per-axis `ScrollController`s + `Scrollbar` on each +
   synced horizontal scroll between a fixed header row and the body) — this
   is the proven, bug-fixed pattern from this session (row-height gaps,
   missing horizontal scrollbar, header-scrolls-away, and hang-at-~400-rows
   were all found and fixed on it). The original screen's `SakalScrollableTable`
   eagerly builds every row and was never exercised past a handful of manual
   lines — unsafe now that this screen must also handle a full bulk import.
   Directly satisfies "not slow" + "both scrollbars."
2. **One unified Excel template**: always pre-filled from Product Master
   (Product Code/Name/Unit filled in, everything else blank) — strictly
   better than the original's blank-header template for every use case,
   including a quick manual top-up (delete the rows you don't need, or just
   use Add Line/Scan instead of Excel for that). Columns = union of both
   screens': Qty (or Pack Qty + Loose Qty, see #3), Batch No, Expiry Date,
   Manufacturing Date, Serial No, Unit Cost, Unit Cost Specific (Price in
   Product Currency), Barcode (if enabled), Remarks.
3. **Pack/Loose qty split respected** (`session.qtyEntryMode`), reversing
   Value Upload's own deliberate one-off exception — that exception was
   fine for a pure bulk-value-import screen, but the merged screen also
   handles live manual/scan entry, exactly the scenario this mandatory
   company-configurable-field pattern exists for. `base_qty` computed
   identically to the original screen's existing logic.
4. **Manual "Add Line" + scan-to-add preserved** from the original screen,
   ported onto the new row model — `SakalAutocomplete` product picker per
   row, barcode/part-number scan field gated by `showBarcode`/`enablePartNumber`
   exactly as today.
5. **GL posting becomes a header-level toggle** ("Post to Ledger (GL)"),
   not an implicit property of which screen you're on. **Toggle gates the
   date field's editability**: ON locks the date to FY start (same
   reconciliation reasoning as the Value Upload screen); OFF leaves the
   date freely editable at/before today, exactly as the original screen
   works today. Confirmation dialog wording adapts to whether GL will post.
6. **Save/Approve reverts to the original screen's 2-step flow** (Save
   Draft, then a separate Approve button) rather than Value Upload's
   one-click chain — this is the one deliberate simplification I'm
   reversing, for two reasons: (a) it's what makes offline support possible
   at all (Approve stays online-only app-wide; a one-click chain can't be
   offline-capable), and offline capability is real, already-working
   functionality on the original screen that a merge shouldn't quietly
   drop; (b) once this screen can also do a large bulk import, letting the
   user Save and review the full grid before committing to an irreversible
   GL-posting Approve is safer than a single all-at-once click. Approve's
   confirmation dialog still clearly states GL impact when `post_gl` is on.
7. **Advisory "already established" check**: adopt Value Upload's batched
   version (one `rim_product_location` query for every product on the grid
   when location changes) instead of the original's per-row live query —
   strictly better, avoids N+1 calls on a large import.
8. **Print support preserved** from the original screen (`_buildPrintDocument`,
   the `OPENING_STOCK` print template) — Value Upload never had this; no
   regression.
9. **Permission simplification**: retire the separate `IN-OSV` approve
   permission. The "Post to Ledger" toggle and the Approve action are both
   gated by the single, existing `IN-OPN` `canApprove` permission — there is
   no longer a second screen to justify a second permission axis. Backend:
   `fn_approve_opening_stock`'s existing `IF post_gl THEN check IN-OSV ELSE
   check IN-OPN` branch collapses to always checking `IN-OPN`.
10. **Retire `IN-OSV` entirely**: delete `opening_stock_value_upload_screen.dart`,
    its route/`RouteNames` entry; hide the menu item (`is_active=false`,
    matching the exact convention just used for the `PR-PAY`/`IN-STK`/`FN-CBK`
    orphan cleanup) and remove it from `fn_seed_client_modules.sql`. The
    `post_gl` column, the `OPENING_STOCK_EQUITY_ACCOUNT` link type, and
    `fn_approve_opening_stock`'s GL-posting logic all stay — the merged
    screen still needs every bit of that backend capability.

## Files touched

**Backend** (one new migration, next number 199):
- `fn_approve_opening_stock` — `CREATE OR REPLACE`, reproduce the current
  live body from migration 198 verbatim, collapse the permission-check
  branch to always check `IN-OPN` (drop the `IN-OSV` branch).
- Hide `IN-OSV` in `ric_master_menus` (`is_active=false, is_deleted=true`),
  same shape as migration 197.
- `fn_seed_client_modules.sql`: remove the `IN-OSV` row (manual re-deploy
  in Supabase SQL editor after, per this project's established convention
  for that file).

**Flutter**:
- Rewrite `lib/features/inventory/presentation/screens/opening_stock_entry_screen.dart`
  in place (same route, same list screen unchanged) with: the new
  ListView.builder-based desktop grid (reusing the compact/dense cell
  styling proven on Bulk Upload Products / Value Upload), manual Add Line +
  scan preserved, unified pre-filled Excel template/upload, the new
  "Post to Ledger (GL)" header toggle driving date-lock + `post_gl` in the
  save payload, batched already-established check, 2-step Save
  Draft/Approve preserved, offline queueing preserved, print preserved.
- Delete `opening_stock_value_upload_screen.dart`.
- Remove `RouteNames.openingStockValueUpload` + its `GoRoute` from
  `app_router.dart`/`route_names.dart`.
- `OpeningStockRepository` needs no interface change — `save`/`approve`/
  every other method already used by both screens is identical.

## Verification
- `flutter analyze` clean (targeted + full project).
- Manual smoke test once deployed: (a) small manual entry with GL off,
  editable date, matches today's Opening Stock behavior exactly; (b) bulk
  Excel upload of the full catalog with GL on, confirm date locks to FY
  start, grid stays responsive at 400+ rows with both scrollbars working;
  (c) confirm `IN-OSV` menu item is gone from the sidebar; (d) confirm a
  user with `IN-OPN` approve rights can toggle GL and Approve either way.

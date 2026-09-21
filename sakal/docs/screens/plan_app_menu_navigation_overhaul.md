Status: Approved, not yet implemented (2026-09-21)

# App Menu / Navigation Overhaul — module order, module landing pages, sidebar collapse, favorites

## Context

The user's own words: "Our App menu still not impressive." Four concrete complaints about the
current navigation, all confirmed live in the code:

1. **Module order is wrong and inconsistent** — `Settings` currently sorts first (`serial_no=0`
   in the seed), ahead of the actual work modules. Wanted order: Sales, Purchase, Inventory,
   Finance, Settings — for every tenant, existing and future.
2. **Clicking a module icon on the Dashboard jumps straight into a random first screen**
   (today: whichever feature happens to be first in DB order, e.g. Sales lands on Sales
   Quotation) instead of showing the user what's actually available in that module. The user
   wants a proper landing/hub page per module, organized by the module's real groups
   (Transactions, Reports, and whatever else exists for that module — see the confirmed
   decision below), with every menu option clickable straight through to its screen.
3. **A sidebar group ("Transactions", "Reports", etc.) can never be collapsed once shown.**
   Confirmed root cause: `_buildGroup` in `sidebar.dart` renders its features unconditionally
   (`...group.features.map(...)`, no expand/collapse condition at all) and its header's only
   `onTap` behavior is `context.go(groupPath)` — it navigates away, it doesn't toggle anything.
   Once a module is expanded, every one of its groups is permanently, fully expanded with no
   way to hide it again.
4. **No favorites/pinned quick-access exists anywhere.** Confirmed via search — zero
   scaffolding (no `is_favorite` column, no Dart widget/provider). A user with access to
   many menu items has no way to shortlist the handful they use daily.

## Confirmed decision (from clarifying question)

Module landing pages show **all of that module's real groups** (however many exist —
Transactions, Reports, Masters, Setup, etc.), not a forced 2-bucket Transactions/Reports
simplification. This avoids miscategorizing anything and needs zero re-bucketing logic.

## Part 1 — Module order (all tenants)

Module order is 100% server-side, per-tenant DB data (`ric_system_modules.serial_no`) — no
Flutter change needed at all; `Sidebar`/`DashboardScreen` both just render whatever order
`fn_get_user_menu` returns.

- `backend/functions/fn_seed_client_modules.sql` (lines 54-62): change the seed values to
  `SL=0, PR=1, IN=2, FN=3, AD=4` (Sales, Purchase, Inventory, Finance, Settings). Also fix a
  real, separate bug found while reading this: the `ON CONFLICT ... DO UPDATE SET` clause only
  refreshes `module_name`, never `serial_no` — add `serial_no = excluded.serial_no` so this
  function is actually idempotent for re-ordering, not just for renaming.
- New migration (next number): a plain, targeted
  `UPDATE ric_system_modules SET serial_no = CASE module_code WHEN 'SL' THEN 0 WHEN 'PR' THEN 1
  WHEN 'IN' THEN 2 WHEN 'FN' THEN 3 WHEN 'AD' THEN 4 END WHERE module_code IN (...)` across ALL
  existing companies — deliberately NOT re-running the full `fn_seed_client_modules` for
  every existing tenant (that function also touches ~75 menu/report rows per company; a
  5-row-per-company UPDATE on exactly the one column that needs to change is lower-risk and
  faster, especially with Shanju now a real, live tenant).

## Part 2 — Module Landing Page (Dashboard module-tile click)

Today (`dashboard_screen.dart` `_buildQuickAccess`, lines 151-175): tapping a module tile
flattens every group's features and does `context.go(firstFeature.screenName)` — straight into
an arbitrary first screen, skipping the module entirely.

New behavior: tapping a module tile navigates to a new **`ModuleLandingScreen`**
(`lib/core/layout/module_landing_screen.dart`, route `/module/:moduleCode`, added to
`RouteNames`/`app_router.dart` next to the existing `groupPath`/`GroupLandingScreen`). Modeled
directly on the already-working `GroupLandingScreen` (breadcrumb + `Wrap` of feature cards,
`lib/core/layout/group_landing_screen.dart`) but one level up: iterate `module.groups`, render
each group as its own titled section (group name as a section header) with that group's
features as cards directly beneath it — one page shows every group and every feature in one
scroll, and clicking any feature card's "Open →" goes straight to `feature.screenName` (no
extra hop through `GroupLandingScreen` needed, matching the user's literal ask: "when user
click on any menu option it should take him to that screen").

Extract the existing `_FeatureCard` widget (currently private to `group_landing_screen.dart`)
into a small shared widget both screens import, rather than duplicating it — the icon lookup
map (`_featureIcons`, currently only ~20 of 100+ feature codes covered) moves alongside it as
a shared lookup too, so both landing pages benefit from any future icon additions equally.

`GroupLandingScreen` itself is untouched — it stays as the target for the collapsed
(icon-only) sidebar rail's flyout menu, which has no room for a full accordion tree.

## Part 3 — Sidebar group collapse (the actual bug fix)

Root cause is `_buildGroup`'s header `onTap` navigating away instead of toggling, and its
feature list having no expand/collapse gate at all. Fix, mirroring the module-level pattern
that already works correctly (`sidebarExpandedModulesProvider` / `_toggleModule`, lines
196-210):

- New `sidebarExpandedGroupsProvider` (`StateProvider<Set<String>>`, same shape as the
  existing module one) in `lib/core/providers/session_provider.dart`.
- `_buildGroup`'s header `onTap` changes from `context.go(groupPath)` to a `_toggleGroup`
  toggle (same shape as `_toggleModule`) — no more navigation from this row.
- The feature list (`...group.features.map(...)`) becomes conditional on the group's own
  expanded state, wrapped in the same `ClipRect`/`AnimatedSize` pattern already used for the
  module level (lines 271-285) — a real accordion, not permanent.
- Trailing icon changes from the static `Icons.arrow_forward_ios` to the same
  `AnimatedRotation`-wrapped chevron the module header already uses, so it visually reads as
  "expand/collapse," not "navigate."
- `_seedInitialExpansion` (lines 40-57) — which today auto-expands whichever module contains
  the current route on first load — gets the same treatment one level down: also auto-expand
  the specific group containing the current route, so landing directly on a feature (deep
  link, refresh) doesn't hide the active item behind a collapsed group.

This is a pure UX/state fix — no backend or menu-data change needed for this part.

## Part 4 — Favorites / quick access

Confirmed net-new (zero existing scaffolding). Deliberately built as its own small table, NOT
a new column on `ric_user_menus` — that table also carries real permission grants
(`edit_allowed`/`approve_allowed`/etc.), and a favorite is a personal UI preference a user
should be able to self-service without ever writing to the same row that controls their
permissions.

**Backend** (one new migration):
- `ric_user_menu_favorites` table: `id, client_id, company_id, user_id, feature_code,
  created_at`, `UNIQUE (client_id, company_id, user_id, feature_code)`. RLS
  (`auth_rw_user_menu_favorites`) scoped to `client_id`/`company_id` match **and**
  `user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid` — a user
  can only ever see/insert/delete their own favorites, confirmed the JWT already carries a
  signed `user_id` claim (same one migrations 108/109's `fn_check_approve_permission` already
  reads).
- `fn_get_user_menu.sql`: extend the query with a `LEFT JOIN ric_user_menu_favorites fav ON
  fav.user_id = p_user_id AND fav.feature_code = mm.feature_code` and include
  `fav.id IS NOT NULL AS is_favorite` in the per-feature JSON — one bundled fetch, no second
  round-trip.

**Flutter**:
- `MenuFeature` (`lib/core/models/menu_models.dart`) gains `isFavorite`.
- A small `toggleFavorite(featureCode)` repository/provider method — direct PostgREST
  `POST`/`DELETE` against `ric_user_menu_favorites`, then invalidate `menuProvider` (mirrors
  the existing `ref.invalidate(...)`-after-mutation convention used all over this app) so the
  star updates immediately everywhere it's shown.
- A small star/pin icon toggle added to every place a feature is already rendered: sidebar
  `_buildFeature` rows, the shared `_FeatureCard` from Part 2 (used by both landing pages).
- Dashboard gets a new **Favorites** strip (`dashboard_screen.dart`), shown only when the user
  has ≥1 favorite (hidden entirely otherwise — no empty-state clutter), computed client-side
  by flattening the already-loaded `menuProvider` tree and filtering `isFavorite == true` — no
  extra fetch, same data the rest of the page already has.

## Files touched

**Backend**: `fn_seed_client_modules.sql` (module order + ON CONFLICT fix),
`fn_get_user_menu.sql` (favorites join), one new migration for the module-order backfill +
`ric_user_menu_favorites` table (can be one migration file covering both, they're unrelated
but both small/additive).

**Flutter**:
- `lib/core/layout/module_landing_screen.dart` (new)
- `lib/core/layout/group_landing_screen.dart` (extract `_FeatureCard`/icon map into a shared
  file, e.g. `lib/core/layout/menu_feature_card.dart`)
- `lib/core/layout/sidebar.dart` (group collapse fix, favorite star on feature rows)
- `lib/core/providers/session_provider.dart` (`sidebarExpandedGroupsProvider`, favorite
  toggle method)
- `lib/core/models/menu_models.dart` (`MenuFeature.isFavorite`)
- `lib/core/router/route_names.dart` + `app_router.dart` (`/module/:moduleCode` route)
- `lib/features/dashboard/presentation/screens/dashboard_screen.dart` (module tile → new
  route; new Favorites strip)

## Verification
- `flutter analyze` clean (targeted + full project).
- Manual smoke test once deployed: confirm sidebar shows Sales/Purchase/Inventory/Finance/
  Settings in that order for both an existing tenant (Shanju) and a freshly-registered one;
  click a Dashboard module tile and confirm it opens the new landing page showing every real
  group with its features, not a random screen; expand a sidebar module, click a group header,
  confirm its features toggle open/closed (and stay closed on a second click) instead of
  navigating away; star a couple of features from the landing page and the sidebar, confirm
  they appear in the Dashboard's new Favorites strip and the star state stays in sync across
  all three surfaces (sidebar / landing page / Favorites strip).

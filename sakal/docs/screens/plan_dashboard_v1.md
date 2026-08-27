Status: Implemented 2026-08-27 (migration 157, not yet run by user).

# Dashboard v1 — generic homepage, everyone-can-see content only

## Context

`DashboardScreen` was a fully static "coming soon" placeholder. User supplied a generic ERP-homepage
mockup (`sakal/docs/screens/erp_homepage_concept.html`) and was explicit: no role-restricted financial
KPIs (sales totals, stock value, etc.) — only generic, everyone-can-see content, since the navbar/sidebar
itself was explicitly out of scope for this task (touched the day before, separately).

## What changed from the mockup, and why
- **Quick Access / My workspace tiles** (Global Search, Favorites, Tasks, Documents) — none of these
  concepts exist in SAKAL. Replaced with one card per MODULE the viewing user has permission to see
  (`menuProvider`, already permission-filtered server-side) — zero new backend work, genuinely "generic"
  since it's navigation, not KPI data.
- **Pending Actions** — SAKAL has DRAFT/pending-approval concepts in every module but no cross-module
  aggregator. Built one (`fn_dashboard_pending_actions`, migration 157) — see below.
- **Announcements / Upcoming (calendar)** — dropped. Neither has a real, honest data source in SAKAL
  today (no broadcast-message feature, no meetings/calendar concept anywhere in this ERP).
- **System status** — the mockup's generic "ERP services: Operational" monitor means nothing for SAKAL's
  actual offline-first architecture. Replaced with SAKAL's own real, already-tracked state: online/offline
  mode (`session.offlineMode`) + pending-sync document count (`pendingSyncCountProvider`, the same
  provider `SyncStatusIndicator` in TopBar already reads).
- **Recent activity** — reuses `notificationProvider` (built the day before) directly.
- **Helpful links** — static list to screens that already exist (View Logs, Offline Data, Change
  Password).

## `fn_dashboard_pending_actions` (migration 157)
`RETURNS TABLE (document_type, feature_code, pending_count, route)`. One `UNION ALL` branch per document
type with a DRAFT/pending status, each gated by `EXISTS (... ric_user_menus WHERE feature_code=X AND
approve_allowed=true ...)` — a branch contributes ZERO rows (not a zero-count row) when the calling user
can't approve that feature, so the UI never lists something the user has no authority over. Ten branches
covering Sales (Invoice/Order/Quotation), Purchase (Order/GRN/Invoice), Inventory (Stock Adjustment/Stock
Transfer Request), Finance (Journal Voucher/Expense Voucher). Two branches (Stock Adjustment, Journal
Voucher) additionally filter `source_doc_type IS NULL` — same guard migrations 111/112 established for
the approve-permission checks themselves, so an auto-posted document (e.g. an adjustment created by
approving a Stock Count Review) isn't double-counted as its own separate pending item.

No new tables, no reporting-engine registry rows — this is a small RPC the Dashboard screen calls
directly via `DioClient`, not a report.

## New small shared utilities (extracted, not duplicated)
- `lib/core/utils/module_icons.dart` — the module-code→icon map, previously private to
  `sidebar.dart`'s own `_moduleIcons`, now shared by both the sidebar and the Dashboard's Quick Access grid.
- `lib/core/utils/relative_time.dart` — the "Xm ago"/"Xh ago" formatting, previously private to
  `NotificationBell`, now shared by the bell dropdown and the Dashboard's Recent Activity panel.

## Critical files
- `backend/migrations/157_dashboard_pending_actions.sql`.
- `lib/features/dashboard/presentation/screens/dashboard_screen.dart` — full rewrite, `ConsumerStatefulWidget`
  (needs its own loading state for the Pending Actions RPC fetch). Still deliberately NOT using
  `ScreenHeaderMixin` — preserves the existing TopBar company-name fallback on landing.
- `lib/core/layout/sidebar.dart`, `lib/core/widgets/notification_bell.dart` — updated to import the two
  newly-shared utilities instead of keeping their own private copies.

## Verification (pending — user has not yet run migration 157)
1. Dashboard shows a personalized, time-of-day-aware greeting; TopBar still falls back to the company
   name (not "Dashboard") on landing.
2. Quick Access grid shows exactly the modules the CURRENT user has menu access to.
3. Pending Actions lists only document types the current user can approve; a user with zero
   `approve_allowed` grants sees the empty state, not a wall of zero-count rows.
4. Creating a new DRAFT document (e.g. a Purchase Order) increases that row's count on next dashboard load.
5. Recent Activity mirrors exactly what the bell dropdown shows.
6. Sync & Offline Status reflects real state; hidden (sync count) on web.
7. `flutter analyze`/`flutter test` stay clean.

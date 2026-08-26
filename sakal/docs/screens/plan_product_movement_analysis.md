Status: Implemented 2026-08-26 (migration 156, not yet run by user; pg_cron must be enabled on Supabase).

# Inventory — Product Movement Analysis (Fast/Slow/Non-Moving) + Report Job Queue + Notification base

## Context

Fourteenth Inventory report — the classic Fast/Slow/Non-Moving inventory-health analysis, scoped to
finished-product SALES (not raw stock-ledger movement). Researched Odoo's FSN report (turnover-ratio
driven, F>3/S 1-3/N<1) and SAP's MC46/MC50 (days-since-last-issue / stock-depletion-over-time) before
designing — synthesis: SAP's cleanest signal (zero sales = unambiguously Non-Moving) + Odoo's ratio-driven
Fast/Slow split + SAKAL's own proven ledger-reconstruction technique (from `fn_stock_details`, migration
149) for an accurate Average Stock denominator.

This report aggregates over the ENTIRE product catalog (one row per product) — fundamentally different
from every prior report this session, which aggregate over transactions in a date range. For a 50,000-SKU
catalog this is genuinely heavy. Three designs were discussed and two rejected before landing here:
1. A single shared, mutable snapshot table, wholesale-replaced on refresh — rejected: two users
   requesting different periods at the same time would stomp each other's data.
2. A pure live query, no stored state — zero concurrency issues (Postgres MVCC), but blocks the
   requesting user's screen for however long the computation takes.
3. **Built**: a real job queue — submit params, pg_cron processes async, results stored per-job, user
   notified in-app when ready. Mirrors how SAP itself often runs MC46 as a background job for large plants.

## Piece A — Notification base (generic, reusable)

`ric_user_notifications`: user-scoped (RLS: client+company+user_id), `notification_type` (loose, no
CHECK — room for a future workflow/approval-notifications module), `title`/`message`/`link_route`,
`is_read`. `NotificationBell` widget (`lib/core/widgets/notification_bell.dart`) polls every 45s (no
realtime/push infra exists in this app — same tier as `MasterDataSyncIndicator`/`SyncStatusIndicator`,
which it now sits alongside in `TopBar`), shows an unread badge, marks read + navigates on tap.

## Piece B — Generic Report Job Queue (pg_cron-driven, reusable)

`ric_report_jobs` (RLS: user-wise — a user only sees their OWN jobs, per their explicit framing),
`fn_submit_report_job` (fast INSERT, returns immediately), `fn_process_pending_report_jobs` (pg_cron
worker, every minute, `SKIP LOCKED` claiming, dispatches by `report_key`, catches per-job exceptions so
one failure never aborts the batch, notifies on both success and failure), `fn_purge_old_report_jobs`
(nightly, 30-day retention — prevents unbounded growth now that jobs genuinely accumulate, unlike the
rejected shared-snapshot design). Any FUTURE heavy report just needs its own
`fn_run_<report>_job(job_id, params)` + one more `CASE` branch — queue/locking/retry/retention/
notification wiring are all shared already.

## Piece C — Product Movement Analysis itself

`ric_product_movement_snapshot` keyed by `job_id` (never shared/overwritten between jobs).
`fn_run_product_movement_analysis_job` — the heavy, once-per-job computation: one set-based `GROUP BY`
over `rim_product_location`/`v_sales_details_base`/`ril_stock_ledger` (no per-product loop). Classification:
```
qty_sold = 0        → Non-Moving
avg_stock = 0        → Fast-Moving  (sold out within the window — must precede the ratio check, since
                                      the ratio itself is NULL/undefined here, not falsely falling
                                      through to Slow-Moving)
ratio >= 3            → Fast-Moving  (Odoo's own default threshold)
else                   → Slow-Moving
```
`v_product_movement_analysis` — the ONLY thing a real user's report screen queries; joins back to
`ric_report_jobs` (RLS already scopes this to the current user's own jobs) and applies the standard
location-access convention. Runs UNSCOPED inside the job function itself (no JWT context under pg_cron —
confirmed by reading `v_sales_details_base`'s own location-access WHERE clause, which falls through to
"unrestricted" with no JWT, exactly what's needed to compute across the whole catalog once).

`is_saleable` filter defaults **unchecked** (not filtering) — `rim_product_flag_types` has no seeded
default across companies (confirmed by grep — it's a fully admin-defined, per-company table with zero
seed rows anywhere), so a default-checked filter would silently show zero rows for any company that never
configured this flag.

## Flutter — new engine capability: `fixedParams` on `ReportDataController`

The first report needing a hidden, non-filter-bar-editable scope key (`job_id`) threaded through every
fetch. Added `ReportDataController.fixedParams` (bare column → raw value), formatted per target type at
each call site exactly like the existing `ancestorKeys` group-drilldown mechanism already does
(`eq.<value>` for a VIEW fetch, `p_<key>=<value>` for a FUNCTION/RPC fetch) — `report_repository.dart`'s
`fetchTotals` gained a matching `extraParams` param. Generic, reusable by any future report with the same
need — zero effect on every existing report (defaults to `null`).

`ReportScreen` gained an optional `jobId` (from the route's `?job_id=` query param, threaded by
`app_router.dart`). When `reportKey == 'PRODUCT_MOVEMENT_ANALYSIS'` and no `jobId` is present, the normal
"Run Report" prompt is replaced by a Submit flow (`_buildSubmitJobPrompt`) — pick a date range, Submit
calls `fn_submit_report_job` directly via RPC and shows a confirmation; the user is expected to navigate
away and return via the notification bell once it's ready.

## Critical files
- `backend/migrations/156_product_movement_analysis.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — `IN-RPT-PMA` row.
- `lib/core/providers/notification_provider.dart`, `lib/core/widgets/notification_bell.dart` — Piece A.
- `lib/core/reporting/report_repository.dart` (`fetchTotals` extraParams),
  `lib/core/reporting/report_data_controller.dart` (`fixedParams` + `LAST_90_DAYS` preset),
  `lib/core/reporting/sakal_report_screen.dart` (`jobId` + Submit flow),
  `lib/core/router/app_router.dart` (`job_id` query param threading) — Piece C's Flutter side.
- `lib/core/reporting/sakal_report_table.dart` — BADGE coloring extended for Fast/Slow/Non-Moving.
- `lib/core/layout/top_bar.dart` — `NotificationBell` wired in.

## Verification (pending — user has not yet run migration 156 or enabled pg_cron)
1. `pg_cron` extension enabled on Supabase (Database → Extensions) before running the migration, or the
   `CREATE EXTENSION` line needs a re-run afterward.
2. Submitting a job shows the confirmation screen immediately; within ~1 minute a notification appears in
   the bell with a working link into the completed report.
3. Two jobs submitted back-to-back for different date ranges both complete independently, correct,
   non-overlapping results.
4. A product that sold out within the window (avg_stock=0, qty_sold>0) shows Fast-Moving, not a blank
   ratio silently defaulting to Slow-Moving.
5. Live filters (Location/Category/Brand/Product/Movement Category) narrow a completed job's rows
   instantly, without re-triggering computation.
6. After 30 days, an old job (and its snapshot rows, via `ON DELETE CASCADE`) are gone on the next nightly
   purge run.
7. `flutter analyze` clean — this is the first report touching several shared engine files
   (`report_data_controller.dart`, `report_repository.dart`, `app_router.dart`), worth a careful pass.

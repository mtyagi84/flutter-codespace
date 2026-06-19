# SAKAL ERP — Screen Development Checklist

A screen is **complete** only when every applicable item below is ticked.
Non-applicable items (e.g. Approve for a read-only report) must be marked N/A with a reason.

---

## A — Backend (PostgreSQL)

- [ ] SQL migration written and numbered (`NNN_description.sql`)
- [ ] All required columns present — every table has `client_id`, `company_id`, `location_id`, `is_active`, `is_deleted`, `created_at`, `created_by`, `updated_at`, `updated_by`
- [ ] Unique / composite constraints defined
- [ ] PG function written for complex reads (if PostgREST direct query is not enough)
- [ ] Migration tested in Supabase (run manually, no errors)
- [ ] PG function tested with sample data via Supabase SQL editor

---

## B — Flutter Data Layer

- [ ] Dart model class with `fromJson` / `toJson`
- [ ] Remote data source (`DioClient` calls to PostgREST / RPC)
- [ ] Local data source (Drift table + queries, for offline cache)
- [ ] Repository implementation wires remote + local
- [ ] Drift table registered in `app_database.dart` + `schemaVersion` incremented + migration step added

---

## C — State & Business Logic

- [ ] Riverpod provider(s) defined (no `setState` for shared state)
- [ ] Server-side filtering passed as query params (never fetch all then filter in Dart)
- [ ] Pagination implemented — `limit` + `offset` or cursor-based
- [ ] All providers use `autoDispose` unless data must survive navigation
- [ ] Input validation rules match DB constraints (not stricter, not looser)

---

## D — UI / UX Standards

- [ ] Page header: title + subtitle describing what the screen does
- [ ] Loading state: `CircularProgressIndicator` while data fetches
- [ ] Empty state: friendly message + action button (e.g. "No customers yet — Add one")
- [ ] Error state: red banner with message + Retry button
- [ ] Form fields have labels, hint text, and validation messages
- [ ] Destructive / irreversible actions have a confirmation dialog
- [ ] Snackbar feedback on every save / delete / approve action
- [ ] No hardcoded colours — use `AppColors.*` only
- [ ] No hardcoded strings that will be user-visible (use constants or l10n keys)
- [ ] Document numbers / sequences are system-generated, never user-editable

---

## E — Permissions

Wire every action button to the corresponding permission flag from `MenuFeature`:

| Permission flag       | Controls                                              |
|-----------------------|-------------------------------------------------------|
| `view_allowed`        | Screen is accessible; list and detail views visible   |
| `add_allowed`         | "New" / "Add" button visible; Save of a new record    |
| `edit_allowed`        | "Edit" button visible; Save of an existing record     |
| `approve_allowed`     | "Post" / "Approve" / "Reverse" button visible         |
| `copy_allowed`        | "Copy" / "Duplicate" button visible                   |
| `excel_upload_allowed`| "Import from Excel" button visible                    |

Rules:
- Button must be **hidden** (not just disabled) when the flag is false
- There is **no delete_allowed** — transactions are corrected via reversals (Credit Note / Debit Note); master data uses `is_active = false` via `edit_allowed`
- Route guard: if `view_allowed` is false and user navigates directly via URL, redirect to dashboard

---

## F — Pillar 1: Performance & Scalability

- [ ] List screens paginate — default page size 50, "Load more" or infinite scroll
- [ ] Search / filter sends params to server, not a Dart `.where()` on a full list
- [ ] Large dropdowns (countries, accounts, products) use searchable async dropdown — not a pre-loaded `DropdownButton` with hundreds of items
- [ ] No `SELECT *` — specify only the columns the screen needs
- [ ] Read-heavy screens use `STABLE` PG functions (allows query planning cache)

---

## G — Pillar 2: Mobile Responsiveness

Breakpoints used in SAKAL:

| Name    | Width        | Layout                         |
|---------|--------------|--------------------------------|
| Mobile  | < 600 px     | Single column, bottom nav      |
| Tablet  | 600–1024 px  | Two column where needed        |
| Desktop | > 1024 px    | Sidebar + split panel          |

- [ ] Tested at mobile width (600 px or narrower)
- [ ] Tested at tablet width (800 px)
- [ ] Tested at desktop width (1280 px)
- [ ] List+Detail screens: stacked on mobile, split panel on desktop
- [ ] All touch targets ≥ 48 × 48 px (buttons, checkboxes, list tiles)
- [ ] No horizontal overflow at any breakpoint
- [ ] Form dialogs / panels are resizable or scrollable on small screens

---

## H — Pillar 3: Offline Capability

- [ ] Master data readable offline (served from Drift cache, populated during last online sync)
- [ ] Write buttons (Add, Edit, Approve) are **hidden** when `session.offlineMode == true`
- [ ] New transactions created offline are enqueued via `SyncEngine.enqueue()` — not dropped
- [ ] Queued documents display a "Pending sync" badge / indicator
- [ ] No network call is made without a connectivity check or try-catch that degrades gracefully
- [ ] Offline banner (`OfflineBanner`) visible on every screen when in offline mode

---

## I — Final Verification

- [ ] Golden path tested end-to-end (create → view → edit → approve)
- [ ] Permission restriction tested (log in as user with no rights → screen/buttons hidden)
- [ ] Offline mode tested on native device (Android / desktop) — not on Flutter Web
- [ ] No console errors or warnings in debug mode
- [ ] `flutter analyze` passes with no errors on the new files
- [ ] Code committed and pushed; Codespace pulled and app rebuilt

---

*Last updated: 2026-06-20*
*Permission model: view / add / edit / approve / copy / excel_upload — no delete (reversals only, OHADA compliance)*

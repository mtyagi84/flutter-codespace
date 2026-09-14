# Phase D — Non-Functional Production-Readiness Checklist

Per the Production-Readiness Testing Roadmap: correctness alone (Phases A/B)
isn't "production ready." This checklist covers what's left — most items
here need an infrastructure decision or account-level confirmation only
the user (as the Supabase project owner) can make; a few were checked
directly against the codebase this session.

## 1. Environment separation
- [ ] **NOT DONE** — production should be a dedicated Supabase project,
  separate from the one QA testing (and now Phase B's throwaway second
  tenant) runs against. Currently everything — QA tenant, the 2 test
  tenants from the new-tenant starter kit verification, and Phase B's
  `QA Isolation Test Co` — lives in one project (`krygednbejwjuzlmmljn`).
  **Decision needed**: create a fresh Supabase project for production before
  any real customer data goes in, and re-run every migration (001-188)
  against it.

## 2. Migration deployment runbook
- [x] **Partially addressed this session** — every migration this session
  was deployed via a one-off Node.js `pg` script (connection string pasted
  fresh each time, per the project's deliberate never-persist-credentials
  rule). This works but isn't a standing tool.
- [ ] **Decision needed**: pick a standing approach for production
  deployments — installing `psql` directly, using the Supabase CLI
  (`supabase db push`), or continuing with the ad-hoc script. Whichever is
  chosen, document the exact command sequence somewhere durable (this file,
  or a new `backend/DEPLOY.md`) so it isn't re-derived from scratch each
  session.

## 3. Backup / restore
- [ ] **NOT verified this session** — needs checking directly in the
  Supabase dashboard (Database → Backups) that Point-in-Time Recovery or
  scheduled backups are actually enabled for the production project (not
  just assumed from the plan tier), AND that a restore has been test-run at
  least once. An untested backup is not a backup.

## 4. Monitoring
- [x] **Confirmed present in code**: `AppLogger` (`lib/core/utils/app_logger.dart`)
  captures uncaught errors app-wide via `runZonedGuarded` + `FlutterError.onError`
  + `PlatformDispatcher.instance.onError`, persists to a rotating local file
  (mobile/desktop) and an in-app `/dev/logs` viewer.
- [ ] **NOT confirmed**: whether anyone actually looks at these logs, or
  gets notified when a crash happens. `/dev/logs` requires opening the app
  and navigating to it manually — there is no push/alert mechanism. **Decision
  needed**: is manual log-checking acceptable for a 1-tenant soft-launch, or
  is a real alerting channel (even something as simple as a Slack webhook on
  a crash) worth adding before go-live?

## 5. Performance smoke test
- [ ] **NOT DONE** — every automated test this session ran against the QA
  tenant's small fixture dataset (a handful of products/customers/
  transactions). No test has confirmed the app behaves reasonably with a
  realistic transaction volume (hundreds to low thousands of rows per
  table) — report screens in particular (Stock Ledger, Account Ledger,
  registers) could behave very differently against real volume than
  against a fixture. **Suggested next step, doable without the UI**: a
  backend-only load test — script N GRNs/Sales Invoices via the same
  `BackendVerifier` RPC pattern already used everywhere in this suite, then
  time a few report queries before/after. Flagging as a candidate for a
  follow-up session rather than attempting it inline here, since it's a new
  kind of test (timing-based, not correctness-based) worth scoping
  separately.

## Summary
Items 1, 3, and 5 need a decision or an infrastructure step only the user
can take (create a project, check a dashboard setting, decide how much
performance-testing effort is worth it before a 1-tenant launch). Item 2 has
a working-but-ad-hoc answer already; item 4 is code-complete but has an open
question about whether manual log-checking is enough for now. None of these
block Phase E (soft-launch) outright, but environment separation (#1) is the
one item worth resolving BEFORE any real customer data is entered, since
migrating data out of a shared QA project afterward is far more painful than
starting clean.

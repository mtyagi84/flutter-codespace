# Stock Count Review — Test Plan
Route: `/inventory/stock-count-review` | Module: IN — Inventory | Feature Code: IN-CNR
Manager-side screen — deliberately online-only (needs a live view of other
counters' status and a live ledger-based system-qty computation). See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N"). Companion screen:
`stock_count.md`.

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CNR-C01 | Pick multiple SUBMITTED counts, same location | Select 2+ counts | Clubbed and compared against system stock as of a chosen `as_of_date` | High | Passed (1 count) | E2E: `New Review` on Main Store auto-defaulted Review Date/As Of Date to today, listed `CNT/MAIN/2026/00002` under "Submitted Stock Counts at this Location", checking it auto-saved a DRAFT review (`CNTR/MAIN/2026/00001`) and computed variance. Only 1 submitted count existed in the fixture — multi-count clubbing not separately exercised. |
| CNR-C02 | Variance uses ledger sum AS OF the date, not live current_stock | Post a transaction AFTER `as_of_date`, re-view | Zero effect on the computed variance | High | Not Started | |
| CNR-C03 | Untracked qty sums across sources | 2 counters both counted the same untracked product | Sums correctly (different zones, non-overlapping) | Med | Not Started | Needs 2+ submitted counts at the same location — fixture only had 1. |
| CNR-C04 | Serial uses DISTINCT, never double-counted | Same serial found in 2 overlapping counts | Counted as one unit | High | Not Started | Needs a serial-tracked product fixture. |
| CNR-C05 | Unknown serial excluded | A serial with zero ledger history at this location | Flagged `is_unknown_serial`, excluded from auto-adjustment | High | Not Started | Needs a serial-tracked product fixture. |
| CNR-A01 | Approve composes Stock Adjustment directly | Approve | Calls `fn_save_stock_adjustment` + `fn_approve_stock_adjustment` directly, inheriting cost-lookup/GL/negative-stock rules for free | High | Passed | DB-verified: Approve posted `rih_stock_adjustment_headers` row `ADJ/MAIN/2026/00002` (status APPROVED), line `adjust_flag='+'`, `base_qty=3.0000` (Counted 20 − System 17), `unit_cost=25.0000` (current cost pulled live, never re-entered — confirms the "+" line never trusts a user-typed cost, per the Stock Adjustment engine's own rule). GL posted under `ADJV` voucher: Dr `[3600001] Stock Account` 75.00 / Cr `[5800] Internal Transfers` 75.00 (3 × 25), and `rim_product_location.current_stock` for PRD-00002 at Main Store moved 17 → 20, matching the counted qty exactly. |
| CNR-A02 | What the manager sees IS what posts | Compare the preview grid to the actual posted adjustment | Numbers match exactly (both call the same `fn_compute_stock_count_variance`) | High | Passed | Preview grid showed Counted 20.00 / System 17.00 / Variance +3.00 for PRD-00002 before Approve; posted adjustment line's `base_qty=3.0000` matches exactly. |
| CNR-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Passed | Post-approve screenshot shows Save Draft/Approve buttons both gone from the header (only Print + bell/avatar remain), status badge reads APPROVED — consistent with every other approved-document screen in the app. |
| CNR-A04 | `IN-CNR` permission suffices, `IN-ADJ` not separately required | Approve with only `IN-CNR` | Succeeds (composition guard) | Med | Not Started | QA Administrator holds every permission — a restricted-user variant wasn't exercised this pass; the `source_doc_type IS NULL` guard itself is unit-verified by migration 112's own pgTAP pair per CLAUDE.md (not re-proven live here). |
| CNR-XS01 | Resulting adjustment traces back | Approve | `rih_stock_adjustment_headers.source_doc_type/no/date` populated correctly | Med | Passed | DB-verified: `ADJ/MAIN/2026/00002.source_doc_type='STOCK_COUNT_REVIEW'`, `source_doc_no='CNTR/MAIN/2026/00001'`. |
| CNR-XS02 | Stock Count Worksheet/Variance reports | Approve | Both reports reflect the final state (`reports/inventory_reports.md`) | High | Not Started | Deferred to the Inventory Reports pass (Phase 4, not yet started). |

### Real finding during this pass — not a bug
The Variance panel's own RPC (`fn_compute_stock_count_variance`) took close to 20 seconds to resolve on this small 2-product fixture (vs. the 6-8s settle time every other screen this session has needed) — long enough that an 8s wait looked identical to a permanently stuck spinner (confirmed via full network-request tracing: `getHeader`/`getSources`/the variance RPC all eventually returned HTTP 200, just slowly). Not logged as a bug — `_init()`'s own `try/finally`-equivalent (`if (mounted) setState(() => _loading = false)` at the end of the `try` block, with the same reset in `catch`) is written correctly and does resolve once the RPC returns; this is pure RPC latency, worth keeping an eye on only if it gets materially worse against a larger real catalog (the RPC aggregates `ril_stock_ledger`, which grows with real usage).

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`. CCC #8 (offline) explicitly does NOT apply
here — confirm this screen correctly requires connectivity, unlike its
Counter-side companion.

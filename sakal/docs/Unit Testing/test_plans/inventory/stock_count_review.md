# Stock Count Review — Test Plan
Route: `/inventory/stock-count-review` | Module: IN — Inventory | Feature Code: IN-CNR
Manager-side screen — deliberately online-only (needs a live view of other
counters' status and a live ledger-based system-qty computation). See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N"). Companion screen:
`stock_count.md`.

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CNR-C01 | Pick multiple SUBMITTED counts, same location | Select 2+ counts | Clubbed and compared against system stock as of a chosen `as_of_date` | High | Not Started | |
| CNR-C02 | Variance uses ledger sum AS OF the date, not live current_stock | Post a transaction AFTER `as_of_date`, re-view | Zero effect on the computed variance | High | Not Started | |
| CNR-C03 | Untracked qty sums across sources | 2 counters both counted the same untracked product | Sums correctly (different zones, non-overlapping) | Med | Not Started | |
| CNR-C04 | Serial uses DISTINCT, never double-counted | Same serial found in 2 overlapping counts | Counted as one unit | High | Not Started | |
| CNR-C05 | Unknown serial excluded | A serial with zero ledger history at this location | Flagged `is_unknown_serial`, excluded from auto-adjustment | High | Not Started | |
| CNR-A01 | Approve composes Stock Adjustment directly | Approve | Calls `fn_save_stock_adjustment` + `fn_approve_stock_adjustment` directly, inheriting cost-lookup/GL/negative-stock rules for free | High | Not Started | |
| CNR-A02 | What the manager sees IS what posts | Compare the preview grid to the actual posted adjustment | Numbers match exactly (both call the same `fn_compute_stock_count_variance`) | High | Not Started | |
| CNR-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| CNR-A04 | `IN-CNR` permission suffices, `IN-ADJ` not separately required | Approve with only `IN-CNR` | Succeeds (composition guard) | Med | Not Started | |
| CNR-XS01 | Resulting adjustment traces back | Approve | `rih_stock_adjustment_headers.source_doc_type/no/date` populated correctly | Med | Not Started | |
| CNR-XS02 | Stock Count Worksheet/Variance reports | Approve | Both reports reflect the final state (`reports/inventory_reports.md`) | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`. CCC #8 (offline) explicitly does NOT apply
here — confirm this screen correctly requires connectivity, unlike its
Counter-side companion.

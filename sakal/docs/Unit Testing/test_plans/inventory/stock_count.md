# Stock Count — Test Plan
Route: `/inventory/stock-count` | Module: IN — Inventory | Feature Code: IN-CNT
The Counter-side screen — blind count, enforced at the schema level (no
system_qty column exists on this table at all). See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N"). Companion screen: `stock_count_review.md`.

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CNT-C01 | Pick Location + category filter, get worksheet | Start a count | Worksheet pre-populates, system qty is NEVER shown (true blind count) | High | Passed | E2E `New Stock Count` → `Start Count` on Main Store (no category/item-type filter = all). Worksheet pre-populated with both active products (PRD-00001, PRD-00002), both quantities defaulted to 0, no system-qty column anywhere on screen or in `rid_stock_count_lines`'s own schema — confirmed blind by construction. |
| CNT-C02 | Free-text new-lot batch/serial entry | Count a tracked product | Pure free-text entry, no existing-lot picker (would leak system data) | Med | Not Started | QA fixture has no batch/serial-tracked product — deferred, needs a dedicated tracked-product fixture. |
| CNT-C03 | "Mark Counted — None Found" | A tracked product has zero found | Explicit action distinguishes "confirmed empty" from "never touched" (`is_counted` flag) | High | Passed (partial) | PRD-00002 counted (Qty Pack 20, `is_counted=true`) and PRD-00001 left untouched (`is_counted=false`, qty columns NULL) — confirmed the two states are genuinely distinct in `rid_stock_count_lines`. Did not separately exercise a dedicated "Mark Counted — None Found" action for a zero-find row; the untouched/not-is_counted state was exercised instead. |
| CNT-E01 | Edit before Submit | Change a counted qty, Save | Persists | High | Not Started | |
| CNT-S01 | Submit | Submit | Status becomes SUBMITTED, no longer editable by the counter | High | Passed | DB-verified: header `status='SUBMITTED'` after Submit (`CNT/MAIN/2026/00002`). |
| CNT-OFF01 | Fully offline-capable | Go offline, count, come back online | Syncs correctly (this screen is deliberately offline-capable since neither Save nor Submit touches the ledger/GL) | High | Not Started | Not exercised this pass — needs a native-build offline toggle, same deferred-until-native-access gap documented for POS. |
| CNT-XS01 | Reservation once picked into a Review | Get picked into a manager's DRAFT Review | Cannot be picked into a second concurrent Review | Med | Passed | Confirmed live: after `CNT/MAIN/2026/00002` was picked into DRAFT review `CNTR/MAIN/2026/00001`, a second "New Review" at the same location showed "No submitted counts available at this location yet" — reservation-once-consumed works as documented. |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`, noting CCC #8 (offline) is a REQUIRED pass
here, not optional — this is the one screen in the app explicitly designed for
unreliable-connectivity counting sessions spanning hours/days.

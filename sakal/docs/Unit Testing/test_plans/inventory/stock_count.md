# Stock Count — Test Plan
Route: `/inventory/stock-count` | Module: IN — Inventory | Feature Code: IN-CNT
The Counter-side screen — blind count, enforced at the schema level (no
system_qty column exists on this table at all). See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N"). Companion screen: `stock_count_review.md`.

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CNT-C01 | Pick Location + category filter, get worksheet | Start a count | Worksheet pre-populates, system qty is NEVER shown (true blind count) | High | Not Started | |
| CNT-C02 | Free-text new-lot batch/serial entry | Count a tracked product | Pure free-text entry, no existing-lot picker (would leak system data) | High | Not Started | |
| CNT-C03 | "Mark Counted — None Found" | A tracked product has zero found | Explicit action distinguishes "confirmed empty" from "never touched" (`is_counted` flag) | High | Not Started | |
| CNT-E01 | Edit before Submit | Change a counted qty, Save | Persists | High | Not Started | |
| CNT-S01 | Submit | Submit | Status becomes SUBMITTED, no longer editable by the counter | High | Not Started | |
| CNT-OFF01 | Fully offline-capable | Go offline, count, come back online | Syncs correctly (this screen is deliberately offline-capable since neither Save nor Submit touches the ledger/GL) | High | Not Started | |
| CNT-XS01 | Reservation once picked into a Review | Get picked into a manager's DRAFT Review | Cannot be picked into a second concurrent Review | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`, noting CCC #8 (offline) is a REQUIRED pass
here, not optional — this is the one screen in the app explicitly designed for
unreliable-connectivity counting sessions spanning hours/days.

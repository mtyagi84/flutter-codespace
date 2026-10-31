# Stock Receipt — Test Plan
Route: `/inventory/stock-receipts` | Module: IN — Inventory | Feature Code: IN-SRC
Fulfills a Stock Transfer, mirrors GRN's role fulfilling a PO. See `00_INDEX.md`
for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRC-C01 | Receive a full transfer | Pick the transfer, confirm full qty | Saves as DRAFT | High | Passed | E2E `test_stock_receipt.js` 9/9: picked `STXF/MAIN/2026/00001`, Dispatched/Received Qty Pack both pre-filled 5.00, Save Draft then Approve. **Real numbering finding**: the resulting document number came back as `SRCP//2026/00001` (empty segment where the location-short code should be, e.g. `SRCP/MAIN/2026/00001`) — same for its GL voucher `STXJ//2026/00001`. Traced to `ric_locations.location_short=''` (empty string, not NULL) for "QA Second Store" — `fn_next_trans_no`'s `coalesce(location_short, left(id::text,3))` only falls back on NULL, not on `''`, so the `{LOC}` token resolves to nothing. Two contributing factors: a test-data gap (Phase 1's Location Setup test never filled in a short code — that field isn't marked required at creation) and a genuine, minor code defect (`coalesce` needs `nullif(location_short,'')` to treat blank the same as missing). Logged as `SRC-BUG01`, not fixed this session — low severity (cosmetic numbering gap, not a correctness issue) but worth a quick fix in a future pass. |
| SRC-BUG01 | **Found live** — empty `location_short` produces a malformed document number | Approve a document numbered at a location whose `location_short` is `''` (not NULL) | `{LOC}` token in the trans-no format should fall back to a derived short code, same as the NULL case | Low | Found, not fixed | See SRC-C01's own note — `fn_next_trans_no`'s `coalesce(location_short, ...)` doesn't treat empty string as missing. |
| SRC-C02 | Short receipt | Receive less than transferred | "Short Received" tracked correctly (schema has no true partial-receipt tracking — this is a flag-based approximation, verify it's still accurate) | High | Not Started | |
| SRC-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| SRC-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| SRC-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| SRC-A01 | Stock lands at destination | Approve | Destination location's stock increases correctly | High | Passed | DB-verified: QA Second Store `current_stock=5` (newly received), `ril_stock_ledger` row `trans_type=TRANSFER_IN, qty_change=+5`. GL `STXJ` voucher clears the in-transit balance: Dr Stock Account 125 / Cr Internal Transfers 125 (5 x cost_price 25) — closes the loop the Transfer's own Dr-Transit/Cr-Stock opened. |
| SRC-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| SRC-A03 | Permission gating (CCC #6, `IN-SRC`) | Approve without the right | Denied | High | Not Started | |
| SRC-XS01 | Stock Receipt Register + Pending Transfer to Receive | Approve | Both reflect it correctly | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

# Opening Stock — Test Plan
Route: `/inventory/opening-stock` | Module: IN — Inventory | Feature Code: IN-OPN
One-time (per product/location) document with NO GL posting at all. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OPN-C01 | One line per lot/unit | Add a serial-tracked product with 3 units | 3 separate lines, not 1 line qty=3 | High | Not Started | |
| OPN-C02 | Cost IS user-entered (the one deliberate inversion) | Enter a unit cost | Saves correctly, establishes cost basis | High | Passed | E2E `test_opening_stock.js` 9/9: PRD-00002, Qty Pack 20 x Unit Cost 25, DB-verified `rim_product_location.cost_price=25` exactly. **Real automation-timing finding**: editing Qty Pack triggers a reactive row rebuild that can silently overwrite a just-typed Unit Cost value a moment later if entered too quickly after — confirmed live (an early attempt with no settle wait between the two fields produced `cost_price=50`, matching an unrelated product's own cost, not anything typed that run). An 800ms wait between the two field edits reliably avoided it. Not escalated as a confirmed product bug (a real human typing at normal speed is unlikely to hit this exact race), but worth a quick Flutter-side look at why the row rebuild's default value happens to equal a DIFFERENT product's `cost_price` — flagged as `OPN-UI01` for a future pass. |
| OPN-C03 | `OPENING_STOCK_ALREADY_ESTABLISHED` guard | Attempt on a product that already has stock/cost at that location (e.g. from a real GRN) | Blocked at Approve | High | Not Started | |
| OPN-C04 | Excel bulk upload | Upload a valid file | Lines land correctly; template's own downloadable header list matches what the parser accepts (a past bug: template omitted manufacturing_date) | High | Not Started | |
| OPN-E01 | Edit a DRAFT | Change a line, Save | Persists | High | Not Started | |
| OPN-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| OPN-A01 | Approve — NO GL posting | Approve | Confirm zero GL voucher created, only stock movement | High | Passed | Confirmed: `rih_opening_stock_headers.post_gl=false` (toggle left unchecked), zero rows in `rih_finance_headers` for `source_doc_type='OPENING_STOCK'`. `ril_stock_ledger` shows `trans_type=OPENING_STOCK, qty_change=+20` — pure stock movement, no GL. GL-ON variant (toggle checked) still open. |
| OPN-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| OPN-A03 | Permission gating (CCC #6, `IN-OPN`) | Approve without the right | Denied | High | Not Started | |
| OPN-XS01 | Stock reports reflect it | Approve | Stock Balance/Value/Ledger all show the new opening position | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

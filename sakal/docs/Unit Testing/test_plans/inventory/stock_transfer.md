# Stock Transfer — Test Plan
Route: `/inventory/transfers` | Module: IN — Inventory | Feature Code: IN-TRF
SAME_BOOK vs INTER_ENTITY depends on `ric_companies.inter_location_model` +
`location.group_id`. See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-C01 | SIMPLE model — pure stock movement | Transfer between two locations under SIMPLE | Pure stock transfer, no financial posting | High | Passed (correction — see Bug Ref) | E2E `test_stock_transfer.js`, AGAINST_REQUEST mode, Main Store → QA Second Store (both `group_id=NULL`, SIMPLE inter-location model). **Real correction to this row's own expectation**: a SAME_BOOK/SIMPLE transfer is NOT financial-posting-free — it posts a real `STXJ` journal through a dedicated `STOCK_IN_TRANSIT_ACCOUNT` link type (Dr Stock in Transit / Cr Stock Account at source on Transfer Approve, reversed at Receipt). "Pure stock movement" describes the absence of a party invoice (no inter-entity Customer/Supplier posting), not the absence of GL entirely — the GR/IR-style in-transit clearing pattern applies here just as it does for GRN→Bill. | `STOCK_IN_TRANSIT_ACCOUNT` was never configured on this fresh tenant — see STR-BUG01 below. |
| TRF-C02 | INTER_ENTITY, same group | Transfer within the same location group | Pure stock transfer, no financial posting (same as SIMPLE) | High | Not Started | |
| TRF-C03 | INTER_ENTITY, different group | Transfer across groups | Inter-entity invoice created using each group's own customer/supplier account | High | Not Started | |
| TRF-C04 | DIRECT mode | Fresh product entry | Barcode/tracked-product entry works (CCC #9/#10) | Med | Not Started | |
| TRF-C05 | AGAINST_REQUEST mode | Consolidate a Transfer Request | Lines/barcode carried forward from the request, no fresh scan | Med | Passed | Confirmed: picking `STRQ/MAIN/2026/00001` auto-filled To Location (QA Second Store) and the line's Qty Pack (5.00) with no re-entry needed. |
| STR-BUG01 | **Found live** — Stock in Transit Account link never auto-wired, no friendly setup path | Approve a SIMPLE-model transfer on a fresh tenant with no Account Link Setup done for Stock in Transit | Blocked with "No Stock in Transit Account resolved for product [...]." — not itself a bug (correct validation), but the account genuinely needs manual Configure via Account Link Setup, unlike `STOCK_ACCOUNT`/`PURCHASE_ACCRUAL_ACCOUNT` which auto-wire for new tenants (per `project_new_tenant_starter_kit`). | Med | Found, config fix applied | Configured live via Account Link Setup → Stock in Transit Account → Company-wide → `[5800] Internal Transfers`, then the transfer approved successfully. **A second, more interesting bug found in the SAME flow**: switching the Level selector (Company-wide → something else → back to Company-wide) soft-deletes the existing `rim_account_link_defaults` row, and re-saving then fails with a raw `duplicate key value violates unique constraint "uq_account_link_defaults_company"` — the unique constraint is NOT partial on `is_deleted=false`, so a soft-deleted row still blocks a fresh insert. This is the EXACT bug class CLAUDE.md already documents for `uq_users_client_username` ("plain non-partial UNIQUE constraint means soft-deleted masters must be REUSED, not re-created") — `rim_account_link_defaults` needs the same fix (either a partial unique index, or the save logic reactivating a soft-deleted row instead of inserting). Worked around this session by directly `UPDATE`-ing the row's `is_deleted` back to `false`; a proper migration fix is recommended for a future session, same pattern as the `uq_users_client_username` precedent. |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| TRF-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| TRF-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| TRF-P01 | Print | Print an approved transfer | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-A01 | Stock leaves source location | Approve | Source location's stock decreases correctly | High | Passed | DB-verified: Main Store `current_stock=17` (22-5), `ril_stock_ledger` row `trans_type=TRANSFER_OUT, qty_change=-5`; GL `STXJ/MAIN/2026/00001` posted: Dr Stock in Transit / Cr Stock Account (per `[5800] Internal Transfers`, the test config). |
| TRF-A02 | Never restricted from external transactions | Confirm a location involved in a transfer can still do POs/Sales freely | No restriction leaks across | Med | Not Started | |
| TRF-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| TRF-A04 | Permission gating (CCC #6, `IN-TRF`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact (Convert-to-Stock Receipt is the natural next step)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-XS01 | Stock Transfer Register + Pending Transfer to Receive | Approve, then receive via Stock Receipt | Moves correctly between the two reports | High | Not Started | |
| TRF-XS02 | Short-received flagged | Receive less than transferred | Short-received flag/pending qty shown correctly on the report side | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

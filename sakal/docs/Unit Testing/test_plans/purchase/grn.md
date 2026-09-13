# Goods Receipt (GRN) — Test Plan
Route: `/purchase/grn` | Module: PR — Purchase | Feature Code: PR-GRN
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N"). This is the screen
that already caught the SELLING/MID exchange-rate bug (`25b4806`) via manual +
automated testing this session — the multi-currency test cases below are not
theoretical, they're the proven regression check.

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRN-C01 | Direct GRN (no PO) | Pick supplier, add lines, Save | Saves as DRAFT | High | Not Started | |
| GRN-C02 | Against-PO, single PO | Pick a PO, consolidate its lines | Lines pre-fill with PO qty/rate, rate defaults from PO's own confirmed rate | High | Not Started | |
| GRN-C03 | Against-PO, multiple POs same currency | Consolidate 2+ POs | All lines correct, one currency | Med | Not Started | |
| GRN-C04 | Foreign-currency GRN | Receive in a currency ≠ base | `trans_currency` = GRN's own currency on every line, NOT hardcoded to base (a real bug once fixed in migration 051) | High | Not Started | |
| GRN-C05 | Batch/serial new-lot entry | Receive a tracked product | Free-text batch/serial + expiry/manufacturing date entry (CCC #10) | High | Not Started | |
| GRN-C06 | Charges with ADD/DEDUCT nature | Add both charge types | Dr/Cr direction flips correctly for DEDUCT | High | Not Started | |
| GRN-C07 | Tax deferred, never posted at GRN | Receive with a tax group set | NO VAT line posts at GRN — only tax-exclusive stock/accrual (GR/IR pattern) | High | Not Started | |

## Edit / View
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRN-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| GRN-E02 | Immutability (CCC #5) | Approve, attempt edit | Blocked | High | Not Started | |
| GRN-V01 | Reload matches saved state | Save, reopen | Matches, including batch/serial allocations | High | Not Started | |

## List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRN-L01 | Filter by status/billed | Apply filter | Correct subset | Med | Not Started | |
| GRN-P01 | Print | Print an approved GRN | Renders correctly with "Received By" signature | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRN-A01 | Stock + Accrual post correctly | Approve | Dr Stock (tax-exclusive), Cr Purchase Accrual — verify amounts exactly | High | Not Started | |
| GRN-A02 | **Multi-currency regression: cost basis uses the Exchange Rate (MID), not Selling** | Receive foreign-currency stock, note the cost_price saved | `rim_product_location.cost_price` derived using the SAME rate a later Sales Invoice's COGS will use — see `finance_masters.md` EX-03 for the paired check | High | Not Started | This is the exact class of bug fixed in `25b4806` |
| GRN-A03 | New-tenant auto-wired accounts (2026-09-13 fix) | Approve on a freshly-registered tenant with zero manual Account Link Setup | Succeeds immediately — Stock/Purchase Accrual accounts already resolved | High | Not Started | |
| GRN-A04 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| GRN-A05 | Permission gating (CCC #6, `PR-GRN`) | Approve without the right | Denied | High | Not Started | |
| GRN-A06 | Negative stock rules for batch/serial | Attempt an outward movement that would take a batch negative | Blocked, full stop, regardless of `allow_negative_stock` flags | High | Not Started | N/A for GRN itself (inward only) — verify this is correctly NOT applicable here, only relevant for outward-movement screens |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRN-XS01 | GRN Register + Pending to Bill | Approve | Both reflect it (`reports/purchase_reports.md`) | High | Not Started | |
| GRN-XS02 | Stock reports | Approve | Stock Balance/Ledger reflect the inward movement and correct cost | High | Not Started | |
| GRN-XS03 | **Full pilot: GRN → Sales Invoice zeroes stock/COGS exactly** | Receive 100 units, then sell all 100 via Sales Invoice | Net stock movement = 0, net Stock-account GL movement = 0 (base currency) — the proven regression check, confirmed once via `integration_test` smoke test 2026-09-13 | High | Not Started | See `sales/sales_invoice.md` INV-XS01 |

## Convert-to-Purchase Invoice (billing)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRN-CV01 | Bill a single GRN | Create a Purchase Invoice against this GRN | GR/IR loop closes correctly — see `purchase_invoice.md` | High | Not Started | |
| GRN-CV02 | Reservation prevents double-billing | Attempt to bill the same GRN twice (two draft invoices) | Second attempt blocked | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

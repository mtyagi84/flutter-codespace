# Sales Order — Test Plan
Route: `/sales/orders` | Module: SL — Sales | Feature Code: SL-SO
Spec doc: `docs/screens/sales_order.md` | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").
Existing informal notes: `docs/Unit Testing/Sales Quotation.md` has 19 free-text notes for Sales Order — fold in as regression cases.

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-C01 | DIRECT mode, priced live | Create fresh, pick product, price auto-fills from `fn_get_active_price` | Correct currency-converted price used | High | Not Started | |
| SO-C02 | AGAINST_QUOTATION mode | Convert a quotation | Every priced field frozen server-side; client-supplied rate/discount ignored even if sent | High | Not Started | |
| SO-C03 | Price override with governance | As a user with `can_override_price` + `max_discount_percent`, exceed the cap | Blocked server-side even if UI somehow allowed it | High | Not Started | |
| SO-C04 | Available-stock hint shown ungated | Add a line | Available qty shown regardless of `can_view_cost_price` (it's operational, not sensitive) | Low | Not Started | |
| SO-C05 | Cost price gated | As a user without `can_view_cost_price` | Cost price hidden on the line | Med | Not Started | |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| SO-E02 | Immutability (CCC #5) | Approve, then attempt edit | Blocked | High | Not Started | |

## View / Resume Draft
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-V01 | Reload matches saved state | Save, reopen | Matches, including frozen AGAINST_QUOTATION fields | High | Not Started | |

## List Screen
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-L01 | Filter by status | Filter | Correct subset | Med | Not Started | |

## Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-P01 | Print includes ship-to/bill-to, Incoterm, Payment Term | Print | All present and correct | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-A01 | Button state after Approve (CCC #4) | Approve | Buttons disable correctly | High | Not Started | |
| SO-A02 | Permission gating (CCC #6, `SL-SO`) | Approve without the right | Denied | High | Not Started | |

## Cancel
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-X01 | Cancel with mandatory reason | Attempt cancel with no reason | Blocked — reason is required | High | Not Started | |
| SO-X02 | Cancel a partially-invoiced order | Cancel after one partial invoice | Verify actual supported behavior (remaining qty handling) | Med | Not Started | |

## Convert-to-Sales Invoice
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-CV01 | Whole-document conversion | Convert to Sales Invoice | Only whole-document consumption — no partial; source `NOT EXISTS` row-lock check prevents double-invoicing | High | Not Started | |
| SO-CV02 | Double-conversion attempt | Try to invoice the same order twice (e.g. two browser tabs) | Second attempt blocked by the row-locked check | High | Not Started | |
| SO-CV03 | Cancelling the invoice re-opens the order | Cancel a DRAFT invoice created from this order | Order becomes available for invoicing again (no separate "un-reserve" step needed) | Med | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SO-XS01 | Sales Order Register + Open Sales Orders | Approve/convert | Both reports reflect it correctly | High | Not Started | |
| SO-XS02 | Prospect conversion side-effect | Convert a prospect-sourced order | New `rim_accounts` customer row created correctly (same as Quotation's own conversion) | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.

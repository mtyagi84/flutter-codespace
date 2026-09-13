# Sales Invoice ("Quick Invoice") — Test Plan
Route: `/sales/invoices` | Module: SL — Sales | Feature Code: SL-INV
Spec doc: `docs/screens/sales_invoice.md` (has its own §6 chronological bug list and §7 cross-cutting checklist — read before testing, this screen has the deepest documented history in the app) | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-C01 | DIRECT, Cash sale | Direct mode, Cash, pick product | Posts to the cashier's own `cash_customer_id`, forces invoice currency to local | High | Not Started | |
| INV-C02 | DIRECT, Credit sale | Direct mode, Credit, pick customer | Customer-DR/Sales-CR posts correctly | High | Not Started | |
| INV-C03 | AGAINST_QUOTATION / AGAINST_ORDER | Convert either | Every line re-derived server-side, client payload ignored | High | Not Started | |
| INV-C04 | No Price Master row → Override Price | Add a line with no price configured | `PRICE_NOT_CONFIGURED` triggers Override UI, reason required | High | Not Started | |
| INV-C05 | Batch/serial auto-allocation (FEFO) | Add a tracked product under IMMEDIATE dispatch | Auto-fills FEFO-ordered batches/serials; "Reset to FEFO" button works after a manual edit | High | Not Started | |
| INV-C06 | Deferred dispatch — no COS voucher yet | Save a deferred-dispatch invoice | No `COS` voucher posted; stock unaffected until actual dispatch | High | Not Started | |
| INV-C07 | Charges — DIRECT mode freely editable | Add an ad-hoc delivery charge | Apportions and posts to the charge's own `gl_account_id`, plus tax leg if taxable | High | Not Started | |
| INV-C08 | Charges — AGAINST_QUOTATION/ORDER carried verbatim | Convert a source with a charge on it | Charge copied exactly, client's own charge payload ignored | High | Not Started | |
| INV-C09 | Offline create (Direct, Cash or Credit only) | Go offline, create an invoice | Queues via SyncEngine; lands in real DRAFT status once synced, invoice_no assigned then | High | Not Started | |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-E01 | Resume a DRAFT with tracked lines | Save, reopen | Existing batch/serial allocations AND live candidate list both reload (a real bug found before, confirm still fixed) | High | Not Started | |
| INV-E02 | Save is Approve — no separate DRAFT-then-approve for online path | Save online | Chains `fn_save_sales_invoice` + `fn_approve_sales_invoice` in one click | High | Not Started | |

## View / Resume Draft
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-V01 | Manager Review shows a synced offline DRAFT | Sync an offline invoice | Appears on Manager Review with a live stock-position preview | High | Not Started | |

## List Screen
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-L01 | Filter by sale type / status | Apply filters | Correct subset | Med | Not Started | |

## Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-P01 | POS receipt template, no signature block | Print a cash sale | Renders as a receipt correctly (deliberately no signature block by default) | Med | Not Started | |

## Approve / Post
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-A01 | Two-voucher split (SI + COS) | Approve an immediate-dispatch invoice in a foreign currency | SI voucher in invoice currency, COS voucher in base currency, both correct | High | Not Started | |
| INV-A02 | Manager Review approve (offline-synced) | Approve from Manager Review | Same `fn_approve_sales_invoice` runs; a stock-vanished race is caught and shown inline, not silently posted | High | Not Started | |
| INV-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable correctly | High | Not Started | |
| INV-A04 | Permission gating (CCC #6, `SL-INV`) | Approve without the right | Denied | High | Not Started | |

## Cancel
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-X01 | Cancel only from DRAFT | Attempt to cancel an APPROVED invoice | Blocked — no reversal path in this build, that's Sales Return's job | High | Not Started | |

## Cross-Screen Impact — this is the pilot flow already verified once via automation
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-XS01 | Stock/COGS zero out exactly after buy-then-sell-all | GRN 100 units, then Sales Invoice all 100 units | `ril_stock_ledger` net qty_change = 0, Stock account's net `base_amount` = 0 — this is the exact regression check for the SELLING/MID bug (`25b4806`) | High | Not Started | Already confirmed via `integration_test` smoke test 2026-09-13 for the underlying mechanism; full chained flow automation still blocked (see `reference_automation_capabilities_2026_09_13.md`) — do this one manually for now |
| INV-XS02 | Sales Register + Gross Profit reports | Approve | Both reflect the invoice correctly | High | Not Started | |
| INV-XS03 | Pending Bills (Credit sale) | Approve a credit sale | Appears in Pending Bills Register/by Customer | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`, PLUS this screen's own `docs/screens/sales_invoice.md` §7 checklist (barcode/loose-qty/batch-serial/negative-stock/FEFO/charges) — the two overlap but the spec doc's is more detailed for this specific screen.

# Sales Invoice ("Quick Invoice") — Test Plan
Route: `/sales/invoices` | Module: SL — Sales | Feature Code: SL-INV
Spec doc: `docs/screens/sales_invoice.md` (has its own §6 chronological bug list and §7 cross-cutting checklist — read before testing, this screen has the deepest documented history in the app) | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| INV-C01 | DIRECT, Cash sale | Direct mode, Cash, pick product | Posts to the cashier's own `cash_customer_id`, forces invoice currency to local | High | Passed | E2E `2026-10-25`: `SI/MAIN/2026/00002`/`00003` both Direct+Cash, currency correctly forced to CDF (local), Customer/Location auto-filled from `ric_user_quick_invoice_setup` once configured (see QIS-BUG01 below). |
| INV-C02 | DIRECT, Credit sale | Direct mode, Credit, pick customer | Customer-DR/Sales-CR posts correctly | High | Passed | Covered via the AGAINST_ORDER/Credit path (INV-C03) — `SI/MAIN/2026/00001` posted Dr Customer 500/Cr Sales 500 correctly. Direct+Credit specifically not separately re-tested this pass. |
| INV-C03 | AGAINST_QUOTATION / AGAINST_ORDER | Convert either | Every line re-derived server-side, client payload ignored | High | Passed | AGAINST_ORDER tested: `SI/MAIN/2026/00001` from `SO/MAIN/2026/00001`, Credit — line correctly re-derived (Qty 5, Rate 100, Amount 500). DB-verified GL: Dr `[4110001]` Customer 500 / Cr `[7010]` Sales of Goods 500 (SLS voucher); Dr `[6100001]` Cost of Sales 125 / Cr `[3600001]` Stock Account 125 (COS voucher, 5×25 cost basis). Stock dispatched immediately (20→15) since `quick_invoice_dispatch_stock` was still `true` at that point. AGAINST_QUOTATION not separately re-tested (Sales Order's own AGAINST_QUOTATION path already proven; the remaining re-derivation logic is identical). |
| INV-C04 | No Price Master row → Override Price | Add a line with no price configured | `PRICE_NOT_CONFIGURED` triggers Override UI, reason required | High | Passed | Confirmed live: adding PRD-00001 with no Price Master row and no `can_override_price` grant produced "no active price configured, and you are not authorized to override it." After granting `can_override_price=true` via `ric_user_sales_controls`, the Rate field became editable and a new "Override Price" checkbox + per-line "Override Reason" column appeared — entering a rate with no reason blocked Save ("Line 1: enter a reason for overriding the price."); supplying both saved correctly. |
| INV-C05 | Batch/serial auto-allocation (FEFO) | Add a tracked product under IMMEDIATE dispatch | Auto-fills FEFO-ordered batches/serials; "Reset to FEFO" button works after a manual edit | High | Not Started | |
| INV-C06 | Deferred dispatch — no COS voucher yet | Save a deferred-dispatch invoice | No `COS` voucher posted; stock unaffected until actual dispatch | High | Passed | Toggled `ric_companies.quick_invoice_dispatch_stock=false`, created `SI/MAIN/2026/00002`/`00003` — both APPROVED with `stock_dispatch_mode='DEFERRED'`, no COS voucher posted at approve time, `rim_product_location.current_stock` unchanged, `v_sales_invoice_delivery_status.delivery_status='PENDING'`. COS voucher confirmed to post later, correctly, at actual Sales Delivery approve time (see `sales_delivery.md`). |
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
| INV-A01 | Two-voucher split (SI + COS) | Approve an immediate-dispatch invoice in a foreign currency | SI voucher in invoice currency, COS voucher in base currency, both correct | High | Passed | `SI/MAIN/2026/00001` (immediate dispatch, USD): `SLS` voucher Dr Customer 500/Cr Sales 500; `COS` voucher Dr Cost of Sales 125/Cr Stock Account 125 — both correctly balanced, base_amount matches on every line. |
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

### Real finding — Quick Invoice Setup can get permanently locked before it's ever configured
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QIS-BUG01 | **Found live** — a user who makes a Quick Invoice before `ric_user_quick_invoice_setup` is ever configured for them gets locked out of configuring it afterward | On a fresh tenant, make a Credit-mode Quick Invoice without ever visiting Quick Invoice Setup, then try to configure it | Setup should still be configurable (nothing was ever set to "lock") | Med | Found, not fixed | The QA Administrator's first invoice (`SI/MAIN/2026/00001`, AGAINST_ORDER + Credit) saved successfully with `location_id` resolved some other way (confirmed via `v_sales_invoice_delivery_status`/the invoice's own stored `location_id` — Main Store), **not** from `ric_user_quick_invoice_setup` (confirmed: zero rows existed for this user at that point). But the next visit to Quick Invoice Setup showed "Locked — this user has already made 1 Quick Invoice(s). Setup can no longer be changed." with every field blank — meaning Setup can never be configured for this user through the UI again, yet it was never configured in the first place. This also explains why the entry screen's own Location field appeared permanently stuck at "—" with no working dropdown on Cash-mode attempts (its value binds to the now-permanently-unconfigurable Setup row). Worked around by inserting the `ric_user_quick_invoice_setup` row directly via SQL (test-data fix, not a product fix) — not fixed in the app. **Likely root cause**: the "lock after first use" check counts *any* invoice the user has made, not whether Setup was ever actually saved — the lock should probably only apply once a real Setup row exists to protect. |

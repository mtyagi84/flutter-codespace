# Sales Order
## Screen Requirement Document

**Module:** Sales (third screen — after Sales Quotation and Sales Price Master)
**Route:** `/sales/orders`
**Status:** 📝 Design agreed — not yet built

---

## 1. Screen Name

**Sales Order** — two screens:
- **Sales Order List** — browse/search/filter existing orders
- **Sales Order Entry** — create/edit/approve a single order, in one of two modes

---

## 2. Screen Description

### Why this screen is needed
A Sales Order is the customer's confirmed commitment to buy — the point where a quotation (still a negotiable proposal) or a walk-in/phone request becomes a real order the business intends to fulfill. It exists so the business can:
- Record exactly what was promised (product, quantity, price, charges) as a single frozen reference for the delivery/invoicing team to fulfill against.
- Track fulfillment progress (how much of an order has been delivered/invoiced so far) across possibly multiple future deliveries.
- Enforce pricing discipline — price comes from Sales Price Master, not from a salesperson's memory, with a controlled, permission-gated exception path rather than an open text field.

### Where it sits in the ERP
Sales Order plays the same role on the sales side that **Purchase Order** plays on the purchase side: a pre-commitment document with **zero stock and zero GL impact**. Real inventory/financial effect only happens later, at a future Sales Delivery/Invoice screen (mirroring GRN's role on the purchase side).

```
Sales Quotation ──(Convert)──▶ Sales Order ──▶ Sales Delivery / Sales Invoice ──▶ GL + Stock
                                    ▲
Direct entry (no quotation) ───────┘
```

Two independent ways to reach a Sales Order:
- **Direct** — no prior quotation; the user fills in customer, products, and (locked) prices directly.
- **Against Quotation** — converts exactly one existing quotation (its own negotiated prices, discounts, and tax are frozen and copied in) into a real order.

---

## 3. Screen Layout

### 3.1 List Screen

Uses the shared `SakalAdaptiveList` widget — desktop table / mobile cards.

| Column | Notes |
|---|---|
| Order No | e.g. `SO/KIN/2026/00001` |
| Date | Order date |
| Mode | DIRECT / AGAINST QUOTATION badge |
| Customer | `[code] name` |
| Source Quotation | Quotation No, blank for Direct orders |
| Status | Colored chip — DRAFT / APPROVED / PARTIALLY_DELIVERED / DELIVERED / CANCELLED |
| Grand Total | In transaction currency |
| Sales Person | |

**Filters:** Location, Status, Mode, Customer, Date range.
**Search:** Order No, Customer name, or Customer PO Ref.
**Buttons:** `+ New Order` (top-right, `canAdd`-gated) — opens a small mode picker (Direct / Against Quotation) before landing on the Entry screen.

### 3.2 Entry Screen

```
┌──────────────────────────────────────────────────────────────────────┐
│  Sales Order                                    [Save Draft] [Approve]│
│  SO/KIN/2026/00001 · DRAFT · Against SQ/KIN/2026/00001    [Print]     │
├──────────────────────────────────────────────────────────────────────┤
│  Order No: (auto)    Order Date: [____]     Customer PO Ref: [____]   │
│  Customer: [code] name  Location: [__▾]     Sales Person: [____▾]     │
│  Currency: [USD]  Rate: [____]              Status: DRAFT             │
│  Payment Terms: [__________]  Delivery Terms: [__________]            │
│  Remarks: [______________________________________________________]   │
├──────────────────────────────────────────────────────────────────────┤
│  Lines                                    [+ Add Line] (Direct only) │
│  # | Product | UOM | Qty Pk | Qty Ls | Rate🔒| Disc%🔒| Tax | Total   │
│    | Source (frozen, Against-Quotation only)                    [x]  │
├──────────────────────────────────────────────────────────────────────┤
│  Charges (optional, always editable)                 [+ Add Charge]  │
│  Charge [code] name | Nature | Amt/% | Amount | Tax | Tax Amt | Total │
├──────────────────────────────────────────────────────────────────────┤
│                    Subtotal:  Discount:  Charges:  Tax:  GRAND TOTAL │
└──────────────────────────────────────────────────────────────────────┘
```
🔒 = locked in both modes unless the acting user's Sales Controls permit an override (Direct mode only — see §4).

- Header buttons top-right next to the title (standard convention); mobile stacks them below.
- **Header Card**: Order No (read-only) · Order Date · Customer PO Ref (free text, the customer's own reference number — common in B2B wholesale) · Customer (Autocomplete, Direct mode only — read-only, inherited, in Against-Quotation mode) · Location · Sales Person · Currency/Rate · Payment/Delivery Terms · Remarks.
- **Lines Card**: Direct mode — `+ Add Line` available, Product Autocomplete + barcode scan (gated by `showBarcode`), UOM, Qty Pack/Loose (gated by `showLooseQty`), Rate (read-only unless override permission), Discount % (hidden unless `can_give_discount`), Tax, Line Total. Against-Quotation mode — no `+ Add Line`; lines are pre-populated from the source quotation, entirely read-only except **Qty to Convert** (capped at the line's remaining unconverted quantity).
- **Charges Card**: identical shape and behavior in both modes — always addable/editable.
- **Totals footer**: Subtotal, Discount Total, Charges Total, Tax Total, Grand Total.

---

## 4. Screen Functionality

### Header fields
| Field | Behavior |
|---|---|
| Order No | Auto-assigned on first Save Draft, format `SO/{LOC}/{YYYY}/{SEQ5}` (same per-location scheme as Sales Quotation's `SQ`). Read-only. |
| Order Date | Date picker, defaults to today. Editable while DRAFT. |
| Order Mode | `DIRECT` or `AGAINST_QUOTATION` — chosen once, at creation, from the list screen's "+ New Order" picker. Immutable after first save. |
| Customer PO Ref | Free text — the customer's own purchase order/reference number, if any. New field, not present on Sales Quotation. |
| Customer | Direct mode: `Autocomplete` filtered to `rim_accounts` where `account_nature = 'Customer'` (same Account Picker rule as Quotation). Against-Quotation mode: inherited from the (now-guaranteed-real) customer on the source quotation, read-only. |
| Location | Dropdown, defaults to session location. Never restricts customer/location combination (Inter-Location Model rule). |
| Sales Person | Dropdown of `rim_users`. |
| Currency / Rate | Direct mode: defaults from customer's ledger currency, rate via `fn_get_exchange_rate(..., 'SELLING')`. Against-Quotation mode: inherited from the quotation. |
| Payment / Delivery Terms | Free text, same shape as Quotation. |
| Status | Read-only colored chip, see lifecycle below. |
| Remarks | Free text. |

### Order Mode — Direct
- Customer picked directly; no quotation involved, no prospect concept applies (a Direct order customer is always a real, existing `rim_accounts` Customer).
- Per line, price resolves via `fn_get_active_price(client, company, location, product, uom, customer_id, order_date)`:
  - **Resolved** → Rate locked to that value, `price_source = 'PRICE_MASTER'`.
  - **Not resolved** → line save is **hard-blocked** unless the acting user's `ric_user_sales_controls.can_override_price = true`, in which case Rate becomes manually editable and a short **Override Reason** is required (`price_source = 'MANUAL_OVERRIDE'`).
  - Even when a price *is* resolved, a user with `can_override_price = true` may still change it (same reason requirement applies whenever the entered rate differs from the resolved one).
- Discount % field is hidden entirely unless `can_give_discount = true`; if shown, the entered value is validated server-side against `max_discount_percent`.
- Cost Price / Margin columns are shown only if `can_view_cost_price = true` — and are never even fetched from the server otherwise (not just hidden client-side).

### Order Mode — Against Quotation
Triggered by picking a specific quotation from a picker (filtered to the quotation's own convertible statuses: APPROVED / SENT / ACCEPTED / PARTIALLY_CONVERTED, not expired, with unconverted quantity remaining). Before the Order DRAFT is created:
1. **Validity re-check** (status, expiry, remaining qty) — server-side authoritative, client-side pre-flight for UX.
2. **If the quotation's `customer_type = PROSPECT`** → the **Prospect → Customer Conversion** wizard opens (see §5) — must complete before proceeding.
3. Order is created with every line's product/UOM/rate/discount/tax **frozen exactly as quoted** — the only per-line choice is **how much of the remaining unconverted quantity** to bring into this Order (supports partial conversion across multiple future Orders from one quotation).
4. Charges are copied from the quotation as a starting point but remain fully editable — new charges can be added, inherited charge amounts can be amended.

On Approve, `converted_qty` is written back to the source quotation's lines, and its header status rolls to `PARTIALLY_CONVERTED` or `CONVERTED` — the exact downstream contract the Sales Quotation module already documented.

### Status lifecycle
```
DRAFT ──Approve──▶ APPROVED ──(future Delivery/Invoice screen)──▶ PARTIALLY_DELIVERED ──▶ DELIVERED
  │                    │
  └────────Cancel──────┘   (CANCELLED — only reachable before any delivery/invoice has occurred)
```
No Send/Accept/Reject stage — by the time an Order exists, the customer has already committed (that negotiation already happened at Quotation stage, if any). Mirrors Purchase Order's own lifecycle shape, not Quotation's pipeline shape.

### Buttons
| Button | Gate | Behavior |
|---|---|---|
| Save Draft | `canAdd`/`canEdit`, status = DRAFT | Validates + saves header/lines/charges, assigns Order No on first save. |
| Approve | `canApprove`, status = DRAFT | Locks the order from further edits; for Against-Quotation orders, writes back `converted_qty`/status to the source quotation. |
| Print | any status once Order No exists | Produces the customer-facing PDF. |
| Cancel | `canApprove`, status ∈ {DRAFT, APPROVED} and nothing delivered yet | Sets CANCELLED. |

### Permissions
`ScreenPermissionMixin`, `screenName = '/sales/orders'`. `canAdd`/`canEdit` gate Save Draft, `canApprove` gates Approve/Cancel. Price/discount/cost-visibility behavior is additionally governed by the acting user's own `ric_user_sales_controls` row (a separate, per-user setting configured in the existing Permissions screen — see the companion note in that screen's own documentation once built), not by `ScreenPermissionMixin`.

### Company-configurable line fields
`showLooseQty`/`showBarcode` computed once in `build()`, exactly per the mandatory app-wide pattern. Barcode scanning applies to Direct-mode line entry only (origin-style); Against-Quotation lines carry the barcode forward from the source quotation line (consolidation-style) — same origin-vs-consolidation split as every other module.

### Batch/Serial — explicitly not on this screen
Same reasoning as Purchase Order and Sales Quotation: no stock movement happens on this document, so there is nothing to allocate a batch/serial against. Deferred entirely to the future Sales Delivery/Invoice screen. Called out explicitly so it doesn't read as a missed item.

### Period/backdate checks — deliberately skipped
Sales Order never posts to the books at any status, so `fn_check_period_open`/`fn_check_backdate_allowed` are not called — same intentional deviation Sales Quotation and Sales Price Master already document.

### Offline support
Direct-mode Save Draft works fully offline (standard Drift cache + `SyncEngine` retrofit pattern, including the `_renameLocalDocument` case for `SALES_ORDER`). **Against-Quotation mode is online-only end to end** — starting one requires a live validity check against the quotation and potentially the Prospect Conversion wizard, which creates a real ledger account. Approve is online-only for both modes, same as every other module.

### Print support
Standard `PrintEngine` integration (5-step checklist already documented in CLAUDE.md) — this is a customer-facing document, so print is a first-class requirement, not optional (unlike Price Master).

---

## 5. Data Flow

### Upstream — what this screen reads
| Source | Purpose |
|---|---|
| `rim_accounts` (`account_nature = 'Customer'`) | Customer picker (Direct mode) |
| `rih_sales_quotations` / `rid_sales_quotation_lines` / `rid_sales_quotation_charges` | Source data for Against-Quotation mode |
| `fn_get_active_price` (Price Master, 083) | Locked price resolution for Direct mode |
| `rim_product_location.cost_price` | Cost/margin display, gated by `can_view_cost_price` |
| `ric_user_sales_controls` (**new**) | Per-user price-override/discount/cost-visibility settings |
| `rim_products` + `rim_product_uom`, `rim_tax_groups`/`rim_taxes`, `rim_additional_charges` | Same as Sales Quotation |
| `rim_users` | Sales Person picker |
| `rim_voucher_types` | New `SO` voucher type; numbering via existing per-location `fn_next_trans_no` |

### New tables this screen introduces
| Table | Notes |
|---|---|
| `ric_user_sales_controls` | Per-user: `can_override_price`, `can_give_discount`, `max_discount_percent`, `can_view_cost_price`. Configured via the existing Permissions screen, not this one. |
| `rih_prospect_conversions` | One row per Prospect→Customer conversion event: source quotation, new customer id, converted_by/at, notes. Pure audit/traceability log. |
| `rih_sales_orders` | Header. Unique `(client_id, company_id, order_no, order_date)`. Carries `order_mode`, soft-linked `source_quotation_no/date` (nullable), `customer_id` (always NOT NULL — no prospect concept survives to this document), `customer_po_ref`. |
| `rid_sales_order_lines` | `rate`, `price_source`, `price_override_reason` (nullable), `discount_pct/amt`, tax fields, `charge_amount/landed_amount`, `delivered_qty` (running total for future partial delivery/invoicing), `source_quotation_line_serial` (nullable). |
| `rid_sales_order_charges` | Mirrors `rid_sales_quotation_charges`/`rid_po_charge_lines`. Always editable regardless of mode. |

New PG functions: `fn_save_sales_order`, `fn_approve_sales_order`, `fn_convert_prospect_to_customer` (standalone/reusable, not embedded in the save function).

### Confirmed: zero GL / zero stock impact
No call to `fn_post_voucher` or `fn_post_stock_movement` anywhere in this module, at any status — identical guarantee to Sales Quotation and Purchase Order.

### Downstream — what consumes this screen's output
- **Sales Delivery / Sales Invoice** (future screen, mirrors GRN's role): reads an APPROVED Order's lines, writes back `delivered_qty`, rolls status to PARTIALLY_DELIVERED/DELIVERED, and is the first point in this pipeline that actually touches stock/GL.
- **Sales Quotation**: receives `converted_qty`/status write-back from Against-Quotation orders (already documented as Quotation's own downstream contract).
- **`rih_prospect_conversions`**: a natural future input to a sales pipeline/conversion-rate report, same forward-pointer already flagged in the Quotation doc.

### What is NOT in this screen
- No Sales Delivery/Invoice functionality (separate, future — this document only defines the trigger/contract point)
- No stock reservation or allocation of any kind
- No GL posting of any kind
- No batch/serial selection
- No multi-quotation consolidation into one Order (always exactly one quotation, or none)
- No payment/receipt handling
- No dedicated Prospect Conversion list/report screen (the `rih_prospect_conversions` log exists, but v1 has no UI to browse it)

---

*Design agreed: 2026-07-14*

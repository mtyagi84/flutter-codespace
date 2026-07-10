# Sales Quotation
## Screen Requirement Document

**Module:** Sales (first screen of this module)
**Route:** `/sales/quotations`
**Status:** ✅ SQL migration (081) + Flutter screens built — pending Codespace build/test (flutter analyze, pgTAP, manual smoke test)

---

## 1. Screen Name

**Sales Quotation** — two screens:
- **Sales Quotation List** — browse/search/filter existing quotations
- **Sales Quotation Entry** — create/edit/approve a single quotation

---

## 2. Screen Description

### Why this screen is needed
A quotation is the formal price offer a company gives a customer **before** any commitment exists — the customer hasn't ordered anything yet, no stock is reserved, and no accounting entry is made. It exists so the sales team can:

- Negotiate price, discount, and delivery/payment terms with a prospective or existing customer over a period of days or weeks (typical for B2B wholesale customers in DRC/Zambia), or issue a quick over-the-counter quote for a walk-in customer.
- Have a written, printable record of exactly what was promised (rate, discount, validity date, delivery terms) — protecting both the company and the customer from later disputes.
- Track the sales pipeline: how many quotations are sent, accepted, rejected, or expired, and how many convert into real business.

### Where it sits in the ERP
Sales Quotation plays the same role on the **sales** side that Purchase Order plays on the **purchase** side: a pre-commitment document that carries no stock or GL impact. Real inventory/financial effect only happens later, when the quotation is converted into a **Sales Order** and/or a **Sales Invoice** (both separate, not-yet-built screens).

```
Sales Quotation  ──(Convert)──▶  Sales Order   ──▶  Sales Invoice   ──▶  GL + Stock
      │                                                    ▲
      └────────────────────(Convert directly)──────────────┘
```

A quotation can be converted straight to a Sales Invoice (simple retail-style sale) **or** via a Sales Order first (more formal B2B flow with its own stock reservation) — the user chooses at conversion time; it is not a fixed pipeline.

---

## 3. Screen Layout

### 3.1 List Screen

Uses the shared `SakalAdaptiveList<QuotationModel>` widget (`lib/core/widgets/sakal_adaptive_list.dart`) — desktop table / mobile cards, no hand-rolled layout.

| Column | Notes |
|---|---|
| Quotation No | e.g. `SQ/KIN/2026/00001` |
| Date | Quotation date |
| Customer | `[code] name` |
| Valid Until | Highlighted red if past today and not yet Accepted/Converted |
| Status | Colored chip — DRAFT / APPROVED / SENT / ACCEPTED / REJECTED / EXPIRED / PARTIALLY_CONVERTED / CONVERTED |
| Grand Total | In transaction currency |
| Sales Person | |

**Filters:** Location, Status, Customer, Date range.
**Search:** Quotation No or Customer name.
**Buttons:** `+ New Quotation` (top-right, `canAdd`-gated).
**Row tap:** opens Entry screen — editable if `canEdit` and status = DRAFT, read-only otherwise.

### 3.2 Entry Screen

```
┌──────────────────────────────────────────────────────────────────────┐
│  Sales Quotation                          [Save Draft] [Approve]     │
│  SQ/KIN/2026/00001 · DRAFT                [Send] [Print] [Convert ▾] │
├──────────────────────────────────────────────────────────────────────┤
│  Quotation No: (auto)    Quotation Date: [____]   Valid Until:[____] │
│  Customer: [code] name ▾  Location: [____▾]        Sales Person:[__▾]│
│  Currency: [USD]  Rate: [____]                     Status: DRAFT     │
│  Payment Terms: [__________]  Delivery Terms: [__________]           │
│  Remarks: [______________________________________________________]  │
├──────────────────────────────────────────────────────────────────────┤
│  Lines                                                 [+ Add Line]  │
│  # | Product        | UOM | Qty Pk | Qty Ls | Rate | Disc% | DiscAmt│
│    | Tax Grp | Tax Amt | Line Total |                          [x]  │
├──────────────────────────────────────────────────────────────────────┤
│  Charges (optional)                                   [+ Add Charge] │
│  Charge [code] name | Nature | Amt/% | Amount | Tax | Tax Amt | Total│
├──────────────────────────────────────────────────────────────────────┤
│                    Subtotal:  Discount:  Charges:  Tax:  GRAND TOTAL │
└──────────────────────────────────────────────────────────────────────┘
```

- Header buttons sit top-right next to the title, per the app-wide entry-screen convention (mobile: stacked in a `Column` below the title instead of inline).
- **Header Card** (Row 1) Quotation No (read-only) · Quotation Date · Valid Until Date
  (Row 2) Customer (Autocomplete `[code] name`) · Location · Sales Person
  (Row 3) Currency (chip) · Rate (editable, hidden when currency = base) · Status (chip)
  (Row 4) Payment Terms (free text) · Delivery Terms / Shipping Address (free text) · Remarks
- **Lines Card**: `#`, Product (Autocomplete `[code] name` + a barcode-scan field gated by `showBarcode`), UOM, Qty Pack, Qty Loose (gated by `showLooseQty`; label falls back to plain "Quantity" when hidden), Rate, Discount %, Discount Amt, Taxable Amount, Tax Group, Tax Amt, Line Total, **Landed Amount** (all-inclusive price including this line's apportioned share of charges — added after the initial build, see §4/§5), Remove. **No batch/serial fields on this screen** — see §4.
- **Charges Card** (collapsible, optional): Charge `[code] name`, Nature (ADD/DEDUCT, frozen from the master at entry time), Amount/Percent toggle, Amount, Tax, Tax Amt, Total.
- **Totals footer**: Subtotal, Discount Total, Charges Total, Tax Total, Grand Total.
- **`Convert ▾`** button: dropdown with "Convert to Sales Order" / "Convert to Sales Invoice" — visible only once status is APPROVED, SENT, ACCEPTED, or PARTIALLY_CONVERTED, and the quotation still has unconverted quantity on at least one line. Both target screens don't exist yet — this button documents the trigger point/contract for when they're built, it is not implemented in this screen's first version.

---

## 4. Screen Functionality

### Header fields
| Field | Behavior |
|---|---|
| Quotation No | Auto-assigned on first Save Draft, format `SQ/{LOC}/{YYYY}/{SEQ5}` (same token scheme as CRV/BRV). Read-only. |
| Quotation Date | Date picker, defaults to today. Editable while DRAFT. |
| Valid Until Date | Date picker, must be ≥ Quotation Date. Drives the computed EXPIRED status. |
| Customer Type | `SegmentedButton` toggle — **Existing Customer** or **Prospect**. Added after the initial build once it became clear a quotation must be issuable to a prospect with no `rim_accounts` ledger yet. |
| Customer (when type = Existing Customer) | `Autocomplete`, filtered to `rim_accounts` where `account_nature = 'Customer'`, shows `[code] name`, searches code OR name (standard Account Picker rule). Selecting a customer auto-fills the Party fields below (name/phone/email/address) from the account, fetches `credit_limit`/`credit_days`/`is_credit_blocked` as **info only** — none of these block saving (mirrors how PO already shows supplier info without blocking). |
| Prospect Name (when type = Prospect) | Free-text required field replacing the Customer Autocomplete. No `rim_accounts` row is created — see Data Flow. |
| Party Phone / Email / Address | **Always populated** regardless of Customer Type — auto-filled (but editable per-quotation, same "default from master, editable per-document" convention as PO's Ship To) when an existing customer is picked; typed directly for a Prospect. Printing and every downstream reader always reads these snapshot fields, never branches on customer type. |
| Location | Dropdown of the company's locations, defaults to the user's session location. Never restricts which customer/location combination is allowed — quotations, like every external transaction, are never location-restricted (per the Inter-Location Model rule). |
| Sales Person | Dropdown of `rim_users`, for pipeline/commission tracking. |
| Currency | Defaults from the selected customer's ledger currency; editable. |
| Rate | Auto-fetched via `fn_get_exchange_rate(..., p_rate_type => 'SELLING')` when currency ≠ base — converting **to** the customer's currency uses the SELLING rate, per the existing Exchange Rate screen's documented rule. Editable, hidden entirely when currency = base. |
| Payment Terms | Free-text note (e.g. "30 days net"). Deliberately **not** an installment schedule like PO's `rid_po_payment_terms` — a quotation isn't a committed bill yet, so a structured schedule belongs at Sales Order/Invoice stage, not here. |
| Delivery Terms / Shipping Address | Free text, defaults from the customer's address but editable per quotation (delivery address can differ from billing). |
| Status | Read-only colored chip, see lifecycle below. |
| Remarks | Free text. |

### Status lifecycle
```
DRAFT ──Approve──▶ APPROVED ──Send──▶ SENT ──▶ ACCEPTED ──▶ PARTIALLY_CONVERTED ──▶ CONVERTED
                                        │              │
                                        ▼              ▼
                                    REJECTED        (also reachable from SENT)
                                        
SENT / ACCEPTED ──▶ EXPIRED   (computed: today > Valid Until Date, not yet Accepted/Converted)
```
- **EXPIRED is a computed display state**, not a column a job flips — the UI/list computes it from `valid_until_date` vs. today whenever status is SENT or ACCEPTED. No cron job needed.
- **Partial conversion**: each line tracks a running `converted_qty`, so one quotation can spawn multiple Sales Orders/Invoices over time as a customer takes partial delivery — this deliberately follows the PO→GRN partial-fulfillment precedent (many GRNs per PO) rather than GRN→Purchase Invoice's whole-document-only precedent, because a customer accepting quantity in stages is a normal sales pattern.

### Buttons
| Button | Gate | Behavior |
|---|---|---|
| Save Draft | `canAdd`/`canEdit`, status = DRAFT | Validates required fields, saves header+lines+charges, assigns Quotation No on first save. |
| Approve | `canApprove`, status = DRAFT | Locks the quotation from further line edits. **Required before Send/Print** — a formal approval step (e.g. a supervisor confirming the discount/rate given), per this module's own decision, unlike some other pre-commitment documents. |
| Send | status = APPROVED | Marks SENT — signals the quotation has gone out to the customer. No email/SMS integration in this version; it's a manual status flip once the user has printed/shared the document themselves. |
| Print | any status once Quotation No exists | Produces the customer-facing PDF — see Print support below. |
| Convert ▾ | status ∈ {APPROVED, SENT, ACCEPTED, PARTIALLY_CONVERTED} and unconverted qty remains | Opens the (future) Sales Order or Sales Invoice entry screen pre-filled from this quotation's lines. |
| Accept / Reject | status = SENT | Records the customer's response — sets ACCEPTED or REJECTED. |

### Permissions
`ScreenPermissionMixin`, `screenName = '/sales/quotations'`. `canAdd`/`canEdit` gate Save Draft; `canApprove` gates the Approve button; no separate permission for Send/Accept/Reject (bundled under `canEdit`) since they carry no financial risk.

### Company-configurable line fields
`showLooseQty` (from `qty_entry_mode`) and `showBarcode` (from `enable_barcode`) are computed once in `build()` and threaded down to the line-rendering method, exactly per the mandatory app-wide pattern — not re-read per row.

### Batch/Serial — explicitly not on this screen
A quotation has no stock allocation to attach a batch/serial to — there's nothing yet to reserve. This is intentionally the same shape as Purchase Order (which also has no batch/serial entry; only GRN, the actual goods receipt, does). Batch/serial selection is deferred entirely to Sales Order/Invoice. This is called out explicitly here so it doesn't look like a missed item against the CLAUDE.md pre-completion self-check — the answer for this screen is "N/A by design."

### Period/backdate checks — deliberately skipped
Every other `fn_approve_*` function calls `fn_check_period_open`/`fn_check_backdate_allowed` first, because it's about to post to the books. `fn_approve_sales_quotation` does **not**, because a quotation never posts to the books at any status — flagged explicitly here as an intentional deviation from the usual rule, not an oversight.

### Offline support
Sales Quotation is one of the more offline-relevant screens in the app: field sales reps visiting customers in DRC/Zambia routinely work with unstable or no connectivity while negotiating a quote. Full support: Drift local cache table, `sales_quotation_local_ds.dart`, repository `(_remote, _local, _isOffline)` pattern, `SyncEngine` enqueue on Save Draft (standard offline retrofit pattern). **Approve, Send, and Convert require an online connection** — Approve needs live numbering/locking, Send/Convert have effects other users/screens depend on — matching the existing "Approve stays online-only" convention.

### Print support
Standard `PrintEngine` integration (`print_field_registry.dart`, a `sales_quotation_default_template.dart`, `print_template_provider.dart`, `print_sample_data.dart`, and the screen's own `_buildPrintDocument()`/`_printQuotation()`/`_buildPrintButton()`) — the 5-step additive checklist already documented in CLAUDE.md, not repeated here. This is the document a customer actually receives, so it's a first-class requirement, not an afterthought.

---

## 5. Data Flow

### Upstream — what this screen reads
| Source | Purpose |
|---|---|
| `rim_accounts` (`account_nature = 'Customer'`) | Customer picker, credit info, ledger currency |
| `rim_products` + `rim_product_uom` | Product picker, pack/loose conversion, per-UOM barcode |
| `rim_tax_groups` / `rim_taxes` (via `product.sales_tax_group_id`) | Line-level tax calculation |
| `rim_additional_charges` (`applicable_on IN ('SALES','BOTH')`) | Charges picker — same shared master Purchase already uses |
| `rim_exchange_rates` via `fn_get_exchange_rate` | SELLING rate for foreign-currency quotations |
| `rim_users` | Sales Person picker |
| `rim_voucher_types` | New `SQ` voucher type code + `trans_no_format`; numbering via the existing **per-location** `fn_next_trans_no`/`ril_trans_no_seq` (this session's decision — matches Finance Vouchers, not PO's company-wide scheme) |
| Session (`UserSession`) | `qtyEntryMode`, `enableBarcode`, default location |

### New tables this screen introduces
Naming follows the `rih_purchase_orders` / `rid_purchase_order_lines` / `rid_po_charge_lines` precedent:

| Table | Notes |
|---|---|
| `rih_sales_quotations` | Header. Unique key `(client_id, company_id, quotation_no, quotation_date)`. `location_id` is a plain column only (which location this quotation is FROM, and an input to `fn_next_trans_no`'s per-location numbering sequence) — it is **not** part of the key, matching GRN/Material Requisition's shape (only Finance Vouchers, the earliest-built module, actually keys on location; that was wrongly generalized as "the location-scoped pattern" in an earlier draft of this migration and corrected before anything was ever run). Also carries `customer_type` (CUSTOMER/PROSPECT), nullable `customer_id`, and always-populated `party_name`/`party_phone`/`party_email`/`party_address` — see Prospect support below. |
| `rid_sales_quotation_lines` | `qty_pack`/`qty_loose`/`base_qty`, `rate`, `discount_pct`/`discount_amt`, tax fields, `converted_qty` (running total pulled into Sales Order/Invoice — enables partial conversion, mirrors PO's `qty_received`), and `charge_amount`/`landed_amount` (this line's apportioned share of quotation charges + all-inclusive price — added after the initial build, see below). |
| `rid_sales_quotation_charges` | Mirrors `rid_po_charge_lines`, including `allocation_factor` — freezes charge type/tax/nature from the master at entry time, apportions by value onto each line same as PO's landed cost (no costing purpose here, purely so the customer sees an all-inclusive per-item price). |

**Prospect support** (added after the initial build, in response to a real gap: a quotation must be issuable to someone with no `rim_accounts` ledger yet): `customer_type` toggles between CUSTOMER (real `rim_accounts` row, `customer_id` required) and PROSPECT (`customer_id` NULL, nothing created in the accounting master). `party_name`/`party_phone`/`party_email`/`party_address` are **always populated** regardless of type — auto-filled from the account (but editable per-quotation) when CUSTOMER, typed directly when PROSPECT — so printing and every future report reads one set of columns and never branches on type. A prospect only gets a real Customer account at the point a future Sales Order/Invoice conversion forces it — never at quoting time, keeping the accounting master free of speculative entities.

New PG functions: `fn_save_sales_quotation`, `fn_approve_sales_quotation` (reuses the existing `fn_next_trans_no`). No new posting engine — see below.

### Confirmed: zero GL / zero stock impact
**No call to `fn_post_voucher` or `fn_post_stock_movement` anywhere in this module, at any status.** This is the single most important data-flow rule for this screen: nothing it does is ever visible in the trial balance, P&L, balance sheet, or `rim_product_location.current_stock`.

### Downstream — what consumes this screen's output
- **Sales Order** (future screen) and/or **Sales Invoice** (future screen): either can read an APPROVED/SENT/ACCEPTED quotation's lines as a prefill (product, qty, rate, discount, tax), and on their own Approve, write back `converted_qty` per line here — rolling this header's status to PARTIALLY_CONVERTED or CONVERTED once fully consumed. This is the same reservation-linkage idea as GRN's `billed_invoice_no`/Stock Count's `consolidated_into_review_no`, generalized from a single header flag to a per-line running total so partial conversion is possible.
- **Print/PDF**: leaves the system entirely once produced — emailed, WhatsApp'd, or handed to the customer outside the app. Send only flips the in-app status; there is no email/SMS integration built.
- **Future Sales Pipeline / Conversion-Rate report**: a natural future consumer of the status history (win rate = (ACCEPTED + CONVERTED) ÷ total SENT) — explicitly out of scope for this screen, flagged here as a forward pointer only.

### What is NOT in this screen
- No Sales Order screen (separate, future — this document only defines the trigger/contract point)
- No Sales Invoice screen (separate, future)
- No stock reservation or allocation of any kind
- No GL posting of any kind
- No batch/serial selection (see §4)
- No payment/receipt handling
- No price-list or customer-specific pricing engine — Rate is manually entered per line in this version, exactly like PO's own Rate field; a future Price List module can prefill it later without changing this screen's contract
- No multi-level or threshold-based approval — a single `canApprove` gate only

---

*Design agreed: 2026-07-10*
*First screen of the Sales module — no prior Sales code or tables existed before this document.*

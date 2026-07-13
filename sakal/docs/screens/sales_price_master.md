# Sales Price Master
## Screen Requirement Document

**Module:** Sales (second screen of this module)
**Route:** `/sales/price-master`
**Status:** 🚧 Design agreed (revised) — SQL migration + Flutter build pending

**Revision note:** this doc replaces an earlier draft that scoped pricing as company-wide. That draft was never migrated or committed — this version reflects the corrected, location-wise design agreed with the user, plus currency, margin/cost, below-cost reason, barcode/part-number scan, and print requirements added in the same round of discussion.

---

## 1. Screen Name

**Sales Price Master** — two screens:
- **Price Master List** — browse/search/filter existing price batches
- **Price Master Entry** — create/edit/approve one batch of product prices

---

## 2. Screen Description

### Why this screen is needed
`rim_products` was deliberately built with no selling-price column — migration 026's own header comment names this exact gap: *"rim_product_location_price and fn_get_product_price deferred to Sales module."* Sales Quotation, the first Sales screen, hit this gap live and documented it as an explicit "what is NOT in this screen" item: Rate is manually typed per line with no price-list engine behind it. This screen pays off that deferral.

It exists so a company can:
- Maintain a selling price **per location** — the same product can legitimately sell at a different price in different stores (different rent, different local competition, different market), so price is never a single company-wide number.
- Maintain one **generic** selling price per product/UOM/location (applicable to all customers by default), and override it for a **specific customer** at that same location without touching the generic price everyone else sees.
- Enter a price in **whichever currency makes sense for that batch** (base, local, or a customer's own currency), while immediately seeing the product's current cost in that same currency for comparison.
- Derive the selling price from a target **margin %**, or type the price directly and see the margin computed automatically — whichever direction is more natural for how the user thinks about that product.
- Require a **documented reason** the moment a price is set below cost, so a below-cost line is always a deliberate, auditable decision (clearance, promotion, competitor match) and never a silent typo.
- **Scan a barcode or part number** to jump straight to pricing a specific item, without hunting for it in a product list.
- Schedule a price change **ahead of time** — enter and approve next month's price list today, and have it silently take over the moment the date arrives, with zero manual intervention on the day.
- Update **many products at once** in a single reviewable, approvable batch — a monthly price revision touching 200 SKUs at one store is one document, not 200 edits.
- **Print** the batch as a reference document (e.g. to hand to a store manager or file for audit).

### Where it sits in the ERP
Price Master is reference data with an approval gate — it never touches GL or stock, at any status. It sits **upstream** of Sales Order and Sales Invoice (both future, not-yet-built screens): those screens will call this module's resolver function to prefill a line's rate instead of a user typing it free-hand, exactly the gap Sales Quotation's own doc flagged.

```
Sales Price Master (per LOCATION, DRAFT → APPROVED, effective_date arrives)
        │
        ▼  fn_get_active_price(location, product, uom, customer, as_of_date)
Sales Order / Sales Invoice   (future screens — read-only consumers)
```

---

## 3. Screen Layout

### 3.1 List Screen

Uses the shared `SakalAdaptiveList<Map<String, dynamic>>` widget (`lib/core/widgets/sakal_adaptive_list.dart`) — desktop table / mobile cards, no hand-rolled layout.

| Column | Notes |
|---|---|
| Entry No | e.g. `PRC/KIN/2026/00001` (per-location numbering) |
| Location | Which store/location this batch prices |
| Entry Date | Batch entry/booking date |
| Price Type | Chip — GENERIC or CUSTOMER |
| Customer | Blank for GENERIC batches; `[code] name` for CUSTOMER batches |
| Currency | The batch's entry currency |
| Effective Date | Highlighted (e.g. amber) if still in the future — not yet active even though it may already be APPROVED |
| Status | Chip — DRAFT / APPROVED |
| Line Count | Number of product/UOM price lines in the batch |

**Filters:** Location, Price Type, Customer, Status, Effective Date range.
**Search:** Entry No or Customer name.
**Buttons:** `+ New Batch` (top-right, `canAdd`-gated).
**Row tap:** opens Entry screen — editable if `canEdit` and status = DRAFT, read-only otherwise.

### 3.2 Entry Screen

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Sales Price Master                        [Save Draft] [Approve][Print] │
│  PRC/KIN/2026/00001 · DRAFT                                               │
├──────────────────────────────────────────────────────────────────────────┤
│  Entry No: (auto)    Entry Date: [____]    Effective Date: [____]        │
│  Location: [____▾]   Currency: [USD▾]  Rate: [____] (hidden if base)     │
│  Price Type: (•) Generic  ( ) Customer-Specific                          │
│  Customer: [code] name ▾   (shown only when Price Type = Customer)       │
│  Scan Barcode / Part Number: [_______________]  Status: DRAFT           │
│  Remarks: [__________________________________________________________]  │
├──────────────────────────────────────────────────────────────────────────┤
│  Lines                                                     [+ Add Line]  │
│  # | Product | UOM | Cost | Margin% | Selling Price | BelowCostReason    │
│    | Incl.Tax?  | Barcode(audit)                                  [x]   │
├──────────────────────────────────────────────────────────────────────────┤
```

- Header buttons sit top-right next to the title, per the app-wide entry-screen convention (mobile: stacked in a `Column` below the title instead of inline).
- **Header Card** (Row 1) Entry No (read-only) · Entry Date (defaults today, editable while DRAFT) · Effective Date (date picker, **no upper bound**)
  (Row 2) Location (dropdown, session default, **locked once the first line is added** — same reasoning as Price Type below) · Currency (chip/dropdown, defaults to company base currency) · Rate to Base (editable, hidden when currency = base — same convention as Sales Quotation)
  (Row 3) Price Type (`SegmentedButton`: Generic / Customer-Specific — **locked once the first line is added**)
  (Row 4) Customer (Autocomplete `[code] name`, visible and required only when Price Type = Customer-Specific)
  (Row 5) **Scan Barcode / Part Number** (text field, gated by `showBarcode`/`enablePartNumber` — see §4) · Status (chip) · Remarks
- **Lines Card**: `#`, Product (Autocomplete `[code] name`), UOM (dropdown scoped to that product's `rim_product_uom` rows), **Cost Price** (read-only, computed — see §4), **Margin %** (editable, bidirectional with Selling Price), **Selling Price** (editable, bidirectional with Margin %), **Below-Cost Reason** (dropdown, appears/becomes required only when Selling Price < Cost Price), Tax Inclusive? (checkbox, display-only), Barcode (small, read-only audit display of what was scanned to build this line, if any), Remove. **No Tax Group field** — tax is already linked per product via `rim_products.sales_tax_group_id`; a future Sales Order/Invoice resolves it from the product at the point of sale, not from this line.
- **No Qty, no Discount, no Charges, no Totals footer** — this is a rate list, not a transaction; there is nothing to sum.
- Same product can appear on **multiple lines** in one batch as long as each line's UOM differs — duplicate (product, UOM) pairs within one batch are rejected at Save; duplicate barcodes are rejected the same way (see §4).

---

## 4. Screen Functionality

### Header fields
| Field | Behavior |
|---|---|
| Entry No | Auto-assigned on first Save Draft, format `PRC/{LOC}/{YYYY}/{SEQ5}` — **per-location** numbering via `fn_next_trans_no`, same scheme as Sales Quotation (reversed from an earlier draft of this doc that wrongly scoped it company-wide, like Purchase Order). Read-only. |
| Entry Date | Date picker, defaults to today. Editable while DRAFT. |
| Effective Date | Date picker. May be before, on, or after Entry Date — no validation against today in either direction. Drives when the price actually becomes usable, entirely independent of Approve. |
| Location | Dropdown, defaults to the user's session location. **One location per batch** — a price revision for a second store is a separate batch. Locked once a line exists, for the same reason Price Type is locked (see below): every line's cost lookup and coexistence-uniqueness key are anchored to this one location. |
| Currency | Defaults to the company's base currency; editable to any active currency. Drives which currency the line's Selling Price and displayed Cost Price are both shown in. |
| Rate to Base | Auto-fetched via `fn_get_exchange_rate(..., p_rate_type => 'SELLING')` when Currency ≠ base, same convention as Sales Quotation. Editable. Hidden entirely when Currency = base. |
| Price Type | `SegmentedButton` — **Generic** or **Customer-Specific**. Applies to every line in this batch; a batch is never mixed. Locked once a line exists. |
| Customer (when Price Type = Customer-Specific) | `Autocomplete`, filtered to `rim_accounts` where `account_nature = 'Customer'`, `[code] name`, searches code OR name. Required. |
| Scan Barcode / Part Number | See "Barcode / Part Number scan" below. |
| Status | Read-only colored chip, see lifecycle below. |
| Remarks | Free text. |

### Cost Price display — the three-way currency rule
Every line shows a read-only **Cost Price**, in the header's own selected Currency, resolved as:
1. **Currency = company base currency** → show `rim_product_location.cost_price` (that product's current moving-average cost at this batch's Location) as-is, no conversion.
2. **Currency = that product's own `cost_currency_id`** → show `rim_product_location.cost_price_specific` as-is — this is already maintained (per GRN's landed-cost posting) in the product's own procurement currency, so no conversion is needed or wanted.
3. **Anything else** → convert `cost_price` (base) into the header's Currency using the header's own already-confirmed **Rate to Base** (`cost_in_currency = cost_price_base / rate_to_base`) — reusing the header's own rate rather than a fresh `fn_get_exchange_rate` lookup, per this codebase's established rule (GRN's migration 057 fix: reuse the confirmed document rate, never a second lookup that could silently disagree with it).

Cost Price is fetched per line as soon as a Product is picked (needs Location + Currency + Rate, all already on the header by then). It is stored on the line as a snapshot (`cost_price` column) purely for audit and for the below-cost check — it is never re-derived authoritatively elsewhere.

### Margin % ↔ Selling Price — bidirectional, markup-on-cost
Formula (confirmed with the user — **markup on cost**, not gross-margin-on-price):
```
Selling Price = Cost Price × (1 + Margin% / 100)
Margin%       = (Selling Price − Cost Price) / Cost Price × 100     (Cost Price > 0)
```
Typing into either field recomputes the other live. If Cost Price is 0 or not yet resolved (e.g. product never received via GRN, no cost established), Margin % is disabled for that line and the user must type Selling Price directly.

### Below-cost reason
The moment a line's Selling Price is below its Cost Price (same currency, already guaranteed by the three-way rule above), a **Reason** dropdown appears on that line and becomes mandatory before Save will accept it. Reasons are sourced from `rim_common_masters` under a new `type_key = 'PRICE_BELOW_COST_REASON'` (seeded as a global type in this migration, same pattern as `UNIT`/`BRAND`; the company adds its own actual reason values — e.g. "Clearance," "Promotional Offer," "Competitor Match" — via the existing Common Masters screen, not seeded here). Enforced **inline at entry** (the dropdown itself is the enforcement — Save is blocked client-side until it's chosen) and again as a **hard gate at Approve** (`fn_approve_price_master_batch` re-checks `selling_price < cost_price ⇒ below_cost_reason_id NOT NULL`, since a DRAFT could in principle be saved via direct API access bypassing the UI).

### Barcode / Part Number scan
One header-level field, gated by the company's `enable_barcode`/`enablePartNumber` session flags (same flags Opening Stock introduced — reused here, not duplicated). On submit:
1. Resolve the scanned code against `rim_product_uom.barcode` first (same `getProductByCode`-style lookup Opening Stock already uses: barcode match → part number fallback only if `tryPartNumber` is enabled and barcode didn't match).
2. **If the resolved (product, UOM) pair already has a line in this batch** → do not add a new line; instead scroll to and focus that line's **Margin %** field (per the user's own specified UX — scanning something already priced should let you immediately adjust its margin, not create a duplicate).
3. **If it doesn't** → add a new line for that product, pre-select the matched UOM, fetch its Cost Price, and store the scanned code on the line's own `barcode` column (audit trail of what was actually scanned — same "never default a traceability field from the catalog value" rule as every other barcode-capable screen).
4. **Duplicate barcodes are rejected** — if a second, different scan resolves to a (product, UOM) pair already present, behavior is identical to point 2 (jump, don't duplicate); this is also enforced server-side at Save (see Data Flow) so direct API access can't create two lines sharing a barcode either.

### Status lifecycle
```
DRAFT ──Approve──▶ APPROVED
```
Two states only — no Send/Accept/Reject/Convert pipeline. This is master data with an approval gate, not a customer-facing pipeline document like Sales Quotation.

**Important — Approve is never date-gated.** A batch with a next-month Effective Date approves today exactly the same way a today-dated batch does. Effective Date only controls when `fn_get_active_price` starts returning the row.

### Buttons
| Button | Gate | Behavior |
|---|---|---|
| Save Draft | `canAdd`/`canEdit`, status = DRAFT | Validates Price Type/Customer pairing, ≥1 line, no duplicate (product, UOM) pair, no duplicate barcode, every below-cost line has a reason. Saves header+lines, assigns Entry No on first save. |
| Approve | `canApprove`, status = DRAFT | Re-validates line completeness (non-negative price, below-cost reason present where required). Flips batch to APPROVED. Rejects with a named conflict if another already-APPROVED batch has an identical (location, product, UOM, customer/generic, effective_date) combination. |
| Print | any status once Entry No exists | Produces the batch's PDF — see Print support below. |

### Permissions
`ScreenPermissionMixin`, `screenName = '/sales/price-master'`. `canAdd`/`canEdit` gate Save Draft; `canApprove` gates Approve.

### Company-configurable line fields
`showBarcode` (from `enable_barcode`) and the part-number equivalent (`enablePartNumber`) gate the header scan field, computed once in `build()`, same as every other screen. `showLooseQty` does **not** apply — there is no quantity entry on this screen at all.

### Batch/Serial — explicitly not on this screen
No stock movement of any kind happens here, so there is nothing to allocate a batch or serial number against.

### Period/backdate checks — deliberately skipped
`fn_approve_price_master_batch` does **not** call `fn_check_period_open`/`fn_check_backdate_allowed` — this document never posts to the books at any status.

### Offline support
Full support: Drift local cache table, `price_master_local_ds.dart`, repository `(_remote, _local, _isOffline)` pattern, `SyncEngine` enqueue on Save Draft. **Approve is online-only.**

### Print support
Standard `PrintEngine` integration — the 5-step additive checklist already documented in CLAUDE.md (`print_field_registry.dart`, a `price_master_default_template.dart`, `print_template_provider.dart`, `print_sample_data.dart`, and the screen's own `_buildPrintDocument()`/`_printBatch()`/`_buildPrintButton()`). Reversed from an earlier draft of this doc that recommended skipping print — the user wants it, so it gets the full checklist like any other entry screen.

---

## 5. Data Flow

### Upstream — what this screen reads
| Source | Purpose |
|---|---|
| `rim_products` + `rim_product_uom` | Product picker, per-UOM conversion factor, barcode matching |
| `rim_common_masters` (`type_key = 'UNIT'`) | UOM values |
| `rim_common_masters` (`type_key = 'PRICE_BELOW_COST_REASON'`, new) | Below-cost reason picker |
| `rim_accounts` (`account_nature = 'Customer'`) | Customer picker for Customer-Specific batches |
| `rim_product_location` | `cost_price` (base) / `cost_price_specific` (product's own currency), per Location — the Cost Price display and below-cost check |
| `rim_currencies` / `fn_get_exchange_rate` | Header Currency + Rate to Base |
| `rim_voucher_types` | `PRC` voucher type code + `trans_no_format`; numbering via `fn_next_trans_no` (**per-location** — reversed from an earlier company-wide draft) |
| Session (`UserSession`) | `enableBarcode`, `enablePartNumber`, default location |

### New tables this screen introduces
| Table | Notes |
|---|---|
| `rih_price_master_headers` | Header. Unique key `(client_id, company_id, entry_no, entry_date)`. Carries `location_id` (plain column + numbering input, same shape as Sales Quotation's own `location_id` — not part of the composite identity), `price_type`/`customer_id` (XOR-enforced), `effective_date`, `price_currency_id`/`rate_to_base`/`rate_to_local`. |
| `rid_price_master_lines` | `product_id`, `uom_id`, `uom_conversion_factor` (snapshot), `selling_price`, `cost_price` (snapshot, in the header's currency, for audit + below-cost check — never re-derived authoritatively), `margin_percent` (snapshot, a convenience/audit value like `cost_price` — not re-derived server-side), `below_cost_reason_id` (nullable, required iff `selling_price < cost_price`), `barcode` (audit — what was actually scanned, if anything), `is_tax_inclusive` (display-only — **no `tax_group_id`**, deliberately removed: `rim_products.sales_tax_group_id` is already the authoritative link, so a future Sales Order/Invoice resolves tax group from the product itself rather than a redundant, driftable copy on this line). Also carries its own **snapshotted copies** of the header's `location_id`/`price_type`/`customer_id`/`effective_date`/`status` — needed because the generic/customer-coexistence uniqueness rule is enforced via a partial index at the *line* grain, and a partial index cannot reach across tables to read the header. |

**The core design problem this module solves: a generic price and a customer-specific price for the same location+product+UOM+date must be able to coexist, while two *generic* prices (or two prices for the *same* customer) at the same location+product+UOM+date must not.** Solved with two partial unique indexes on `rid_price_master_lines`, scoped to `status = 'APPROVED'` only:
```sql
CREATE UNIQUE INDEX uq_price_master_generic_active
    ON rid_price_master_lines (client_id, company_id, location_id, product_id, uom_id, effective_date)
    WHERE price_type = 'GENERIC' AND status = 'APPROVED' AND is_deleted = false;

CREATE UNIQUE INDEX uq_price_master_customer_active
    ON rid_price_master_lines (client_id, company_id, location_id, product_id, uom_id, customer_id, effective_date)
    WHERE price_type = 'CUSTOMER' AND status = 'APPROVED' AND is_deleted = false;
```

**Price expiry model: latest effective date wins, open-ended** — unchanged from the original design; still no `effective_to` column, no overlap validation.

New PG functions: `fn_save_price_master_batch`, `fn_approve_price_master_batch`, and the resolver `fn_get_active_price` (now taking a `p_location_id` — location is a hard filter, not a fallback level; only Customer→Generic falls back, never across locations).

### Confirmed: zero GL / zero stock impact
**No call to `fn_post_voucher` or `fn_post_stock_movement` anywhere in this module, at any status.**

### Downstream — what consumes this screen's output
`fn_get_active_price(p_client_id, p_company_id, p_location_id, p_product_id, p_uom_id, p_customer_id, p_as_of_date)` is the **frozen contract** for the not-yet-built Sales Order and Sales Invoice screens — tries the customer-specific price first (only if `p_customer_id` supplied) at that exact location, falls back to the generic price at that same location, returns no rows if nothing qualifies.

### What is NOT in this screen
- No Sales Order screen, no Sales Invoice screen (separate, future)
- No customer-group/tier pricing — no customer-group master exists anywhere in the schema yet
- No quantity-break/slab pricing
- No `effective_to`/expiry column or overlap validation — see the "latest wins" model above
- No discount/promotion logic beyond the below-cost reason audit trail
- No tax group on the line at all — `rim_products.sales_tax_group_id` is the single source of truth; `is_tax_inclusive` is the only tax-related field this screen carries, and even that is reference/display only, never computed here
- No multi-level or threshold-based approval — a single `canApprove` gate only
- No Excel bulk upload in this version

---

*Design agreed: 2026-07-13 (revised same day after discussion — location-wise pricing, currency, margin/cost, below-cost reason, barcode/part-number scan, print)*
*Second screen of the Sales module — builds on Sales Quotation's docs/screens/\*.md workflow.*

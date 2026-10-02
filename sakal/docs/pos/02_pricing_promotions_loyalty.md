# Pricing, Promotion, Bundle & Loyalty Design

## 1. Pricing/discount/tax/rounding sequence

Deterministic, computed once per line, in this fixed order (matching the
reference BRD's §10, mapped onto SAKAL's existing primitives):

```
1. Product price           -> fn_get_active_price(..., p_target_currency = invoice currency)
2. Quantity                -> base_qty (pack/loose, per rim_product_uom.conversion_factor)
3. Gross line amount       -> price × base_qty
4. Line discount           -> manual cashier/supervisor discount (ric_user_sales_controls governance, unchanged from Quick Invoice)
5. Scheme/promotion        -> rim_pos_schemes applied automatically (see §2), its own discount column, never merged into #4
6. Taxable amount          -> gross - line discount - scheme discount (or + for a tax-inclusive price, per tax group config)
7. Tax                     -> rim_tax_groups / fn_get_active_tax_rate, unchanged from Quick Invoice
8. Bill-level adjustments  -> header discount %, charges (freight etc.) — unchanged apportionment formula from Quick Invoice
9. Rounding                -> see below
10. Final payable amount
```
`price_source` on `rid_sales_invoice_lines` already distinguishes
`PRICE_MASTER/QUOTATION/ORDER/MANUAL_OVERRIDE` — POS reuses this unchanged.
`discount_amount` (manual) and `scheme_discount_amount` (automatic) are two
separate columns so a report can always tell a cashier's own discount from a
promotion's, even when both apply to the same line.

### Minimum selling price floor (folded into Phase 1, 2026-10-02)
Immediately after the line discount/scheme step, if `rim_products.min_selling_price`
is set, the resulting per-unit price is clamped to never go below it —
checked server-side in `fn_save_sales_invoice`, same "server is authoritative,
client preview is UX only" rule as every other computed field. In v1 this is
a hard block (`BELOW_MINIMUM_PRICE`), not overridable even by a supervisor —
a future, more permissive override tier can be added later if a real need
appears, but starting hard-blocked is the safer default for a floor that
exists specifically to stop a sale going out below cost.

### Weighted products
A weighted line's qty IS the weight (already a decimal field, nothing new
there) — resolved either by scanning a weight/price-embedded barcode
(`ric_companies.weighted_barcode_prefix`/`weighted_barcode_format`, parsed
client-side straight from the scanned digits) or by the cashier typing the
weight manually when no barcode/scale applies. `rim_products.is_weighted`
(via the existing flags mechanism) is what tells the New Sale screen to
accept a decimal weight instead of a whole-unit count and to skip the usual
"pack vs. loose" qty split for that line. A real connected scale integration
is Phase 2 hardware work; the barcode-parsing and manual-entry paths above
need no hardware at all and ship in v1.

### Age-restricted / controlled sale
A line whose product has `is_age_restricted` set (via the existing flags
mechanism) requires the cashier to tap a simple "ID Verified" confirmation
before the line can be added — no new column on the line itself; the
confirmation is written to `rih_pos_audit_log` (action_code
`AGE_RESTRICTED_SALE_CONFIRMED`, `reference_doc_type='SALES_INVOICE'`) for
audit, same table `08_reporting_audit.md` already specifies. A company can
additionally require a supervisor PIN (not just the cashier's own
confirmation) for this prompt via the same real-time PIN-override mechanism
already built for discounts (`05_returns_exchange_void_approvals.md` §0) —
configurable, default off (cashier self-confirms).

### Quick-pick grid
`rim_products.is_quick_pick` (via the existing flags mechanism) marks a
product for the New Sale screen's tappable grid — meant for common,
frequently-unbarcoded items (loose produce, bakery) where searching by name
is slower than a dedicated button. Purely a read of already-existing product
data filtered by this one flag; no new table, no per-terminal configuration
needed (the flag is company-wide, same granularity as every other product
flag in this schema).

### Rounding
Every currency's decimal places already come from `ric_companies`' per-currency
number-format settings (migration 091) — POS reuses this, no new config.
Any rounding adjustment on a cash sale (e.g. rounding a 9,998 CDF total to
10,000 because 2 CDF coins don't exist) is stored as its own explicit line —
a new `rid_sales_invoice_lines.line_type = 'ROUNDING'` row (or a header
`rounding_adjustment_amount` column, mirroring how `charges_amount` already
sits beside line-level amounts) — never silently absorbed into the tender
amount. Reconciles the exact bill-reconciliation principle the reference BRD's
§10.4 calls for.

## 2. Promotion / scheme engine

### Types supported (all 10 from the reference BRD, mapped to `rim_pos_schemes.scheme_type`)
Percentage off, fixed amount off, Buy X Get Y (free), Buy X Get a discount,
fixed price for N qty, mix & match, slab/tiered quantity pricing, free item,
bill-threshold ("spend $200, get $20 off"), and coupon (scanned/typed code).

### Overlap resolution (deterministic, per the BRD's explicit requirement)
1. Filter to schemes whose `start/end_date`, `start/end_time`, `location_ids`,
   and product/category/customer-tier scope all match the current line/bill.
2. Order by `priority ASC` (lower number wins first).
3. Apply the first matching scheme. If `is_stackable = true`, continue
   applying subsequent matching schemes (also stackable) in priority order;
   stop at the first non-stackable match otherwise.
4. Never depend on insertion order or a bare `SELECT` with no `ORDER BY` —
   the priority column is the only deterministic input.
5. Respect `usage_limit_total`/`usage_limit_per_customer` (checked against a
   running count derived from `rid_sales_invoice_lines.applied_scheme_id`,
   same pattern as any other usage cap in this schema — no separate counter
   table, a `COUNT(*)` query is sufficient at this volume).

### Cashier-visible explanation
Every applied scheme writes a human-readable snapshot onto the line
(`applied_scheme_id` + a denormalized `scheme_name_snapshot` text column) so
the cart/receipt can show "Buy 2 Get 1 Free — Promo: Weekend Snack Deal"
without a join back to a scheme that might later be edited or deactivated —
same "snapshot what was applied, never recompute from current config"
principle the reference BRD states explicitly in §11.

### Server-side authority
Exactly like every other pricing/tax/discount computation in this schema
(GRN tax, Sales Invoice tax/discount), the scheme engine's real computation
lives in `fn_save_sales_invoice` (extended, additively) — the client previews
it for speed/UX but the server recomputes and is authoritative, per
CLAUDE.md's existing "never trust the client payload for a frozen/computed
field" rule.

## 3. Bundle sales

See `01_data_model.md` §6 for the table shapes. Business rule: a completed
bundle sale is always traceable to its real component consumption — the
receipt shows the bundle as one line (its own price, its own promotion
eligibility), while `rid_sales_invoice_line_bundle_components` carries the
component breakdown for costing/COGS and inventory audit. A `DYNAMIC_MIX`
bundle is realized entirely through the scheme engine (`MIX_AND_MATCH`) —
no separate "bundle explosion" code path for it, since the customer's actual
component picks aren't knowable until checkout.

## 4. Loyalty program

### Rule configuration (`rim_loyalty_programs`, per `01_data_model.md`)
Points per monetary amount, optional per-product/category override (a second,
narrower rule row scoped to a category via `rim_item_categories`), bonus
campaign points (modeled as a `MANUAL_ADJUSTMENT`/`BONUS` ledger entry, not a
separate campaign table in v1), customer-tier multiplier, minimum points to
redeem, maximum redemption per transaction and as a % of the bill, point value
in base currency, expiry period, and `earn_basis` (pre-tax/post-tax/post-
discount — default post-discount, pre-tax, matching the most common retail
convention and avoiding points earned on tax paid to the government).

### Earn
At `fn_approve_sales_invoice` time (additive to the existing function): if
the invoice carries a `loyalty_profile_id` (set when the cashier captured a
mobile number), compute points on the qualifying amount and insert one
`EARN` row into `ril_loyalty_ledger`, `source_doc_type='SALES_INVOICE'`.

### Redeem
A `tender_method='LOYALTY_POINTS'` row on `rid_pos_tender_lines` with
`tender_amount` expressed in the invoice's own currency; at approve time this
posts a `REDEEM` ledger row (negative `points_change`) sized by
`point_value_in_base_currency`, and the GL leg is a normal sale-discount-style
reduction (no separate liability account needed in v1 — the discount is
realized immediately against the same sale it's used on, unlike a gift card
which is a true deferred liability).

### Reversal on return
`fn_approve_sales_return` (additive) looks up whether the original sale's
lines carried an `EARN` ledger entry and posts a proportional
`RETURN_REVERSAL` (points reversed in the same ratio as the returned amount
to the original sale amount); if the original sale redeemed points on that
line, the redeemed points are **not** restored automatically — a manual
`MANUAL_ADJUSTMENT` is required, since re-crediting a spent point
automatically on every return is a known fraud vector in every loyalty system
researched (Odoo, Square) and is explicitly left as a controlled, audited,
supervisor-only action.

### A customer with no account
The `rih_customer_loyalty_profiles` row is sufcient on its own — no
`rim_accounts` customer required. If the business later wants to convert a
loyalty profile into a real credit/account customer, that's a manual,
explicit action (mirrors Sales Order's existing prospect→customer conversion
pattern, `fn_convert_prospect_to_customer` — same shape, different source
table) — out of scope for POS v1 itself.

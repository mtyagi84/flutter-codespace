# POS Data Model

Every table below follows SAKAL's existing conventions unless noted: prefix by
layer (`ric_`=config, `rim_`=master, `rih_`=transaction header, `rid_`=
transaction line, `ril_`=immutable ledger), `client_id`+`company_id` on every
row (+`location_id` where the concept is location-scoped), `auth_rw_<table>`
RLS policy, `is_active`/`is_deleted` soft-delete, `CREATE ... WITH
(security_invoker = true)` on every view. Grep every migration that touches a
reused function before extending it (per CLAUDE.md's "Check Latest Function
Signature" rule) — this document is a design, not a verbatim migration.

## 1. Terminals, devices, and shift

### `ric_pos_terminals`
The logical checkout counter — register number, not the physical hardware.
```
id, client_id, company_id, location_id -> ric_locations,
terminal_code, terminal_name,
receipt_paper_profile TEXT CHECK (RECEIPT_58MM, RECEIPT_80MM),
default_cash_account_local_id -> rim_accounts,  -- Cash-nature account for this till's local-currency drawer
default_cash_account_base_id  -> rim_accounts,  -- base-currency drawer, mirrors ric_user_quick_invoice_setup's pair
is_active, is_deleted
UNIQUE (client_id, company_id, location_id, terminal_code)
```
A terminal's own default cash accounts are a **fallback** — a cashier's own
`ric_user_quick_invoice_setup` cash accounts (if set) still win for a Quick
Invoice-style walk-up sale; the terminal default exists for a shared-till
environment where several cashiers rotate through one physical register and
the drawer itself (not the cashier) is the actual GL cash pool.

### `ric_pos_devices`
Physical hardware registration/binding — nothing like this exists today.
```
id, client_id, company_id, location_id,
device_uid TEXT,          -- stable client-generated id, stored in secure storage on first run
device_name, platform TEXT CHECK (WEB, ANDROID, WINDOWS, IOS),
bound_terminal_id -> ric_pos_terminals,  -- NULL = not yet bound
app_version, last_seen_at, last_sync_at,
failed_pin_attempts INTEGER DEFAULT 0, pin_locked_until TIMESTAMPTZ,  -- PIN-login lockout is device-scoped, see 06_access_security.md §4
is_blocked BOOLEAN DEFAULT false,
is_active, is_deleted
UNIQUE (client_id, company_id, device_uid)
```
`rim_users` gains `pin_hash TEXT` (bcrypt, same convention as `password_hash`)
— the till's only credential; see `06_access_security.md` §4 for the full
PIN login/uniqueness/lockout design. `ric_companies` gains
`pos_idle_lock_minutes INTEGER DEFAULT 3` (§4's till idle-lock).

## 1a. Five gaps folded into Phase 1 (user decision, 2026-10-02) — all
deliberately designed to add ZERO new tables and at most one or two nullable
columns on existing master tables, never new per-transaction rows:

- **Weighted products**: `ric_companies` gains
  `weighted_barcode_prefix TEXT` (e.g. `'20'`-`'29'`, the common supermarket
  convention) and `weighted_barcode_format TEXT CHECK (WEIGHT_EMBEDDED,
  PRICE_EMBEDDED)`. A scanned barcode matching the configured prefix is
  parsed client-side (product code + weight or price decoded straight from
  the barcode's own digits, per the configured format) — no new table, no
  server round-trip beyond the normal product lookup by the decoded code.
  `rim_products` gets a new `is_weighted` flag via the **existing**
  `rim_product_flag_types`/`flags` JSONB mechanism (zero schema change — this
  is exactly what that mechanism exists for). Manual weight entry (no
  barcode, or no connected scale) reuses the line's own existing qty field —
  weight IS qty for a weighted product, already decimal-capable. An actual
  connected scale (serial/USB/Bluetooth) is the one piece of this that's
  real Phase-2 hardware integration; barcode parsing and manual entry are
  both Phase 1, pure logic, no new hardware dependency.
- **Minimum selling price floor**: one new nullable column,
  `rim_products.min_selling_price NUMERIC` (base currency). Checked at
  discount/override time (`02_pricing_promotions_loyalty.md` §1) — a hard
  floor no discount, including a supervisor override, can cross in v1. Master-
  data column on an existing table — negligible size impact, nothing like a
  new transactional table.
- **Age-restricted / controlled sale**: a new `is_age_restricted` flag via the
  same existing `flags` JSONB mechanism — zero schema change. Confirmation is
  recorded in the already-planned `rih_pos_audit_log` (action_code
  `AGE_RESTRICTED_SALE_CONFIRMED`) rather than a new per-line column — reuses
  a table this design already needed anyway.
- **Quick-pick grid**: a new `is_quick_pick` flag via the same `flags`
  mechanism — an admin toggles it on ~20-40 common unbarcoded items; the New
  Sale screen renders them as a tappable grid alongside search. No new table.
`fn_login` (or a new `fn_pos_device_checkin` called right after login) checks
`is_blocked` and raises `DEVICE_BLOCKED`. Binding a device to a terminal is an
explicit admin/manager action, not automatic on first login.

### `ric_user_pos_terminal_access`
Mirrors `ric_user_location_access`'s shape exactly, one level down.
```
id, client_id, company_id, user_id -> rim_users, terminal_id -> ric_pos_terminals,
access_type TEXT CHECK (PERMANENT, TEMPORARY, SHIFT_BASED) DEFAULT 'PERMANENT',
valid_from, valid_to,   -- NULL/NULL for PERMANENT
is_active, is_deleted
UNIQUE (client_id, company_id, user_id, terminal_id)
```
Store access is `ric_user_location_access` (already exists, unchanged) — POS
terminal access is a prerequisite check layered on top: a cashier must have
both location access AND an active (date-effective) row here for the specific
terminal being opened. A `v_user_accessible_pos_terminals` view (mirroring
`v_user_accessible_locations`'s "zero rows = unrestricted" convention is
**not** used here — a missing row always means no access, since a till is a
money-handling context, not a visibility filter) resolves this for the login
check and the terminal picker.

### `rih_pos_shifts`
The cash-control period for one terminal. One terminal has at most one `OPEN`
shift at a time (partial unique index).
```
id, client_id, company_id, location_id, terminal_id -> ric_pos_terminals,
shift_no TEXT,              -- per-terminal sequence, e.g. SFT/{TERMINAL}/{YYYY}/{SEQ}
cashier_id -> rim_users,
opened_at, closed_at,
status TEXT CHECK (OPEN, CASH_UP_PENDING, CLOSED) DEFAULT 'OPEN',
opening_notes, closing_notes,
expected_cash_local NUMERIC, expected_cash_base NUMERIC,   -- computed at cash-up time, see formula below
counted_cash_local NUMERIC, counted_cash_base NUMERIC,     -- from denomination counts (or a direct total)
variance_local NUMERIC, variance_base NUMERIC,
variance_reason TEXT,
variance_approved_by -> rim_users, variance_approved_at,
opening_approved_by -> rim_users,  -- only populated if the company requires approval to open with a non-standard float
is_deleted
UNIQUE (client_id, company_id, terminal_id) WHERE status = 'OPEN'
```
`rih_sales_invoices` gains a nullable `pos_shift_id -> rih_pos_shifts` —
nullable because back-office Quick Invoice/credit-sale rows never set it.
`rih_pos_payouts` and `rid_pos_tender_lines`'s own header (the sales invoice)
both link back to the same `pos_shift_id`, so every cash movement for a shift
is findable with one filter.

### `rih_pos_shift_opening_float`
One row per currency the shift opened with (a till often starts with both
local and foreign-currency notes on hand).
```
id, client_id, company_id, shift_id -> rih_pos_shifts,
currency_id -> rim_currencies, opening_amount NUMERIC
UNIQUE (shift_id, currency_id)
```

### `rid_pos_shift_denomination_counts`
The literal note/coin count at cash-up — per shift, per currency, per
denomination. `rim_currency_denominations` (new, global per currency: `100,
50, 20, 10, 5, 1` etc., company-editable) backs the picklist.
```
id, client_id, company_id, shift_id -> rih_pos_shifts,
currency_id -> rim_currencies, denomination_value NUMERIC, count INTEGER,
line_total NUMERIC GENERATED ALWAYS AS (denomination_value * count) STORED
```

### Expected cash formula (per currency, computed at cash-up)
```
Expected Closing Cash =
    Opening Float
  + Cash Sales (tender_method = 'CASH', that currency)
  + Cash-In movements
  + Cash Refund Reversals (a cash payment collected back on a return's own
    cash refund tender line counts as a reduction, not an addition — see
    04_shift_cash_management.md)
  - Cash Refunds Paid Out
  - Payouts
  - Cash Drops
```
Non-cash tender lines (card/mobile/voucher/loyalty) never touch this formula.

## 2. Tender (multi-currency split payment)

### `rid_pos_tender_lines`
Replaces the single `collected_amount_local/base` pair on `rih_sales_invoices`
for POS sales — one row per payment instrument applied to one invoice (back-
office Quick Invoice keeps using the existing pair unchanged; this table is
POS-only, `rih_sales_invoices.id`-linked).
```
id, client_id, company_id, invoice_id -> rih_sales_invoices, serial_no,
tender_method TEXT CHECK (CASH, CARD, MOBILE_MONEY, VOUCHER, GIFT_CARD,
                          STORE_CREDIT, CUSTOMER_ACCOUNT, LOYALTY_POINTS),
currency_id -> rim_currencies, tender_amount NUMERIC,
exchange_rate NUMERIC,              -- tender currency -> invoice currency, from fn_get_exchange_rate, versioned by storing it here
base_equivalent_amount NUMERIC,     -- tender_amount * rate-to-base, for the cash-up formula and reconciliation reports
reference_no TEXT,                  -- card/mobile transaction reference
status TEXT CHECK (PENDING, SUCCESS, FAILED, CANCELLED, REFUNDED) DEFAULT 'SUCCESS',
change_given_amount NUMERIC, change_given_currency_id -> rim_currencies  -- only meaningful on a CASH line when change is returned in a different currency than tendered
```
Settlement into GL reuses exactly the mechanism Quick Invoice already has for
cash collection (composing `fn_save_finance_voucher`/`fn_post_finance_voucher`
directly, `voucher_type_code='CRV'`, never `fn_post_voucher`) — extended to
loop over every `rid_pos_tender_lines` row instead of the single collected-
amount pair, one settlement leg per distinct currency, and a non-cash leg
(card/mobile/voucher) posts to that tender method's own configured clearing
account (`rim_account_link_types` gains `CARD_CLEARING_ACCOUNT`,
`MOBILE_MONEY_CLEARING_ACCOUNT`, `GIFT_CARD_LIABILITY_ACCOUNT`, resolved via
`fn_resolve_company_account_link`, same pattern as `EXCHANGE_GAIN_LOSS_ACCOUNT`).
Full detail in `03_payments_multicurrency.md`.

### `rih_pos_payouts`
Cash-in, cash-out, payout, and cash-drop are one table with a `movement_type`
— all four are "cash leaves or enters the drawer outside a sale."
```
id, client_id, company_id, shift_id -> rih_pos_shifts,
payout_no TEXT,   -- per-terminal sequence
movement_type TEXT CHECK (CASH_IN, CASH_OUT, PAYOUT, CASH_DROP),
direction TEXT CHECK (IN, OUT),           -- CASH_IN=IN, the other three=OUT; stored for a simple SUM() in the cash-up formula
amount NUMERIC, currency_id -> rim_currencies,
reason_id -> rim_common_masters,          -- new rim_common_master_types row: POS_CASH_MOVEMENT_REASON
gl_account_id -> rim_accounts,            -- required only for PAYOUT (an expense); NULL for CASH_IN/OUT/DROP (pure cash reclassification)
reference_no, attachment_url,
created_by -> rim_users, approved_by -> rim_users,  -- approved_by NULL until above-threshold approval clears
is_deleted
```
A `PAYOUT` above the configured threshold (see `11_open_decisions.md`,
DEC-08) posts only once `approved_by` is set — same supervisor-verification
pattern as a discount override (`fn_verify_discount_override`), reused here.

## 3. Hold / suspended sale

**No new table.** `rih_sales_invoices.status` CHECK gains `'HELD'` alongside
`DRAFT/APPROVED/CANCELLED`. A held sale is a DRAFT-shaped row (lines/charges
already staged via the existing `fn_save_sales_invoice`) that the cashier
explicitly marks held rather than completing; "Resume" re-opens the exact same
resume-a-DRAFT UI path Quick Invoice already has. Per the source BRD's DEC-04
("recommended default: no"), a `HELD` invoice does **not** reserve stock — the
existing FEFO/negative-stock check simply re-runs at the point of actual
completion, same as any other DRAFT resume. An optional `hold_expires_at`
timestamp on the header lets a company auto-expire abandoned holds (a
scheduled job cancels them, never silently deletes).

## 4. Loyalty

Phone-number-first per the user's explicit decision — a POS sale never needs
a real `rim_accounts` customer to earn/redeem points.

### `rim_loyalty_programs`
Company-level configuration (usually one row per company).
```
id, client_id, company_id, program_name,
points_per_amount NUMERIC,         -- e.g. 1 point per 10 (base currency)
point_value_in_base_currency NUMERIC,  -- redemption value of 1 point
min_points_to_redeem INTEGER,
max_redemption_percent_of_bill NUMERIC,  -- caps how much of a bill points can cover
tier_multiplier_enabled BOOLEAN,
expiry_months INTEGER,             -- NULL = points never expire
earn_basis TEXT CHECK (PRE_TAX, POST_TAX, POST_DISCOUNT) DEFAULT 'POST_DISCOUNT',
is_active
```

### `rih_customer_loyalty_profiles`
```
id, client_id, company_id,
mobile_number TEXT,                -- the identifying key the cashier actually asks for
customer_id -> rim_accounts NULL,  -- optional real-customer link, set only if/when one is created later
display_name TEXT,                 -- whatever name the customer gives at enrollment, not authoritative
tier_id -> rim_common_masters NULL,  -- new type LOYALTY_TIER
points_balance NUMERIC DEFAULT 0,  -- denormalized cache of ril_loyalty_ledger, never the source of truth
is_active
UNIQUE (client_id, company_id, mobile_number)
```

### `ril_loyalty_ledger`
Immutable, append-only — mirrors `ril_stock_ledger`'s "the ledger is the one
source of truth, never a mutable balance column alone" principle.
```
id, client_id, company_id, loyalty_profile_id -> rih_customer_loyalty_profiles,
trans_type TEXT CHECK (EARN, REDEEM, EXPIRE, RETURN_REVERSAL, BONUS,
                       MANUAL_ADJUSTMENT, CANCEL_REVERSAL),
points_change NUMERIC,             -- signed: +earn/bonus, -redeem/expire
source_doc_type TEXT, source_doc_no TEXT, source_doc_date DATE,  -- same traceability convention as rid_finance_lines
reason TEXT,                       -- mandatory for MANUAL_ADJUSTMENT
created_by -> rim_users, created_at
```
`points_balance` on the profile is recomputed by a trigger (or read as
`SUM(points_change)` directly in reports) — the column exists purely so the
POS screen doesn't have to aggregate the whole ledger on every scan.

## 5. Schemes / promotions

### `rim_pos_schemes`
```
id, client_id, company_id,
scheme_code, scheme_name,
scheme_type TEXT CHECK (PERCENT_OFF, AMOUNT_OFF, BUY_X_GET_Y, BUY_X_GET_DISCOUNT,
                        FIXED_PRICE_QTY, MIX_AND_MATCH, SLAB_QUANTITY, FREE_ITEM,
                        BILL_THRESHOLD, COUPON),
scope TEXT CHECK (PRODUCT, CATEGORY, CUSTOMER_TIER, BILL),
priority INTEGER,                  -- lower runs first; the deterministic tie-breaker, never query/insertion order
is_stackable BOOLEAN DEFAULT false,
start_date, end_date, start_time, end_time,  -- time window for happy-hour-style schemes
location_ids UUID[] NULL,          -- NULL = all locations
max_discount_amount NUMERIC,
usage_limit_total INTEGER, usage_limit_per_customer INTEGER,
coupon_code TEXT,                  -- only for scheme_type='COUPON'
is_active
```

### `rim_pos_scheme_rules`
The condition/benefit detail — one scheme can have several rule rows (e.g. a
SLAB_QUANTITY scheme's 1-2/3-5/6+ bands).
```
id, client_id, company_id, scheme_id -> rim_pos_schemes,
applies_to_product_id -> rim_products NULL, applies_to_category_id -> rim_item_categories NULL,
min_qty NUMERIC, max_qty NUMERIC NULL,
benefit_type TEXT CHECK (PERCENT, FIXED_AMOUNT, FIXED_PRICE, FREE_QTY),
benefit_value NUMERIC,
free_product_id -> rim_products NULL   -- for BUY_X_GET_Y / FREE_ITEM
```

A scheme applies automatically at the line level — never a manual cashier
step — the same way a tax group already applies. `rid_sales_invoice_lines`
gains a nullable `applied_scheme_id -> rim_pos_schemes` + `scheme_discount_amount`
(additive columns, alongside the existing `discount_amount` from a manual/
header discount — the two are summed, never conflated, so a report can always
separate "cashier discount" from "promotion discount"). Full engine design
(overlap/priority/stacking resolution) in `02_pricing_promotions_loyalty.md`.

## 6. Bundles / bouquets

### `rim_product_bundles`
A bundle is itself a row in `rim_products` (so it has its own barcode, price,
tax group, and can be scanned like any product) — this table only adds the
bundle-specific metadata.
```
id, client_id, company_id, bundle_product_id -> rim_products UNIQUE,
bundle_mode TEXT CHECK (COMMERCIAL, PREASSEMBLED, DYNAMIC_MIX),
```
- `COMMERCIAL` — sold as one SKU/price; components auto-consumed from stock at
  sale time (no separate bundle stock).
- `PREASSEMBLED` — the bundle product itself carries real stock
  (`rim_product_location.current_stock`), built by a separate assembly
  transaction (out of scope here — a future Inventory "Kit Assembly" module);
  a POS sale of it just deducts the bundle's own stock like any product.
- `DYNAMIC_MIX` — the customer picks components from a rule set at the till
  (e.g. "any 3 of these 10 snacks for $5"); modeled as a `rim_pos_schemes`
  row with `scheme_type='MIX_AND_MATCH'` referencing the bundle's component
  group, not a separate bundle-component consumption path.

### `rim_bundle_components`
Only populated for `COMMERCIAL` and `PREASSEMBLED` bundles.
```
id, client_id, company_id, bundle_id -> rim_product_bundles,
component_product_id -> rim_products, component_qty NUMERIC,
component_rate_contribution NUMERIC   -- this component's share of the bundle price, for GL/costing apportionment
```
At sale time (`COMMERCIAL` mode), one POS line explodes into N stock
movements (one `fn_post_stock_movement` call per component, same "no
aggregation across lines" precedent as GRN/Material Issue) while the GL
posting and the receipt still show one line — the bundle's own `product_id`
on `rid_sales_invoice_lines`, with the component breakdown held in a new
child table `rid_sales_invoice_line_bundle_components` (bundle line's
`serial_no` + each component + qty + cost) purely for traceability/costing,
mirroring how `rid_transaction_line_batches` already shadows a line without
changing what the line itself displays.

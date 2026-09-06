# Finance — Exchange Rates
## Screen Design Specification

**Module:** Finance → Setup
**Status:** Design agreed — SQL + Flutter pending

---

## Purpose

Enter daily buying and selling exchange rates per location. Rates are used by all transaction screens to auto-calculate base and local currency amounts.

---

## Business Rules

### Rate storage
- Rates stored **per location** — each city/branch can have slightly different rates.
- One row per `(company, location, rate_date, from_currency, to_currency)`.
- `from_currency` is always the **company's base currency** (e.g. USD).
- `to_currency` is the target currency (CDF, ZMW, EUR, GBP…).
- Only **active currencies** (from `rim_currencies` where `is_active = true`) are shown.

### Three columns stored (revised 2026-09-06 — see below)
| Column | Meaning |
|---|---|
| `buying_rate` | Reference rate for when the company actually buys foreign currency (real treasury/forex operation) |
| `selling_rate` | Reference rate for when the company actually sells foreign currency (real treasury/forex operation) |
| `exchange_rate` | The rate actually used for every Sales/Purchase/Inventory currency conversion — independently user-entered, no relationship to buying/selling |

### Which rate is used at transaction time — REVISED 2026-09-06

**Real bug found and fixed**: the original design below (SELLING to convert TO local, BUYING to convert
FROM local) was implemented inconsistently — `fn_save_sales_invoice`'s cost-price conversion used the
shared function's default (`MID`) while `fn_get_active_price`'s selling-price conversion explicitly
hardcoded `SELLING`. Two different rates for what should be one conversion on one document caused stock/
COGS to never fully zero out even after 100% of purchased stock was sold (verified via exact arithmetic
match against live data — see migration 179's own header comment for the full trace).

Investigated how Odoo handles this: one rate per currency per day, used uniformly across Sales/Purchase/
Inventory — Buying/Selling spread is a treasury/forex concept, not something that should vary the rate
used across transactional modules. Confirmed this app's own Contra Voucher (the one module doing real
currency-exchange treasury transactions) doesn't call `fn_get_exchange_rate` at all — the user types both
real amounts directly and the system computes the difference as an Exchange Gain/Loss plug.

**Current rule**: `exchange_rate` (the renamed `mid_rate`, now independently user-entered rather than
`(buying+selling)/2`) is used for **every** Sales/Purchase/Inventory conversion — `fn_get_exchange_rate`'s
default `p_rate_type` (`'MID'`) reads this column. `buying_rate`/`selling_rate` are stored and remain
selectable via `fn_get_exchange_rate`'s `p_rate_type` parameter, but nothing currently calls it with
`'BUYING'`/`'SELLING'` — reserved for a future screen that needs them explicitly (e.g. an enhanced Contra
Voucher).

### Cross-rates (e.g. EUR → CDF)
Derived via base currency: EUR→USD→CDF. Accurate enough for bookkeeping; in DRC there is no direct EUR/CDF market — forex bureaus use USD as intermediate anyway.

### Copy to All Locations
Button replicates today's rates from the current location to all other active locations in the same company (`fn_replicate_exchange_rates`). Users can still override per-location after replication.

### Rate lookup logic
`fn_get_exchange_rate` returns the **most recent rate where `rate_date <= transaction_date`**. If no rate exists for or before the transaction date, the function raises an error — user must enter a rate first.

### API rates
Manual entry only in v1. `[Fetch Online]` button is reserved in the UI (greyed out). Schema already has `source` column (MANUAL | API) — no schema change needed when API is added later.

---

## Tables

### `rim_exchange_rates`
| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| client_id | uuid NOT NULL FK | ric_clients |
| company_id | uuid NOT NULL FK | ric_companies |
| location_id | uuid NOT NULL FK | ric_locations |
| rate_date | date NOT NULL | effective date |
| from_currency | text NOT NULL | always company base currency |
| to_currency | text NOT NULL | target currency |
| buying_rate | numeric(18,8) NOT NULL | reference only — not currently used by any calculation |
| selling_rate | numeric(18,8) NOT NULL | reference only — not currently used by any calculation |
| exchange_rate | numeric(18,8) NOT NULL | renamed from `mid_rate` (migration 179) — independently user-entered, no longer generated; used everywhere for Sales/Purchase/Inventory conversions |
| source | text DEFAULT 'MANUAL' | MANUAL \| API |
| standard tenant + audit columns | | is_active, is_deleted, created_at/by, updated_at/by |

Unique constraint: `(client_id, company_id, location_id, rate_date, from_currency, to_currency)`

---

## PG Functions

### `fn_get_exchange_rate`
```
fn_get_exchange_rate(
  p_company_id    uuid,
  p_location_id   uuid,
  p_from_currency text,
  p_to_currency   text,
  p_rate_date     date,
  p_rate_type     text   -- 'BUYING' | 'SELLING' | 'MID'
)
RETURNS numeric
```
- Returns 1 if `from_currency = to_currency` (no conversion needed).
- Returns most recent rate where `rate_date <= p_rate_date`.
- RAISES EXCEPTION if no rate found (forces user to enter rate before transacting).

### `fn_replicate_exchange_rates`
```
fn_replicate_exchange_rates(
  p_client_id     uuid,
  p_company_id    uuid,
  p_from_location uuid,
  p_rate_date     date,
  p_replicated_by uuid
)
RETURNS integer  -- number of location×currency rows updated
```
- Copies all rates for `p_rate_date` from source location to all other active locations.
- Uses UPSERT — if target location already has a rate for that day, it is overwritten.

---

## Screen Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Exchange Rates                                          [Save Rates]    │
│  Location: [Kinshasa ▼]            Date: [2026-09-06]                    │
│                                                                           │
│  [Copy from Previous Date]   [Copy to All Locations]                     │
├──────────────────┬──────────────┬─────────────┬─────────────────────────┤
│  Currency        │  Buying      │  Selling    │  Exchange Rate          │
├──────────────────┼──────────────┼─────────────┼─────────────────────────┤
│  CDF (Fr. Congo) │  2,800.0000  │  2,850.0000 │  2,825.0000             │
│  ZMW (Zambian K) │    25.8000   │    27.2000  │    26.5000              │
│  EUR (Euro)      │     0.9250   │     0.9350  │     0.9300              │
│  GBP (Pound)     │     0.7850   │     0.7950  │     0.7900              │
└──────────────────┴──────────────┴─────────────┴─────────────────────────┘
│  Base currency: USD   Showing active currencies only                    │
└──────────────────────────────────────────────────────────────────────────┘
```

- All three columns (Buying, Selling, Exchange Rate) are independently user-editable fields — Exchange
  Rate is **not** derived from Buying/Selling anymore (see the 2026-09-06 revision above).
- All three are mandatory — a row cannot be saved unless every one is filled in.
- Save Rates lives top-right in the header bar (moved 2026-09-06 to match every other entry screen's
  convention — was previously a body-level button at the bottom of the page).
- "Copy from Previous Date" loads the last entered rates (all three) as starting values.
- Rows for inactive currencies are hidden.

---

## What is NOT in this screen

- Currency master setup (currency codes, names, symbols) — separate master screen
- Bank reconciliation rates — handled in Cheque Register screen
- Historical rate report — separate report

---

*Design agreed: 2026-06-21*
*Rate type parameter: BUYING | SELLING | MID*
*Location-level rates with one-click replication to all locations*

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

### Three columns stored
| Column | Meaning |
|---|---|
| `buying_rate` | Rate when company BUYS foreign currency from customer/supplier (customer gives USD, company records at this rate) |
| `selling_rate` | Rate when company SELLS foreign currency to customer (customer pays in local from USD-priced invoice) |
| `mid_rate` | Always `(buying + selling) / 2` — auto-calculated, stored column, never manually entered |

### Which rate is used at transaction time

| Situation | Rate passed |
|---|---|
| USD-priced invoice → CDF amount | SELLING |
| Customer pays USD to settle CDF invoice | BUYING |
| USD-priced bill → CDF payment amount | SELLING |
| Paying supplier in USD against CDF bill | BUYING |

Rule: converting **TO** local currency → SELLING. Converting **FROM** local currency → BUYING.

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
| buying_rate | numeric(18,8) NOT NULL | |
| selling_rate | numeric(18,8) NOT NULL | |
| mid_rate | numeric(18,8) GENERATED | `(buying + selling) / 2` — stored, never manually set |
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
┌──────────────────────────────────────────────────────────────┐
│  Exchange Rates                                               │
│  Location: [Kinshasa ▼]            Date: [2026-06-21]        │
│                                                               │
│  [Copy from Previous Date]   [Copy to All Locations]          │
│                                         [Fetch Online ▸ soon]│
├──────────────────┬──────────────┬─────────────┬──────────────┤
│  Currency        │  Buying      │  Selling    │  Mid (auto)  │
├──────────────────┼──────────────┼─────────────┼──────────────┤
│  CDF (Fr. Congo) │  2,780.0000  │  2,820.0000 │  2,800.0000  │
│  ZMW (Zambian K) │    25.8000   │    27.2000  │    26.5000   │
│  EUR (Euro)      │     0.9250   │     0.9350  │     0.9300   │
│  GBP (Pound)     │     0.7850   │     0.7950  │     0.7900   │
└──────────────────┴──────────────┴─────────────┴──────────────┘
│  Base currency: USD   Showing active currencies only          │
│                                             [Save Rates]      │
└──────────────────────────────────────────────────────────────┘
```

- Buying and Selling are user-editable fields.
- Mid is read-only — always shows `(B + S) / 2`.
- "Copy from Previous Date" loads the last entered rates as starting values.
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

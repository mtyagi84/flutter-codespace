-- ============================================================
-- 179_exchange_rate_independent_and_price_uses_default_rate.sql
--
-- Real bug traced to its exact root cause: fn_save_sales_invoice (121)
-- computes a line's cost_price via fn_get_exchange_rate with no explicit
-- rate type (defaults 'MID'), while fn_get_active_price (086) -- used for
-- the invoice's selling price AND its header rate_to_base -- explicitly
-- hardcodes 'SELLING'. Two different rates for what should be ONE
-- conversion on one document: verified via exact arithmetic match against
-- live data (10.4790 USD x 2825 Mid = 29603.175 CDF cost saved on the
-- line; 29603.175 x 0.00035088 [= 1/2850, Selling-based] = 1558.0743,
-- vs the correct 10.4790 x 150 qty = 1571.85 -- an ~13.78 USD leak/line,
-- which is why fully purchasing and selling stock never zeroes it out in
-- base currency).
--
-- Considered making Buying the new standard rate everywhere, but checked
-- how this app's own Contra Voucher (the one module doing real currency-
-- exchange treasury transactions) sources its rate: it doesn't call
-- fn_get_exchange_rate at all -- the user types both real amounts
-- directly, and the system only computes the difference as an Exchange
-- Gain/Loss plug. Matches how Odoo does it: ONE rate per currency per day,
-- used uniformly across Sales/Purchase/Inventory -- Buying/Selling spread
-- is a treasury/forex concept, not something that should vary the rate
-- used across transactional modules.
--
-- User-specified final design: stop auto-computing "Mid" from Buying/
-- Selling. rim_exchange_rates.mid_rate becomes an independently user-
-- entered "Exchange Rate" column (renamed), unrelated to Buying/Selling,
-- and mandatory like they already are. This is what every Sales/Purchase/
-- Inventory conversion already effectively used (the shared function's
-- default) -- fn_get_active_price's two hardcoded 'SELLING' overrides are
-- removed so cost and price finally draw from the identical rate on every
-- document. Buying/Selling stay in the schema/UI, stored but unused by any
-- current calculation, reserved for a future screen that needs them
-- explicitly.
-- ============================================================

-- ── 1. rim_exchange_rates: mid_rate -> independently-editable exchange_rate ──
-- NOTE: unlike most migrations in this project, the RENAME COLUMN below is
-- NOT safely re-runnable (a second run would fail with "column mid_rate
-- does not exist") -- this is a genuine one-time structural rename, not a
-- CREATE TRIGGER/POLICY needing the usual DROP IF EXISTS guard. Run once.
ALTER TABLE rim_exchange_rates ALTER COLUMN mid_rate DROP EXPRESSION IF EXISTS;
ALTER TABLE rim_exchange_rates RENAME COLUMN mid_rate TO exchange_rate;
ALTER TABLE rim_exchange_rates ALTER COLUMN exchange_rate SET NOT NULL;
ALTER TABLE rim_exchange_rates DROP CONSTRAINT IF EXISTS rim_exchange_rates_exchange_rate_check;
ALTER TABLE rim_exchange_rates ADD CONSTRAINT rim_exchange_rates_exchange_rate_check CHECK (exchange_rate > 0);

-- ── 2. fn_get_exchange_rate — column reference only, same signature/values ──
-- p_rate_type still accepts 'BUYING' | 'SELLING' | 'MID' (unchanged) — only
-- what the ELSE/MID branch actually reads from changes.
create or replace function fn_get_exchange_rate(
    p_company_id    uuid,
    p_location_id   uuid,
    p_from_currency text,
    p_to_currency   text,
    p_rate_date     date,
    p_rate_type     text default 'MID'
)
returns numeric
language plpgsql stable
as $$
declare
    v_base_currency text;
    v_rate_from     numeric;
    v_rate_to       numeric;
begin
    if p_from_currency = p_to_currency then
        return 1;
    end if;

    select base_currency into v_base_currency
    from ric_companies
    where id = p_company_id;

    if p_from_currency = v_base_currency then
        select case p_rate_type
            when 'BUYING'  then buying_rate
            when 'SELLING' then selling_rate
            else exchange_rate
        end
        into v_rate_to
        from rim_exchange_rates
        where company_id    = p_company_id
          and location_id   = p_location_id
          and from_currency = p_from_currency
          and to_currency   = p_to_currency
          and rate_date    <= p_rate_date
          and is_deleted    = false
        order by rate_date desc
        limit 1;

        if v_rate_to is null then
            raise exception 'No exchange rate found for % → % on or before %. Please enter rate first.',
                p_from_currency, p_to_currency, p_rate_date;
        end if;
        return v_rate_to;
    end if;

    if p_to_currency = v_base_currency then
        select case p_rate_type
            when 'BUYING'  then buying_rate
            when 'SELLING' then selling_rate
            else exchange_rate
        end
        into v_rate_from
        from rim_exchange_rates
        where company_id    = p_company_id
          and location_id   = p_location_id
          and from_currency = v_base_currency
          and to_currency   = p_from_currency
          and rate_date    <= p_rate_date
          and is_deleted    = false
        order by rate_date desc
        limit 1;

        if v_rate_from is null then
            raise exception 'No exchange rate found for % → % on or before %. Please enter rate first.',
                v_base_currency, p_from_currency, p_rate_date;
        end if;
        return 1.0 / v_rate_from;
    end if;

    select case p_rate_type
        when 'BUYING'  then buying_rate
        when 'SELLING' then selling_rate
        else exchange_rate
    end
    into v_rate_from
    from rim_exchange_rates
    where company_id    = p_company_id
      and location_id   = p_location_id
      and from_currency = v_base_currency
      and to_currency   = p_from_currency
      and rate_date    <= p_rate_date
      and is_deleted    = false
    order by rate_date desc
    limit 1;

    if v_rate_from is null then
        raise exception 'No exchange rate found for % → % on or before % (needed for cross-rate). Please enter rate first.',
            v_base_currency, p_from_currency, p_rate_date;
    end if;

    select case p_rate_type
        when 'BUYING'  then buying_rate
        when 'SELLING' then selling_rate
        else exchange_rate
    end
    into v_rate_to
    from rim_exchange_rates
    where company_id    = p_company_id
      and location_id   = p_location_id
      and from_currency = v_base_currency
      and to_currency   = p_to_currency
      and rate_date    <= p_rate_date
      and is_deleted    = false
    order by rate_date desc
    limit 1;

    if v_rate_to is null then
        raise exception 'No exchange rate found for % → % on or before % (needed for cross-rate). Please enter rate first.',
            v_base_currency, p_to_currency, p_rate_date;
    end if;

    return v_rate_to / v_rate_from;
end;
$$;

-- ── 3. fn_replicate_exchange_rates — exchange_rate must now be copied ──
-- explicitly (it was previously omitted on purpose since mid_rate
-- auto-generated; it no longer does).
create or replace function fn_replicate_exchange_rates(
    p_client_id       uuid,
    p_company_id      uuid,
    p_from_location   uuid,
    p_rate_date       date,
    p_replicated_by   uuid
)
returns integer
language plpgsql
as $$
declare
    v_count integer;
begin
    insert into rim_exchange_rates (
        client_id, company_id, location_id,
        rate_date, from_currency, to_currency,
        buying_rate, selling_rate, exchange_rate,
        source, created_by, updated_by
    )
    select
        p_client_id,
        p_company_id,
        loc.id,
        p_rate_date,
        er.from_currency,
        er.to_currency,
        er.buying_rate,
        er.selling_rate,
        er.exchange_rate,
        'MANUAL',
        p_replicated_by,
        p_replicated_by
    from rim_exchange_rates er
    cross join ric_locations loc
    where er.client_id    = p_client_id
      and er.company_id   = p_company_id
      and er.location_id  = p_from_location
      and er.rate_date    = p_rate_date
      and er.is_deleted   = false
      and loc.client_id   = p_client_id
      and loc.company_id  = p_company_id
      and loc.id         != p_from_location
      and loc.is_active   = true
      and loc.is_deleted  = false
    on conflict (client_id, company_id, location_id, rate_date, from_currency, to_currency)
    do update set
        buying_rate    = excluded.buying_rate,
        selling_rate   = excluded.selling_rate,
        exchange_rate  = excluded.exchange_rate,
        source         = 'MANUAL',
        updated_at     = now(),
        updated_by     = p_replicated_by;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- ── 3b. fn_replicate_exchange_rates_new_only (131) — same fix as #3 ──
-- Separate, additive "copy to locations with no rate yet" function
-- (ON CONFLICT DO NOTHING, never overwrites) — also omitted exchange_rate
-- on the same grounds (mid_rate used to auto-generate) and needs the
-- identical fix.
CREATE OR REPLACE FUNCTION fn_replicate_exchange_rates_new_only(
    p_client_id       UUID,
    p_company_id      UUID,
    p_from_location   UUID,
    p_rate_date       DATE,
    p_replicated_by   UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    INSERT INTO rim_exchange_rates (
        client_id, company_id, location_id,
        rate_date, from_currency, to_currency,
        buying_rate, selling_rate, exchange_rate,
        source, created_by, updated_by
    )
    SELECT
        p_client_id,
        p_company_id,
        loc.id,
        p_rate_date,
        er.from_currency,
        er.to_currency,
        er.buying_rate,
        er.selling_rate,
        er.exchange_rate,
        'MANUAL',
        p_replicated_by,
        p_replicated_by
    FROM rim_exchange_rates er
    CROSS JOIN ric_locations loc
    WHERE er.client_id    = p_client_id
      AND er.company_id   = p_company_id
      AND er.location_id  = p_from_location
      AND er.rate_date    = p_rate_date
      AND er.is_deleted   = false
      AND loc.client_id   = p_client_id
      AND loc.company_id  = p_company_id
      AND loc.id         != p_from_location
      AND loc.is_active   = true
      AND loc.is_deleted  = false
    ON CONFLICT (client_id, company_id, location_id, rate_date, from_currency, to_currency)
    DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ── 4. fn_get_active_price — drop the hardcoded 'SELLING' overrides ──
-- Falls through to the shared default ('MID', i.e. the renamed
-- exchange_rate column) — the same call shape every other caller in the
-- codebase already uses. This, combined with #1-3 above, is the actual
-- fix: cost (fn_save_sales_invoice, unchanged) and price (here) now draw
-- from the identical rate on every document, so fn_approve_sales_invoice's
-- round-trip (v_line.cost_price * v_header.rate_to_base) cancels out
-- exactly instead of leaking. Same signature as migration 086 — plain
-- CREATE OR REPLACE, no DROP needed since the RETURNS TABLE shape is
-- unchanged.
CREATE OR REPLACE FUNCTION fn_get_active_price(
    p_client_id       UUID,
    p_company_id      UUID,
    p_location_id     UUID,
    p_product_id      UUID,
    p_uom_id          UUID,
    p_customer_id     UUID,
    p_as_of_date      DATE,
    p_target_currency TEXT
)
RETURNS TABLE (
    selling_price        NUMERIC,
    native_selling_price NUMERIC,
    price_currency_code  TEXT,
    conversion_rate      NUMERIC,
    entry_no             TEXT,
    effective_date       DATE,
    price_type           TEXT,
    is_tax_inclusive      BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_native_price   NUMERIC;
    v_native_ccy     TEXT;
    v_entry_no       TEXT;
    v_effective_date DATE;
    v_price_type     TEXT;
    v_is_tax_incl    BOOLEAN;
    v_rate           NUMERIC;
BEGIN
    IF p_customer_id IS NOT NULL THEN
        SELECT l.selling_price, c.currency_id, l.entry_no, l.effective_date, l.price_type, l.is_tax_inclusive
          INTO v_native_price, v_native_ccy, v_entry_no, v_effective_date, v_price_type, v_is_tax_incl
        FROM   rid_price_master_lines l
        JOIN   rih_price_master_headers h
          ON   h.client_id = l.client_id AND h.company_id = l.company_id
          AND  h.entry_no = l.entry_no AND h.entry_date = l.entry_date
        JOIN   rim_currencies c ON c.id = h.price_currency_id
        WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
          AND  l.location_id = p_location_id
          AND  l.product_id = p_product_id AND l.uom_id = p_uom_id
          AND  l.price_type = 'CUSTOMER' AND l.customer_id = p_customer_id
          AND  l.status = 'APPROVED' AND l.is_deleted = false
          AND  l.effective_date <= p_as_of_date
        ORDER BY l.effective_date DESC, l.created_at DESC
        LIMIT 1;

        IF FOUND THEN
            v_rate := CASE WHEN v_native_ccy = p_target_currency THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, p_location_id, v_native_ccy, p_target_currency, p_as_of_date) END;
            RETURN QUERY SELECT v_native_price * v_rate, v_native_price, v_native_ccy, v_rate,
                                v_entry_no, v_effective_date, v_price_type, v_is_tax_incl;
            RETURN;
        END IF;
    END IF;

    SELECT l.selling_price, c.currency_id, l.entry_no, l.effective_date, l.price_type, l.is_tax_inclusive
      INTO v_native_price, v_native_ccy, v_entry_no, v_effective_date, v_price_type, v_is_tax_incl
    FROM   rid_price_master_lines l
    JOIN   rih_price_master_headers h
      ON   h.client_id = l.client_id AND h.company_id = l.company_id
      AND  h.entry_no = l.entry_no AND h.entry_date = l.entry_date
    JOIN   rim_currencies c ON c.id = h.price_currency_id
    WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
      AND  l.location_id = p_location_id
      AND  l.product_id = p_product_id AND l.uom_id = p_uom_id
      AND  l.price_type = 'GENERIC' AND l.customer_id IS NULL
      AND  l.status = 'APPROVED' AND l.is_deleted = false
      AND  l.effective_date <= p_as_of_date
    ORDER BY l.effective_date DESC, l.created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_rate := CASE WHEN v_native_ccy = p_target_currency THEN 1
                    ELSE fn_get_exchange_rate(p_company_id, p_location_id, v_native_ccy, p_target_currency, p_as_of_date) END;
    RETURN QUERY SELECT v_native_price * v_rate, v_native_price, v_native_ccy, v_rate,
                        v_entry_no, v_effective_date, v_price_type, v_is_tax_incl;
END;
$$;

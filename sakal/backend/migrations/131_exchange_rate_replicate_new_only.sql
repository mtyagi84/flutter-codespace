-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 131 — Exchange Rate: replicate-to-other-locations that never
-- overwrites (Phase 4 of the Sales Invoice Test bugs.docx fix pass).
--
-- fn_replicate_exchange_rates (018) already exists as an explicit,
-- user-triggered "Copy to All Locations" bulk action — it intentionally
-- OVERWRITES every other location's rate for the date (ON CONFLICT DO
-- UPDATE), and its own confirm dialog says so. That stays unchanged.
--
-- This is a SEPARATE, additive function for a different, narrower need:
-- automatically offered right after a location's FIRST-EVER rate save for
-- a given date, to save the same rate to every OTHER location that does
-- NOT already have its own rate for that date — never overwriting one
-- that does (ON CONFLICT DO NOTHING).
-- ═══════════════════════════════════════════════════════════════════════════

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
        buying_rate, selling_rate,
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

REVOKE ALL ON FUNCTION fn_replicate_exchange_rates_new_only(UUID, UUID, UUID, DATE, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION fn_replicate_exchange_rates_new_only(UUID, UUID, UUID, DATE, UUID) TO authenticated;

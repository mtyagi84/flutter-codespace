-- ============================================================
-- 033_protect_item_account_overrides.sql
-- Fixes fn_clear_account_link_cache so item-level overrides
-- (rim_account_links rows with link_type = 'ITEM', written directly by
-- the Item Account Links screen) are NEVER deleted by a cache-clear
-- triggered from editing a Company/Category/Location default or
-- switching a link type's level.
--
-- Problem: p_link_key_id = NULL was used as both "this is the
-- Company-level key" (which is genuinely NULL) and "clear everything
-- for this link type" (level switch), with no way to tell them apart —
-- so editing the Company-wide account, or switching levels, silently
-- wiped every item's manual override too.
--
-- Fix: exclude link_type = 'ITEM' from the DELETE unconditionally.
-- Overrides are only ever removed via an explicit action on the Item
-- Account Links screen itself, never as a side effect of a general
-- Company/Category/Location change.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_clear_account_link_cache(
    p_client_id   UUID,
    p_company_id  UUID,
    p_link_key    TEXT,
    p_link_key_id UUID DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_link_type_id UUID;
    v_count        INTEGER;
BEGIN
    SELECT id INTO v_link_type_id
    FROM rim_account_link_types
    WHERE link_key = p_link_key;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    DELETE FROM rim_account_links
    WHERE client_id    = p_client_id
      AND company_id   = p_company_id
      AND link_type_id = v_link_type_id
      AND link_type    != 'ITEM'
      AND (p_link_key_id IS NULL OR link_key_id = p_link_key_id);

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_clear_account_link_cache(UUID, UUID, TEXT, UUID) TO authenticated;

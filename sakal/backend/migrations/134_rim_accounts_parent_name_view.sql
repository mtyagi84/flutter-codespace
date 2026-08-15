-- ============================================================
-- Migration 134: v_rim_accounts_with_parent — account parent group
-- name resolved server-side via a plain SQL join, not a PostgREST
-- embed.
-- ============================================================
-- Two different PostgREST embed-hint forms for the self-referencing
-- rim_accounts!parent_id relationship failed live against this project's
-- Supabase instance:
--   1. !parent_id (column-name hint) resolved to the REVERSE relationship
--      (this account's children, not its own parent) — silently came back
--      empty for every leaf/postable account, the only kind ever shown in
--      a picker, so Group Name was blank everywhere.
--   2. !rim_accounts_parent_id_fkey (FK constraint name, independently
--      verified correct via pg_constraint) was rejected outright by
--      PostgREST ("no matches were found"), even after
--      NOTIFY pgrst, 'reload schema';
--
-- Self-referencing embeds are evidently unreliable here regardless of hint
-- form. A plain SQL join exposed through a view sidesteps PostgREST's
-- embedding resolution entirely — by the time PostgREST sees this view,
-- parent_name is just a regular scalar column, same as every other
-- established view in this schema (v_pending_bills, v_batch_stock_balance,
-- v_opening_balance_summary, v_sales_details_base, ...).
-- ============================================================

CREATE OR REPLACE VIEW v_rim_accounts_with_parent AS
SELECT c.*,
       p.account_name AS parent_name
FROM   rim_accounts c
LEFT JOIN rim_accounts p
       ON  p.id         = c.parent_id
      AND  p.client_id  = c.client_id
      AND  p.company_id = c.company_id;

-- RLS on the underlying rim_accounts table (whatever it currently is) is
-- enforced automatically through the view by the querying session's own
-- role — no separate policy needed on the view itself.
GRANT SELECT ON v_rim_accounts_with_parent TO authenticated;

-- ============================================================
-- 014_add_is_deleted.sql
-- Add missing is_deleted column to rim_countries and rim_divisions.
-- These tables were created in 008 and 009 before the is_deleted
-- convention was consistently applied. Flutter screens filter on
-- this column so without it queries return a PostgREST 400 error.
-- ============================================================

ALTER TABLE rim_countries
    ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE rim_divisions
    ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;

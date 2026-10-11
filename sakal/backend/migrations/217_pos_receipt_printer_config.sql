-- ============================================================================
-- Migration 217: per-terminal receipt printer configuration
-- ============================================================================
-- ric_pos_terminals.receipt_paper_profile (RECEIPT_58MM/RECEIPT_80MM) has
-- existed since the terminal was first designed (migration 205) but was
-- never actually consumed by anything -- POS printing reused the back-
-- office Sales Invoice/Sales Return A4 template verbatim (confirmed live,
-- 2026-10-11). This migration adds the printer identity a till needs to
-- print SILENTLY (no OS print dialog) via the `printing` package's
-- Printing.directPrintPdf(printer:, onLayout:) -- that call needs a
-- `Printer` object, whose stable identifier is its `url` (name is only a
-- display label and may not be unique). Both are nullable: a terminal with
-- neither set simply falls back to today's dialog-based printing, same as
-- before this migration -- never a hard requirement to configure a printer
-- before a till can be used at all.
-- ============================================================================

ALTER TABLE ric_pos_terminals ADD COLUMN IF NOT EXISTS receipt_printer_name TEXT;
ALTER TABLE ric_pos_terminals ADD COLUMN IF NOT EXISTS receipt_printer_url  TEXT;

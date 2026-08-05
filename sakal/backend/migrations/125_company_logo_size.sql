-- ============================================================
-- Migration 125: Company-level configurable logo print size.
-- ============================================================
-- User-specified: a company's logo should print at a company-wide
-- physical size (default 1 inch x 1 inch), consistently across every
-- place a logo prints — the Reporting Engine's new PDF header AND the
-- existing document Print Engine (PO/GRN/Invoices/Vouchers/etc.), not a
-- separate hardcoded size per template/screen.
--
-- Stored in inches (not mm/points) to match how the user actually
-- specified and will configure it; every renderer converts to PDF
-- points at render time (1 inch = 25.4mm, and the `pdf` package already
-- exposes PdfPageFormat.mm as points-per-mm).
-- ============================================================

ALTER TABLE ric_companies
    ADD COLUMN IF NOT EXISTS logo_width_inch  NUMERIC(4,2) NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS logo_height_inch NUMERIC(4,2) NOT NULL DEFAULT 1;

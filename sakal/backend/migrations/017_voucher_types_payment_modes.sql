-- ============================================================
-- 017_voucher_types_payment_modes.sql
-- Master tables for voucher types and payment modes.
-- System rows (is_system = true) have NULL client_id / company_id.
-- Query pattern: WHERE is_system = true OR (client_id = $1 AND company_id = $2)
-- ============================================================


-- ------------------------------------------------------------
-- rim_voucher_types
-- Defines voucher categories and their document numbering behavior.
-- Format tokens: {TYPE} {LOC} {YYYY} {MM} {DD} {SEQ4} {SEQ5} {SEQ6}
-- ------------------------------------------------------------
create table rim_voucher_types (
    id                  uuid        primary key default gen_random_uuid(),
    client_id           uuid        references ric_clients(id),
    company_id          uuid        references ric_companies(id),
    voucher_type_code   text        not null,
    type_description    text        not null,
    -- RECEIPT | PAYMENT | JOURNAL | DEBIT_NOTE | CREDIT_NOTE | STOCK
    voucher_nature      text        not null,
    -- DR for receipts (cash/bank debited), CR for payments, NULL for journal/notes
    cash_bank_side      text        check (cash_bank_side in ('DR', 'CR')),
    -- When the running sequence resets to 1
    reset_frequency     text        not null default 'YEARLY'
                                    check (reset_frequency in ('DAILY', 'MONTHLY', 'YEARLY', 'NEVER')),
    -- Parameterized document number template
    trans_no_format     text        not null default '{TYPE}/{LOC}/{YYYY}/{SEQ5}',
    is_system           boolean     not null default false,
    is_active           boolean     not null default true,
    is_deleted          boolean     not null default false,
    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz,
    updated_by          uuid,
    constraint rim_voucher_types_nature_check
        check (voucher_nature in ('RECEIPT','PAYMENT','JOURNAL','DEBIT_NOTE','CREDIT_NOTE','STOCK'))
);

-- System voucher types are unique by code alone
create unique index uq_rim_voucher_types_system
    on rim_voucher_types (voucher_type_code)
    where is_system = true;

-- Client-defined voucher types are unique per company
create unique index uq_rim_voucher_types_client
    on rim_voucher_types (client_id, company_id, voucher_type_code)
    where is_system = false;

create index idx_rim_voucher_types_company on rim_voucher_types (client_id, company_id);

alter table rim_voucher_types enable row level security;
create policy "dev_allow_all_voucher_types" on rim_voucher_types for all using (true) with check (true);


-- ------------------------------------------------------------
-- rim_payment_modes
-- CASH, CHEQUE, NEFT, RTGS, WIRE, DD, MOBILE MONEY, etc.
-- Same system vs client pattern as rim_voucher_types.
-- ------------------------------------------------------------
create table rim_payment_modes (
    id                  uuid        primary key default gen_random_uuid(),
    client_id           uuid        references ric_clients(id),
    company_id          uuid        references ric_companies(id),
    payment_mode_code   text        not null,
    payment_mode_name   text        not null,
    is_system           boolean     not null default false,
    is_active           boolean     not null default true,
    is_deleted          boolean     not null default false,
    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz,
    updated_by          uuid
);

create unique index uq_rim_payment_modes_system
    on rim_payment_modes (payment_mode_code)
    where is_system = true;

create unique index uq_rim_payment_modes_client
    on rim_payment_modes (client_id, company_id, payment_mode_code)
    where is_system = false;

create index idx_rim_payment_modes_company on rim_payment_modes (client_id, company_id);

alter table rim_payment_modes enable row level security;
create policy "dev_allow_all_payment_modes" on rim_payment_modes for all using (true) with check (true);


-- ------------------------------------------------------------
-- Seeds — system voucher types
-- client_id / company_id are NULL for system rows.
-- ------------------------------------------------------------
insert into rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) values
    ('CRV', 'Cash Receipt Voucher',   'RECEIPT',    'DR', 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('BRV', 'Bank Receipt Voucher',   'RECEIPT',    'DR', 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('CPV', 'Cash Payment Voucher',   'PAYMENT',    'CR', 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('BPV', 'Bank Payment Voucher',   'PAYMENT',    'CR', 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('JV',  'Journal Voucher',        'JOURNAL',    null, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('SDN', 'Supplier Debit Note',    'DEBIT_NOTE', null, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('SCN', 'Supplier Credit Note',   'CREDIT_NOTE',null, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('CDN', 'Customer Debit Note',    'DEBIT_NOTE', null, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('CCN', 'Customer Credit Note',   'CREDIT_NOTE',null, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('SIV', 'Stock Issue Voucher',    'STOCK',      null, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
on conflict do nothing;


-- ------------------------------------------------------------
-- Seeds — system payment modes
-- ------------------------------------------------------------
insert into rim_payment_modes (payment_mode_code, payment_mode_name, is_system) values
    ('CASH',   'Cash',          true),
    ('CHEQUE', 'Cheque',        true),
    ('NEFT',   'NEFT Transfer', true),
    ('RTGS',   'RTGS Transfer', true),
    ('WIRE',   'Wire Transfer', true),
    ('DD',     'Demand Draft',  true),
    ('MOBILE', 'Mobile Money',  true)
on conflict do nothing;

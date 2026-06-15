-- ============================================================
-- 003_alter_clients.sql
-- Add licensing and registration columns to ric_clients.
-- Run after 002_users.sql.
-- ============================================================

alter table ric_clients
    add column client_no            text unique,
    add column registration_email   text,
    add column license_status       text not null default 'TRIAL',
    add column trial_start_date     date,
    add column trial_end_date       date,
    add column trial_extended       boolean not null default false,
    add column license_expiry_date  date;

-- Index for email duplicate check on registration
create index on ric_clients (registration_email);

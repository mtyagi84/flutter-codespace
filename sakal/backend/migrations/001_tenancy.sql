-- ============================================================
-- 001_tenancy.sql
-- Foundation tables: clients → companies → locations
-- Prefix: ric_ (Rigevedam Innovations + Configuration)
-- Run this first — all other tables depend on these.
-- ============================================================


-- ------------------------------------------------------------
-- ric_clients
-- Top-level tenant. One record per client business.
-- Does NOT have client_id/company_id/location_id — it IS the root.
-- ------------------------------------------------------------
create table ric_clients (
    id              uuid        primary key default gen_random_uuid(),
    client_name     text        not null,
    client_short    text,
    address         text,
    phone           text,
    email           text,
    country         text,
    is_active       boolean     not null default true,
    is_deleted      boolean     not null default false,
    created_at      timestamptz not null default now(),
    created_by      uuid,
    updated_at      timestamptz,
    updated_by      uuid
);


-- ------------------------------------------------------------
-- ric_companies
-- One client → many companies.
-- Stores base + local currency (set at company setup).
-- FK to currencies added in 003_currencies.sql.
-- ------------------------------------------------------------
create table ric_companies (
    id              uuid        primary key default gen_random_uuid(),
    client_id       uuid        not null references ric_clients(id),
    company_name    text        not null,
    company_short   text,
    address         text,
    phone           text,
    email           text,
    country         text,
    base_currency   text,
    local_currency  text,
    is_active       boolean     not null default true,
    is_deleted      boolean     not null default false,
    created_at      timestamptz not null default now(),
    created_by      uuid,
    updated_at      timestamptz,
    updated_by      uuid
);


-- ------------------------------------------------------------
-- ric_locations
-- One company → many locations (stores / warehouses / offices).
-- server_url: points to local PostgREST when on LAN (offline mode).
-- ------------------------------------------------------------
create table ric_locations (
    id              uuid        primary key default gen_random_uuid(),
    client_id       uuid        not null references ric_clients(id),
    company_id      uuid        not null references ric_companies(id),
    location_name   text        not null,
    location_short  text,
    location_type   text,
    address         text,
    phone           text,
    server_url      text,
    is_active       boolean     not null default true,
    is_deleted      boolean     not null default false,
    created_at      timestamptz not null default now(),
    created_by      uuid,
    updated_at      timestamptz,
    updated_by      uuid
);


-- ------------------------------------------------------------
-- Indexes
-- ------------------------------------------------------------
create index on ric_companies (client_id);
create index on ric_locations (client_id);
create index on ric_locations (company_id);


-- ------------------------------------------------------------
-- Row Level Security
-- Enabled on all tables. Policies added separately in rls/.
-- For development: allow all for anon role.
-- Tighten before production deployment.
-- ------------------------------------------------------------
alter table ric_clients   enable row level security;
alter table ric_companies enable row level security;
alter table ric_locations enable row level security;

create policy "dev_allow_all_clients"   on ric_clients   for all using (true) with check (true);
create policy "dev_allow_all_companies" on ric_companies for all using (true) with check (true);
create policy "dev_allow_all_locations" on ric_locations for all using (true) with check (true);

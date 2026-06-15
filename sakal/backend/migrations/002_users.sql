-- ============================================================
-- 002_users.sql
-- User accounts — login, audit trail, account security
-- Prefix: rim_ (Rigevedam Innovations + Master)
-- Roles and menu permissions come later in a separate migration.
-- ============================================================

-- Required for bcrypt password hashing
create extension if not exists pgcrypto;


-- ------------------------------------------------------------
-- rim_users
-- One record per user account.
-- Username is unique per client — two clients can both have 'admin'.
-- created_by / updated_by are self-referencing (null for first admin).
-- ------------------------------------------------------------
create table rim_users (
    id                   uuid        primary key default gen_random_uuid(),
    client_id            uuid        not null references ric_clients(id),
    company_id           uuid        not null references ric_companies(id),
    default_location_id  uuid        references ric_locations(id),
    username             text        not null,
    full_name            text        not null,
    email                text,
    phone                text,
    password_hash        text        not null,
    must_change_password boolean     not null default false,
    password_changed_at  timestamptz,
    last_login_at        timestamptz,
    failed_attempts      integer     not null default 0,
    locked_until         timestamptz,
    is_active            boolean     not null default true,
    is_deleted           boolean     not null default false,
    created_at           timestamptz not null default now(),
    created_by           uuid        references rim_users(id),
    updated_at           timestamptz,
    updated_by           uuid        references rim_users(id)
);

-- Username unique per client (includes soft-deleted — prevents username reuse)
create unique index uq_users_client_username on rim_users(client_id, username);

-- Indexes
create index on rim_users(client_id);
create index on rim_users(company_id);


-- ------------------------------------------------------------
-- Back-fill FK constraints on tenancy tables
-- created_by / updated_by now formally point to rim_users
-- ------------------------------------------------------------
alter table ric_clients
    add constraint fk_clients_created_by foreign key (created_by) references rim_users(id),
    add constraint fk_clients_updated_by foreign key (updated_by) references rim_users(id);

alter table ric_companies
    add constraint fk_companies_created_by foreign key (created_by) references rim_users(id),
    add constraint fk_companies_updated_by foreign key (updated_by) references rim_users(id);

alter table ric_locations
    add constraint fk_locations_created_by foreign key (created_by) references rim_users(id),
    add constraint fk_locations_updated_by foreign key (updated_by) references rim_users(id);


-- ------------------------------------------------------------
-- Row Level Security
-- ------------------------------------------------------------
alter table rim_users enable row level security;
create policy "dev_allow_all_users" on rim_users for all using (true) with check (true);

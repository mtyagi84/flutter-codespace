-- ============================================================
-- 004_menus_and_modules.sql
-- Module registry + menu catalogue + user permissions
-- Run after 003_alter_clients.sql
-- ============================================================


-- ------------------------------------------------------------
-- ric_system_modules
-- Which ERP modules are active per company.
-- One company can have a different module set than another
-- under the same client.
-- ------------------------------------------------------------
create table ric_system_modules (
    id           uuid        primary key default gen_random_uuid(),
    client_id    uuid        not null references ric_clients(id),
    company_id   uuid        not null references ric_companies(id),
    module_code  text        not null,
    module_name  text        not null,
    serial_no    integer     not null default 0,
    is_active    boolean     not null default true,
    is_deleted   boolean     not null default false,
    created_at   timestamptz not null default now(),
    created_by   uuid        references rim_users(id),
    updated_at   timestamptz,
    updated_by   uuid        references rim_users(id),
    unique (client_id, company_id, module_code)
);

create index on ric_system_modules (client_id, company_id);


-- ------------------------------------------------------------
-- ric_master_menus
-- All features available per company — controlled by SAKAL team.
-- is_active = false hides a feature from all users of that company.
-- Custom screens for a specific client live here too.
-- ------------------------------------------------------------
create table ric_master_menus (
    id                   uuid        primary key default gen_random_uuid(),
    client_id            uuid        not null references ric_clients(id),
    company_id           uuid        not null references ric_companies(id),
    module_id            uuid        not null references ric_system_modules(id),
    feature_code         text        not null,
    feature_name         text        not null,
    screen_name          text        not null,
    serial_no            integer     not null default 0,
    excel_upload_allowed boolean     not null default false,
    copy_allowed         boolean     not null default false,
    approve_allowed      boolean     not null default false,
    is_active            boolean     not null default true,
    is_deleted           boolean     not null default false,
    created_at           timestamptz not null default now(),
    created_by           uuid        references rim_users(id),
    updated_at           timestamptz,
    updated_by           uuid        references rim_users(id),
    unique (client_id, company_id, feature_code)
);

create index on ric_master_menus (client_id, company_id, module_id);


-- ------------------------------------------------------------
-- ric_user_menus
-- Per-user permissions. feature_name and screen_name are NOT
-- stored here — always read from ric_master_menus via JOIN.
-- A feature blocked at master level (is_active=false) never
-- shows even if the user has view_allowed=true.
-- ------------------------------------------------------------
create table ric_user_menus (
    id                   uuid        primary key default gen_random_uuid(),
    client_id            uuid        not null references ric_clients(id),
    company_id           uuid        not null references ric_companies(id),
    user_id              uuid        not null references rim_users(id),
    module_id            uuid        not null references ric_system_modules(id),
    feature_code         text        not null,
    serial_no            integer     not null default 0,
    view_allowed         boolean     not null default false,
    edit_allowed         boolean     not null default false,
    approve_allowed      boolean     not null default false,
    copy_allowed         boolean     not null default false,
    excel_upload_allowed boolean     not null default false,
    is_active            boolean     not null default true,
    is_deleted           boolean     not null default false,
    created_at           timestamptz not null default now(),
    created_by           uuid        references rim_users(id),
    updated_at           timestamptz,
    updated_by           uuid        references rim_users(id),
    unique (client_id, company_id, user_id, feature_code),
    foreign key (client_id, company_id, feature_code)
        references ric_master_menus (client_id, company_id, feature_code)
);

create index on ric_user_menus (client_id, company_id, user_id);


-- ------------------------------------------------------------
-- Row Level Security
-- ------------------------------------------------------------
alter table ric_system_modules enable row level security;
alter table ric_master_menus   enable row level security;
alter table ric_user_menus     enable row level security;

create policy "dev_allow_all_modules"      on ric_system_modules for all using (true) with check (true);
create policy "dev_allow_all_master_menus" on ric_master_menus   for all using (true) with check (true);
create policy "dev_allow_all_user_menus"   on ric_user_menus     for all using (true) with check (true);

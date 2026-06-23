-- ============================================================
-- 018_exchange_rates.sql
-- Location-level daily exchange rates (buying / selling / mid).
-- mid_rate is always (buying + selling) / 2 — stored generated column.
-- ============================================================


-- ------------------------------------------------------------
-- rim_exchange_rates
-- One row per (company, location, date, from_currency, to_currency).
-- from_currency is always the company's base currency (e.g. USD).
-- to_currency is the target (CDF, ZMW, EUR, GBP…).
-- Active currencies only — filter via rim_currencies.is_active.
-- ------------------------------------------------------------
create table rim_exchange_rates (
    id              uuid        primary key default gen_random_uuid(),
    client_id       uuid        not null references ric_clients(id),
    company_id      uuid        not null references ric_companies(id),
    location_id     uuid        not null references ric_locations(id),
    rate_date       date        not null,
    from_currency   text        not null,
    to_currency     text        not null,
    -- Company buys foreign currency at this rate (customer pays USD, we record at buying rate)
    buying_rate     numeric(18,8) not null check (buying_rate > 0),
    -- Company sells foreign currency at this rate (invoice USD price → local currency amount)
    selling_rate    numeric(18,8) not null check (selling_rate > 0),
    -- Always (buying + selling) / 2 — never manually set
    mid_rate        numeric(18,8) generated always as ((buying_rate + selling_rate) / 2) stored,
    -- MANUAL = user entry, API = fetched from internet (future)
    source          text        not null default 'MANUAL' check (source in ('MANUAL', 'API')),
    is_active       boolean     not null default true,
    is_deleted      boolean     not null default false,
    created_at      timestamptz not null default now(),
    created_by      uuid,
    updated_at      timestamptz,
    updated_by      uuid,
    constraint uq_rim_exchange_rates
        unique (client_id, company_id, location_id, rate_date, from_currency, to_currency)
);

create index idx_rim_exchange_rates_lookup
    on rim_exchange_rates (company_id, location_id, from_currency, to_currency, rate_date desc);

alter table rim_exchange_rates enable row level security;
create policy "dev_allow_all_exchange_rates" on rim_exchange_rates for all using (true) with check (true);


-- ------------------------------------------------------------
-- fn_get_exchange_rate
-- Returns the most recent rate on or before p_rate_date.
-- Raises exception if no rate found — forces user to enter rate first.
-- p_rate_type: 'BUYING' | 'SELLING' | 'MID'
-- ------------------------------------------------------------
create or replace function fn_get_exchange_rate(
    p_company_id    uuid,
    p_location_id   uuid,
    p_from_currency text,
    p_to_currency   text,
    p_rate_date     date,
    p_rate_type     text default 'MID'
)
returns numeric
language plpgsql stable
as $$
declare
    v_base_currency text;
    v_rate_from     numeric;
    v_rate_to       numeric;
begin
    -- Same currency → always 1
    if p_from_currency = p_to_currency then
        return 1;
    end if;

    -- Base currency for this company (all rates in table are base → other)
    select base_currency into v_base_currency
    from ric_companies
    where id = p_company_id;

    -- CASE 1: from = base → direct lookup
    if p_from_currency = v_base_currency then
        select case p_rate_type
            when 'BUYING'  then buying_rate
            when 'SELLING' then selling_rate
            else mid_rate
        end
        into v_rate_to
        from rim_exchange_rates
        where company_id    = p_company_id
          and location_id   = p_location_id
          and from_currency = p_from_currency
          and to_currency   = p_to_currency
          and rate_date    <= p_rate_date
          and is_deleted    = false
        order by rate_date desc
        limit 1;

        if v_rate_to is null then
            raise exception 'No exchange rate found for % → % on or before %. Please enter rate first.',
                p_from_currency, p_to_currency, p_rate_date;
        end if;
        return v_rate_to;
    end if;

    -- CASE 2: to = base → reciprocal of lookup(base → from)
    if p_to_currency = v_base_currency then
        select case p_rate_type
            when 'BUYING'  then buying_rate
            when 'SELLING' then selling_rate
            else mid_rate
        end
        into v_rate_from
        from rim_exchange_rates
        where company_id    = p_company_id
          and location_id   = p_location_id
          and from_currency = v_base_currency
          and to_currency   = p_from_currency
          and rate_date    <= p_rate_date
          and is_deleted    = false
        order by rate_date desc
        limit 1;

        if v_rate_from is null then
            raise exception 'No exchange rate found for % → % on or before %. Please enter rate first.',
                v_base_currency, p_from_currency, p_rate_date;
        end if;
        return 1.0 / v_rate_from;
    end if;

    -- CASE 3: cross-rate — neither from nor to is base
    -- rate(from → to) = lookup(base → to) / lookup(base → from)
    select case p_rate_type
        when 'BUYING'  then buying_rate
        when 'SELLING' then selling_rate
        else mid_rate
    end
    into v_rate_from
    from rim_exchange_rates
    where company_id    = p_company_id
      and location_id   = p_location_id
      and from_currency = v_base_currency
      and to_currency   = p_from_currency
      and rate_date    <= p_rate_date
      and is_deleted    = false
    order by rate_date desc
    limit 1;

    if v_rate_from is null then
        raise exception 'No exchange rate found for % → % on or before % (needed for cross-rate). Please enter rate first.',
            v_base_currency, p_from_currency, p_rate_date;
    end if;

    select case p_rate_type
        when 'BUYING'  then buying_rate
        when 'SELLING' then selling_rate
        else mid_rate
    end
    into v_rate_to
    from rim_exchange_rates
    where company_id    = p_company_id
      and location_id   = p_location_id
      and from_currency = v_base_currency
      and to_currency   = p_to_currency
      and rate_date    <= p_rate_date
      and is_deleted    = false
    order by rate_date desc
    limit 1;

    if v_rate_to is null then
        raise exception 'No exchange rate found for % → % on or before % (needed for cross-rate). Please enter rate first.',
            v_base_currency, p_to_currency, p_rate_date;
    end if;

    return v_rate_to / v_rate_from;
end;
$$;


-- ------------------------------------------------------------
-- fn_replicate_exchange_rates
-- Copies all rates for p_rate_date from one location to all
-- other active locations in the same company.
-- Returns the number of rows inserted/updated.
-- ------------------------------------------------------------
create or replace function fn_replicate_exchange_rates(
    p_client_id       uuid,
    p_company_id      uuid,
    p_from_location   uuid,
    p_rate_date       date,
    p_replicated_by   uuid
)
returns integer
language plpgsql
as $$
declare
    v_count integer;
begin
    insert into rim_exchange_rates (
        client_id, company_id, location_id,
        rate_date, from_currency, to_currency,
        buying_rate, selling_rate,
        source, created_by, updated_by
    )
    select
        p_client_id,
        p_company_id,
        loc.id,
        p_rate_date,
        er.from_currency,
        er.to_currency,
        er.buying_rate,
        er.selling_rate,
        'MANUAL',
        p_replicated_by,
        p_replicated_by
    from rim_exchange_rates er
    cross join ric_locations loc
    where er.client_id    = p_client_id
      and er.company_id   = p_company_id
      and er.location_id  = p_from_location
      and er.rate_date    = p_rate_date
      and er.is_deleted   = false
      and loc.client_id   = p_client_id
      and loc.company_id  = p_company_id
      and loc.id         != p_from_location
      and loc.is_active   = true
      and loc.is_deleted  = false
    on conflict (client_id, company_id, location_id, rate_date, from_currency, to_currency)
    do update set
        buying_rate  = excluded.buying_rate,
        selling_rate = excluded.selling_rate,
        source       = 'MANUAL',
        updated_at   = now(),
        updated_by   = p_replicated_by;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

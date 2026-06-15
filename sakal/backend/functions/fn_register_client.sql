-- ============================================================
-- fn_register_client
-- Creates client + company + location + first admin in one
-- transaction. Called from Flutter on first-time registration.
-- PostgREST: POST /rest/v1/rpc/fn_register_client
-- ============================================================

create or replace function fn_register_client(
    p_business_name  text,
    p_country        text,
    p_contact_name   text,
    p_email          text,
    p_phone          text,
    p_company_name   text,
    p_company_short  text,
    p_base_currency  text,
    p_local_currency text,
    p_location_name  text,
    p_location_short text,
    p_location_type  text,
    p_admin_name     text,
    p_username       text,
    p_password       text
) returns json language plpgsql security definer as $$
declare
    v_client_id   uuid;
    v_company_id  uuid;
    v_location_id uuid;
    v_user_id     uuid;
    v_client_no   text;
begin
    -- Reject duplicate email (case-insensitive)
    if exists (
        select 1 from ric_clients
        where registration_email = lower(trim(p_email))
    ) then
        raise exception 'EMAIL_EXISTS'
            using hint = 'An account with this email already exists';
    end if;

    -- Generate a unique client_no (SK-XXXXX)
    loop
        v_client_no := 'SK-' || lpad((floor(random() * 90000) + 10000)::int::text, 5, '0');
        exit when not exists (select 1 from ric_clients where client_no = v_client_no);
    end loop;

    -- Create client record
    insert into ric_clients (
        client_name, country, registration_email, phone,
        client_no, license_status,
        trial_start_date, trial_end_date,
        created_at
    ) values (
        trim(p_business_name), trim(p_country),
        lower(trim(p_email)), trim(p_phone),
        v_client_no, 'TRIAL',
        current_date, current_date + 30,
        now()
    ) returning id into v_client_id;

    -- Create company
    insert into ric_companies (
        client_id, company_name, company_short,
        country, base_currency, local_currency,
        created_at
    ) values (
        v_client_id,
        trim(p_company_name), upper(trim(p_company_short)),
        trim(p_country), trim(p_base_currency), trim(p_local_currency),
        now()
    ) returning id into v_company_id;

    -- Create location
    insert into ric_locations (
        client_id, company_id,
        location_name, location_short, location_type,
        created_at
    ) values (
        v_client_id, v_company_id,
        trim(p_location_name), upper(trim(p_location_short)),
        upper(trim(p_location_type)),
        now()
    ) returning id into v_location_id;

    -- Create first admin user with bcrypt password hash
    insert into rim_users (
        client_id, company_id, default_location_id,
        username, full_name, email, phone,
        password_hash, must_change_password,
        created_at
    ) values (
        v_client_id, v_company_id, v_location_id,
        lower(trim(p_username)), trim(p_admin_name),
        lower(trim(p_email)), trim(p_phone),
        crypt(p_password, gen_salt('bf')), false,
        now()
    ) returning id into v_user_id;

    -- Seed modules, master menus, and grant full admin access to first user
    perform fn_seed_client_modules(v_client_id, v_company_id, v_user_id);

    return json_build_object(
        'client_id',   v_client_id,
        'client_no',   v_client_no,
        'company_id',  v_company_id,
        'location_id', v_location_id
    );
end;
$$;

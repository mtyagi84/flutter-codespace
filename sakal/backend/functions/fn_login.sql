-- ============================================================
-- fn_login
-- Verifies credentials using bcrypt. Handles account lockout.
-- Returns session data on success; raises exception on failure.
-- PostgREST: POST /rest/v1/rpc/fn_login
-- ============================================================

create or replace function fn_login(
    p_client_no text,
    p_username  text,
    p_password  text
) returns json language plpgsql security definer as $$
declare
    v_client       ric_clients%rowtype;
    v_user         rim_users%rowtype;
    v_company_name text;
begin
    -- Find and validate client
    select * into v_client
    from ric_clients
    where client_no  = upper(trim(p_client_no))
      and is_deleted = false
      and is_active  = true;

    if not found then
        raise exception 'INVALID_CREDENTIALS';
    end if;

    -- Check license / trial expiry
    if v_client.license_status = 'EXPIRED' then
        raise exception 'LICENSE_EXPIRED';
    end if;

    if v_client.license_status = 'TRIAL'
       and v_client.trial_end_date < current_date then
        update ric_clients
        set license_status = 'EXPIRED'
        where id = v_client.id;
        raise exception 'TRIAL_EXPIRED';
    end if;

    -- Find user within this client
    select * into v_user
    from rim_users
    where client_id  = v_client.id
      and username   = lower(trim(p_username))
      and is_deleted = false;

    if not found then
        raise exception 'INVALID_CREDENTIALS';
    end if;

    if not v_user.is_active then
        raise exception 'ACCOUNT_INACTIVE';
    end if;

    if v_user.locked_until is not null and v_user.locked_until > now() then
        raise exception 'ACCOUNT_LOCKED';
    end if;

    -- Verify bcrypt password
    if v_user.password_hash != crypt(p_password, v_user.password_hash) then
        update rim_users
        set failed_attempts = failed_attempts + 1,
            locked_until = case
                when failed_attempts + 1 >= 5
                then now() + interval '30 minutes'
                else locked_until
            end
        where id = v_user.id;
        raise exception 'INVALID_CREDENTIALS';
    end if;

    -- Success — reset lockout counters and record login time
    update rim_users
    set failed_attempts = 0,
        locked_until    = null,
        last_login_at   = now()
    where id = v_user.id;

    -- Fetch company name for session
    select company_name into v_company_name
    from ric_companies
    where id = v_user.company_id;

    return json_build_object(
        'user_id',      v_user.id,
        'client_id',    v_user.client_id,
        'client_no',    v_client.client_no,
        'company_id',   v_user.company_id,
        'company_name', coalesce(v_company_name, ''),
        'location_id',  v_user.default_location_id,
        'full_name',    v_user.full_name,
        'username',     v_user.username,
        'must_change',  v_user.must_change_password
    );
end;
$$;

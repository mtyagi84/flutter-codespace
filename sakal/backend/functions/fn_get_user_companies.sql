-- ============================================================
-- fn_get_user_companies
-- Returns all companies a user has menu access to.
-- Used by the "Switch Company" dialog in the app shell.
-- PostgREST: POST /rest/v1/rpc/fn_get_user_companies
-- ============================================================

create or replace function fn_get_user_companies(
    p_user_id   uuid,
    p_client_id uuid
) returns json language plpgsql security definer as $$
declare
    v_result json;
begin
    select json_agg(
        json_build_object(
            'company_id',   co.id,
            'company_name', co.company_name
        ) order by co.company_name
    ) into v_result
    from ric_companies co
    where co.client_id  = p_client_id
      and co.is_deleted = false
      and co.is_active  = true
      and exists (
          select 1 from ric_user_menus um
          where um.company_id   = co.id
            and um.user_id      = p_user_id
            and um.is_deleted   = false
            and um.view_allowed = true
      );

    return coalesce(v_result, '[]'::json);
end;
$$;

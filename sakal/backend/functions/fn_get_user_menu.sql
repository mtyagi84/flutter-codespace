-- ============================================================
-- fn_get_user_menu
-- Returns 3-level sidebar menu: module → group → features.
-- Groups are visual sections within a module (group_code on ric_master_menus).
-- PostgREST: POST /rest/v1/rpc/fn_get_user_menu
-- ============================================================

create or replace function fn_get_user_menu(
    p_user_id    uuid,
    p_client_id  uuid,
    p_company_id uuid
) returns json language plpgsql security definer as $$
declare
    v_result json;
begin
    select json_agg(
        json_build_object(
            'module_code', sm.module_code,
            'module_name', sm.module_name,
            'serial_no',   sm.serial_no,
            'groups', (
                select json_agg(
                    json_build_object(
                        'group_code', grp.group_code,
                        'group_name', grp.group_name,
                        'serial_no',  grp.group_serial_no,
                        'features', (
                            select json_agg(
                                json_build_object(
                                    'feature_code',         mm.feature_code,
                                    'feature_name',         mm.feature_name,
                                    'screen_name',          mm.screen_name,
                                    'serial_no',            mm.serial_no,
                                    'add_allowed',          um.add_allowed,
                                    'edit_allowed',         um.edit_allowed,
                                    'approve_allowed',      um.approve_allowed,
                                    'copy_allowed',         um.copy_allowed,
                                    'excel_upload_allowed', um.excel_upload_allowed
                                ) order by mm.serial_no
                            )
                            from ric_user_menus um
                            join ric_master_menus mm
                                on  mm.feature_code = um.feature_code
                                and mm.client_id    = um.client_id
                                and mm.company_id   = um.company_id
                            where um.user_id      = p_user_id
                              and um.client_id    = p_client_id
                              and um.company_id   = p_company_id
                              and um.module_id    = sm.id
                              and mm.group_code   = grp.group_code
                              and um.view_allowed = true
                              and um.is_active    = true
                              and um.is_deleted   = false
                              and mm.is_active    = true
                              and mm.is_deleted   = false
                        )
                    ) order by grp.group_serial_no
                )
                from (
                    select distinct mm2.group_code, mm2.group_name, mm2.group_serial_no
                    from ric_master_menus mm2
                    join ric_user_menus um2
                        on  um2.feature_code = mm2.feature_code
                        and um2.client_id    = mm2.client_id
                        and um2.company_id   = mm2.company_id
                    where mm2.client_id    = p_client_id
                      and mm2.company_id   = p_company_id
                      and mm2.module_id    = sm.id
                      and um2.user_id      = p_user_id
                      and um2.view_allowed = true
                      and um2.is_deleted   = false
                      and mm2.is_active    = true
                      and mm2.is_deleted   = false
                      and mm2.group_code   is not null
                ) grp
            )
        ) order by sm.serial_no
    ) into v_result
    from ric_system_modules sm
    where sm.client_id  = p_client_id
      and sm.company_id = p_company_id
      and sm.is_active  = true
      and sm.is_deleted = false
      and exists (
          select 1 from ric_user_menus um2
          where um2.module_id    = sm.id
            and um2.user_id      = p_user_id
            and um2.view_allowed = true
            and um2.is_deleted   = false
      );

    return coalesce(v_result, '[]'::json);
end;
$$;

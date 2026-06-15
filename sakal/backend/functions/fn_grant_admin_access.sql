-- ============================================================
-- fn_grant_admin_access
-- Grants full access to all master menu features for a user.
-- Use for: existing clients after adding a new company,
-- or manually granting admin rights to a user.
-- PostgREST: POST /rest/v1/rpc/fn_grant_admin_access
-- ============================================================

create or replace function fn_grant_admin_access(
    p_user_id    uuid,
    p_client_id  uuid,
    p_company_id uuid
) returns void language plpgsql security definer as $$
begin
    insert into ric_user_menus (
        client_id, company_id, user_id, module_id, feature_code, serial_no,
        view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
    )
    select
        mm.client_id, mm.company_id,
        p_user_id,
        mm.module_id, mm.feature_code, mm.serial_no,
        true, true,
        mm.approve_allowed,
        mm.copy_allowed,
        mm.excel_upload_allowed
    from ric_master_menus mm
    where mm.client_id  = p_client_id
      and mm.company_id = p_company_id
      and mm.is_deleted = false
    on conflict (client_id, company_id, user_id, feature_code) do update
        set view_allowed         = true,
            edit_allowed         = true,
            approve_allowed      = excluded.approve_allowed,
            copy_allowed         = excluded.copy_allowed,
            excel_upload_allowed = excluded.excel_upload_allowed,
            updated_at           = now();
end;
$$;

-- ============================================================
-- 012_permissions_fn.sql
-- SQL functions for the User Permissions screen.
-- Run after 004_menus_and_modules.sql and 005_alter_master_menus.sql
-- ============================================================


-- ── fn_get_user_permissions ───────────────────────────────────────────────────
-- Returns all active features for a company with the user's current permissions.
-- Uses LEFT JOIN so features with no ric_user_menus row appear as all-false.
-- Ordered by module serial_no → group serial_no → feature serial_no.
-- Call via PostgREST: POST /rpc/fn_get_user_permissions
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_get_user_permissions(
    p_user_id    uuid,
    p_client_id  uuid,
    p_company_id uuid
)
RETURNS TABLE (
    feature_code         text,
    feature_name         text,
    serial_no            integer,
    module_id            uuid,
    module_code          text,
    module_name          text,
    module_serial_no     integer,
    group_code           text,
    group_name           text,
    group_serial_no      integer,
    master_approve       boolean,
    master_copy          boolean,
    master_excel         boolean,
    view_allowed         boolean,
    edit_allowed         boolean,
    approve_allowed      boolean,
    copy_allowed         boolean,
    excel_upload_allowed boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        mm.feature_code,
        mm.feature_name,
        mm.serial_no,
        sm.id                                       AS module_id,
        sm.module_code,
        sm.module_name,
        sm.serial_no                                AS module_serial_no,
        mm.group_code,
        mm.group_name,
        mm.group_serial_no,
        mm.approve_allowed                          AS master_approve,
        mm.copy_allowed                             AS master_copy,
        mm.excel_upload_allowed                     AS master_excel,
        COALESCE(um.view_allowed,         false)    AS view_allowed,
        COALESCE(um.edit_allowed,         false)    AS edit_allowed,
        COALESCE(um.approve_allowed,      false)    AS approve_allowed,
        COALESCE(um.copy_allowed,         false)    AS copy_allowed,
        COALESCE(um.excel_upload_allowed, false)    AS excel_upload_allowed
    FROM ric_master_menus mm
    JOIN ric_system_modules sm
        ON  sm.id         = mm.module_id
        AND sm.client_id  = mm.client_id
        AND sm.company_id = mm.company_id
    LEFT JOIN ric_user_menus um
        ON  um.feature_code = mm.feature_code
        AND um.client_id    = mm.client_id
        AND um.company_id   = mm.company_id
        AND um.user_id      = p_user_id
        AND um.is_deleted   = false
    WHERE mm.client_id  = p_client_id
      AND mm.company_id = p_company_id
      AND mm.is_active  = true
      AND mm.is_deleted = false
      AND sm.is_active  = true
      AND sm.is_deleted = false
    ORDER BY sm.serial_no, mm.group_serial_no, mm.serial_no;
$$;


-- ── fn_upsert_user_permission ─────────────────────────────────────────────────
-- UPSERT a single feature's permissions for a user.
-- Called on every checkbox change in the permissions screen (auto-save).
-- Call via PostgREST: POST /rpc/fn_upsert_user_permission
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_upsert_user_permission(
    p_client_id             uuid,
    p_company_id            uuid,
    p_user_id               uuid,
    p_module_id             uuid,
    p_feature_code          text,
    p_view_allowed          boolean DEFAULT false,
    p_edit_allowed          boolean DEFAULT false,
    p_approve_allowed       boolean DEFAULT false,
    p_copy_allowed          boolean DEFAULT false,
    p_excel_upload_allowed  boolean DEFAULT false,
    p_updated_by            uuid    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO ric_user_menus (
        client_id, company_id, user_id, module_id, feature_code,
        view_allowed, edit_allowed, approve_allowed,
        copy_allowed, excel_upload_allowed,
        is_active, is_deleted, created_at, created_by
    ) VALUES (
        p_client_id, p_company_id, p_user_id, p_module_id, p_feature_code,
        p_view_allowed, p_edit_allowed, p_approve_allowed,
        p_copy_allowed, p_excel_upload_allowed,
        true, false, now(), p_updated_by
    )
    ON CONFLICT (client_id, company_id, user_id, feature_code)
    DO UPDATE SET
        view_allowed         = EXCLUDED.view_allowed,
        edit_allowed         = EXCLUDED.edit_allowed,
        approve_allowed      = EXCLUDED.approve_allowed,
        copy_allowed         = EXCLUDED.copy_allowed,
        excel_upload_allowed = EXCLUDED.excel_upload_allowed,
        module_id            = EXCLUDED.module_id,
        is_active            = true,
        is_deleted           = false,
        updated_at           = now(),
        updated_by           = p_updated_by;
END;
$$;


-- ── fn_copy_user_permissions ──────────────────────────────────────────────────
-- Copies all permissions from one user to another (replaces target's permissions).
-- Call via PostgREST: POST /rpc/fn_copy_user_permissions
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_copy_user_permissions(
    p_from_user_id  uuid,
    p_to_user_id    uuid,
    p_client_id     uuid,
    p_company_id    uuid,
    p_copied_by     uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Soft-delete existing permissions for target user
    UPDATE ric_user_menus
    SET    is_deleted  = true,
           updated_at  = now(),
           updated_by  = p_copied_by
    WHERE  user_id     = p_to_user_id
      AND  client_id   = p_client_id
      AND  company_id  = p_company_id;

    -- Copy source user's active permissions to target user
    INSERT INTO ric_user_menus (
        client_id, company_id, user_id, module_id, feature_code,
        view_allowed, edit_allowed, approve_allowed,
        copy_allowed, excel_upload_allowed,
        is_active, is_deleted, created_at, created_by
    )
    SELECT
        p_client_id, p_company_id, p_to_user_id, module_id, feature_code,
        view_allowed, edit_allowed, approve_allowed,
        copy_allowed, excel_upload_allowed,
        true, false, now(), p_copied_by
    FROM ric_user_menus
    WHERE user_id    = p_from_user_id
      AND client_id  = p_client_id
      AND company_id = p_company_id
      AND is_deleted = false
    ON CONFLICT (client_id, company_id, user_id, feature_code)
    DO UPDATE SET
        view_allowed         = EXCLUDED.view_allowed,
        edit_allowed         = EXCLUDED.edit_allowed,
        approve_allowed      = EXCLUDED.approve_allowed,
        copy_allowed         = EXCLUDED.copy_allowed,
        excel_upload_allowed = EXCLUDED.excel_upload_allowed,
        module_id            = EXCLUDED.module_id,
        is_active            = true,
        is_deleted           = false,
        updated_at           = now(),
        updated_by           = p_copied_by;
END;
$$;

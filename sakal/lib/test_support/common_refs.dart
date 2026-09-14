import 'backend_verifier.dart';
import 'test_tenant_config.dart';

/// Fetches reference IDs shared by most backend-RPC test files (product's
/// UOM, base currency's `rim_currencies.id` surrogate key) — pulled out
/// once here instead of re-querying identically in every
/// `test/backend/*_backend_test.dart` file. Call `CommonRefs.load(verifier)`
/// once in a `setUpAll`.
class CommonRefs {
  final String uomId;
  final String currencyId; // rim_currencies.id (UUID), not the ISO code

  CommonRefs._(this.uomId, this.currencyId);

  static Future<CommonRefs> load(BackendVerifier verifier) async {
    final product = await verifier.getOne(
      'rim_products',
      {'id': 'eq.${TestTenantConfig.productId}'},
      select: 'base_uom_id',
    );
    final currency = await verifier.getOne(
      'rim_currencies',
      {'currency_id': 'eq.USD'},
      select: 'id',
    );
    return CommonRefs._(
      product['base_uom_id'] as String,
      currency['id'] as String,
    );
  }

  /// Get-or-create a Department -> Consumption Area -> expense-account
  /// mapping (`rim_department_consumption_areas`) for the QA tenant — needed
  /// by Material Requisition's Approve (`LINE_DEPARTMENT_AREA_REQUIRED`) and
  /// Material Issue's GL posting. The QA tenant had ZERO rows here as of
  /// 2026-09-14 (confirmed by direct query) — this is real, one-time setup
  /// data a real company configures once through the admin UI, not
  /// per-test-run fixture noise, so it's created idempotently (checked
  /// first, only inserted if missing) and persists across runs since
  /// `resetQaTenant()` never touches master/setup tables.
  static Future<DepartmentAreaRef> loadOrCreateDepartmentArea(BackendVerifier verifier) async {
    final existing = await verifier.get('rim_department_consumption_areas', {'limit': '1'});
    if (existing.isNotEmpty) {
      return DepartmentAreaRef(
        departmentId: existing.first['department_id'] as String,
        consumptionAreaId: existing.first['consumption_area_id'] as String,
        accountId: existing.first['account_id'] as String,
      );
    }

    final types = await verifier.getUnscoped('rim_common_master_types', const {}, select: 'id,type_name');
    final deptTypeId = types.firstWhere((t) => t['type_name'] == 'Department')['id'] as String;
    final areaTypeId = types.firstWhere((t) => t['type_name'] == 'Consumption Area')['id'] as String;

    final department = await verifier.insert('rim_common_masters', {
      'type_id': deptTypeId,
      'description': 'QA Backend Test Department',
      'sort_order': 1,
      'is_active': true,
    });
    final area = await verifier.insert('rim_common_masters', {
      'type_id': areaTypeId,
      'description': 'QA Backend Test Consumption Area',
      'sort_order': 1,
      'is_active': true,
    });
    final account = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.5210'}, // "Administrative Expenses" — a leaf (posting_allowed=true)
      // account in the QA tenant's seeded COA. 5200 "Operating Expense" was
      // tried first and rejected by fn_post_voucher with ACCOUNT_NOT_POSTABLE
      // — it's a group/header account (5210's own parent), confirmed live
      // 2026-09-14 via rim_accounts.posting_allowed.
      select: 'id',
    );

    final mapping = await verifier.insert('rim_department_consumption_areas', {
      'department_id': department['id'],
      'consumption_area_id': area['id'],
      'account_id': account['id'],
    });

    return DepartmentAreaRef(
      departmentId: mapping['department_id'] as String,
      consumptionAreaId: mapping['consumption_area_id'] as String,
      accountId: mapping['account_id'] as String,
    );
  }

  /// Get-or-create a SECOND location for the QA tenant — Stock Transfer
  /// (Request/Transfer/Receipt) genuinely needs two distinct locations to
  /// test at all, and the QA tenant had exactly ONE (`TestTenantConfig.
  /// locationId`, "QA Head Office") as of 2026-09-14. The company's
  /// `inter_location_model` is `SIMPLE` (confirmed live), so a plain
  /// `group_id: null` location is correct — no location-group setup needed
  /// for a same-book stock transfer. Idempotent, persists across runs
  /// (`resetQaTenant()` never touches master/setup tables).
  static Future<String> loadOrCreateSecondLocation(BackendVerifier verifier) async {
    final existing = await verifier.get(
      'ric_locations',
      {'id': 'neq.${TestTenantConfig.locationId}', 'limit': '1'},
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as String;
    }
    final created = await verifier.insert('ric_locations', {
      'location_name': 'QA Warehouse 2',
      'location_short': 'QAWH2',
      'location_type': 'WAREHOUSE',
      'is_active': true,
      'is_negative_stock_allowed': false,
      'is_issue_allowed': true,
    });
    return created['id'] as String;
  }

  /// Get-or-create a COMPANY-granularity STOCK_IN_TRANSIT_ACCOUNT link —
  /// needed by Stock Transfer's Approve (`fn_approve_stock_transfer` raises
  /// `ACCOUNT_LINK_NOT_CONFIGURED` without it, confirmed live 2026-09-14).
  static Future<void> ensureStockInTransitAccountLink(BackendVerifier verifier) =>
      _ensureCompanyAccountLink(verifier, 'STOCK_IN_TRANSIT_ACCOUNT', TestTenantConfig.stockAccountId);

  /// Get-or-create a COMPANY-granularity STOCK_ADJUSTMENT_ACCOUNT link —
  /// needed by Stock Adjustment's Approve (`fn_approve_stock_adjustment`
  /// raises `ACCOUNT_LINK_NOT_CONFIGURED` without it, confirmed live
  /// 2026-09-14 — the identical gap class as Stock Transfer's own missing
  /// link, both apparently never backfilled when this QA tenant was seeded).
  static Future<void> ensureStockAdjustmentAccountLink(BackendVerifier verifier) =>
      _ensureCompanyAccountLink(verifier, 'STOCK_ADJUSTMENT_ACCOUNT', TestTenantConfig.stockAccountId);

  /// Shared get-or-create for any COMPANY-granularity `rim_account_link_*`
  /// pair — the generic mechanism CLAUDE.md's "Account Link Setup
  /// Framework" describes, used identically by Stock Transfer's
  /// STOCK_IN_TRANSIT_ACCOUNT and Stock Adjustment's STOCK_ADJUSTMENT_
  /// ACCOUNT (a THIRD occurrence would just add another one-line wrapper
  /// here, not new logic). Reuses whatever account is passed in as a
  /// pragmatic stand-in — no dedicated accounts of these exact names
  /// existed in the QA tenant's seeded COA, and these tests care about
  /// status/quantity transitions, not the specific GL account chosen.
  static Future<void> _ensureCompanyAccountLink(
    BackendVerifier verifier,
    String linkKey,
    String accountId,
  ) async {
    final types = await verifier.getUnscoped('rim_account_link_types', const {}, select: 'id,link_key');
    final linkTypeId = types.firstWhere((t) => t['link_key'] == linkKey)['id'] as String;

    final existing = await verifier.get('rim_account_link_defaults', {'link_type_id': 'eq.$linkTypeId'});
    if (existing.isNotEmpty) return;

    await verifier.insert('rim_account_link_setup', {
      'link_type_id': linkTypeId,
      'link_type': 'COMPANY',
    });
    await verifier.insert('rim_account_link_defaults', {
      'link_type_id': linkTypeId,
      'link_key_id': null,
      'account_id': accountId,
      'is_active': true,
    });
  }
}

class DepartmentAreaRef {
  final String departmentId;
  final String consumptionAreaId;
  final String accountId;
  const DepartmentAreaRef({
    required this.departmentId,
    required this.consumptionAreaId,
    required this.accountId,
  });
}

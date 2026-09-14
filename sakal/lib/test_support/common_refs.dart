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

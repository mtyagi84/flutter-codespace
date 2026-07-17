import 'package:drift/drift.dart';
import '../app_database.dart';

/// Local datasource for [AccountsCache]. Extracted from the inline Drift
/// code that used to live directly in `accountsProvider`
/// (core/providers/master_cache_providers.dart) so the same read/write
/// logic can be reused by the new Customers/Suppliers master-data sync
/// module and by Sales Invoice's `getCustomerDetails` offline fallback,
/// without duplicating the query shape a second time.
class AccountsLocalDs {
  final AppDatabase _db;
  AccountsLocalDs(this._db);

  Future<List<Map<String, dynamic>>> getAccounts({
    required String clientId,
    required String companyId,
  }) async {
    final rows = await (_db.select(_db.accountsCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.isActive.equals(true)))
        .get();
    return rows.map(_toPickerMap).toList();
  }

  /// Full detail read for one account — backs Sales Invoice's
  /// `getCustomerDetails` offline fallback.
  Future<Map<String, dynamic>?> getById(String id) async {
    final row = await (_db.select(_db.accountsCache)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return {
      'id': row.id,
      'account_code': row.accountCode,
      'account_name': row.accountName,
      'credit_limit': row.creditLimit,
      'credit_days': row.creditDays,
      'is_credit_blocked': row.isCreditBlocked,
      'phone': row.phone,
      'email': row.email,
      'address_line1': row.addressLine1,
      'address_line2': row.addressLine2,
      'rim_currencies': {'currency_id': row.accountCurrency},
    };
  }

  Future<void> upsertAccounts(List<Map<String, dynamic>> accounts, {required String clientId, required String companyId}) async {
    final now = DateTime.now();
    await _db.batch((batch) {
      for (final a in accounts) {
        final parentRel = a['parent'];
        final currRel = a['rim_currencies'];
        batch.insert(
          _db.accountsCache,
          AccountsCacheCompanion.insert(
            id: a['id'] as String,
            clientId: clientId,
            companyId: companyId,
            accountCode: a['account_code'] as String? ?? '',
            accountName: a['account_name'] as String? ?? '',
            accountNature: a['account_nature'] as String? ?? '',
            parentName: Value(parentRel is Map ? (parentRel['account_name'] as String? ?? '') : ''),
            accountCurrency: Value(currRel is Map ? (currRel['currency_id'] as String? ?? '') : ''),
            creditLimit: Value((a['credit_limit'] as num?)?.toDouble()),
            creditDays: Value(a['credit_days'] as int?),
            isCreditBlocked: Value(a['is_credit_blocked'] as bool?),
            phone: Value(a['phone'] as String?),
            email: Value(a['email'] as String?),
            addressLine1: Value(a['address_line1'] as String?),
            addressLine2: Value(a['address_line2'] as String?),
            cachedAt: Value(now),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Map<String, dynamic> _toPickerMap(AccountsCacheEntry r) => {
        'id': r.id,
        'account_code': r.accountCode,
        'account_name': r.accountName,
        'account_nature': r.accountNature,
        'parent': {'account_name': r.parentName},
        'rim_currencies': {'currency_id': r.accountCurrency},
      };
}

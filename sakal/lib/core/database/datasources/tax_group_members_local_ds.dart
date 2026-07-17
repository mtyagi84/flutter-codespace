import 'package:drift/drift.dart';
import '../app_database.dart';

/// Local datasource for [TaxGroupMembersCache] — tax_group_id -> [tax_id]
/// membership (rim_tax_group_members), mirroring the remote
/// `getTaxGroupMemberTaxIds` shape.
class TaxGroupMembersLocalDs {
  final AppDatabase _db;
  TaxGroupMembersLocalDs(this._db);

  Future<Map<String, List<String>>> getMemberTaxIds(List<String> groupIds) async {
    if (groupIds.isEmpty) return {};
    final rows = await (_db.select(_db.taxGroupMembersCache)
          ..where((t) => t.taxGroupId.isIn(groupIds)))
        .get();
    final result = <String, List<String>>{};
    for (final r in rows) {
      result.putIfAbsent(r.taxGroupId, () => []).add(r.taxId);
    }
    return result;
  }

  Future<void> upsert(List<Map<String, dynamic>> rows) async {
    await _db.batch((batch) {
      for (final r in rows) {
        batch.insert(
          _db.taxGroupMembersCache,
          TaxGroupMembersCacheCompanion.insert(
            taxGroupId: r['tax_group_id'] as String,
            taxId: r['tax_id'] as String,
            cachedAt: Value(DateTime.now()),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }
}

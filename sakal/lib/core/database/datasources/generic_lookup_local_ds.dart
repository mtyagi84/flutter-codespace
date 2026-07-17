import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../app_database.dart';

/// Local datasource for [GenericLookupCache] — the shared cache table for
/// simple reference-data picker lists (Currencies, Locations, Countries, PO
/// tax groups, etc). See generic_lookup_cache_table.dart for why this is one
/// shared table instead of a dedicated one per lookup.
class GenericLookupLocalDs {
  final AppDatabase _db;
  GenericLookupLocalDs(this._db);

  Future<List<Map<String, dynamic>>> getLookups({
    required String cacheKey,
    String? clientId,
    String? companyId,
    String? parentId,
  }) async {
    final q = _db.select(_db.genericLookupCache)
      ..where((t) => t.cacheKey.equals(cacheKey))
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.label)]);
    if (clientId != null) q.where((t) => t.clientId.equals(clientId));
    if (companyId != null) q.where((t) => t.companyId.equals(companyId));
    if (parentId != null) q.where((t) => t.parentId.equals(parentId));
    final rows = await q.get();
    return rows.map((r) => jsonDecode(r.dataJson) as Map<String, dynamic>).toList();
  }

  /// Single-row-by-PK read — for per-user rows like a Quick Invoice Setup
  /// entry or sales-controls row, where `getLookups`' client/company/parent
  /// filters aren't precise enough (id IS the discriminator).
  Future<Map<String, dynamic>?> getLookupById({
    required String cacheKey,
    required String id,
  }) async {
    final row = await (_db.select(_db.genericLookupCache)
          ..where((t) => t.cacheKey.equals(cacheKey) & t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : jsonDecode(row.dataJson) as Map<String, dynamic>;
  }

  Future<void> upsertLookups({
    required String cacheKey,
    required List<Map<String, dynamic>> rows,
    required String Function(Map<String, dynamic>) idOf,
    String Function(Map<String, dynamic>)? labelOf,
    String Function(Map<String, dynamic>)? parentIdOf,
    int Function(Map<String, dynamic>)? sortOrderOf,
    String clientId = '',
    String companyId = '',
  }) async {
    final now = DateTime.now();
    for (final row in rows) {
      await _db.into(_db.genericLookupCache).insertOnConflictUpdate(
            GenericLookupCacheCompanion.insert(
              cacheKey:  cacheKey,
              id:        idOf(row),
              clientId:  Value(clientId),
              companyId: Value(companyId),
              label:     Value(labelOf?.call(row) ?? ''),
              parentId:  Value(parentIdOf?.call(row) ?? ''),
              sortOrder: Value(sortOrderOf?.call(row) ?? 0),
              dataJson:  Value(jsonEncode(row)),
              cachedAt:  Value(now),
            ),
          );
    }
  }
}

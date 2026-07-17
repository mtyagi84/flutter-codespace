import 'package:drift/drift.dart';
import '../app_database.dart';

/// Local datasource for [TaxRatesCache] — STANDARD-label tax rates
/// (rim_tax_rates), mirroring the remote `getTaxRatesByIds`'s date-window
/// selection: per tax_id, the most recent row where
/// effective_from <= asOf <= (effective_to ?? infinity).
class TaxRatesLocalDs {
  final AppDatabase _db;
  TaxRatesLocalDs(this._db);

  Future<Map<String, double>> getRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) async {
    if (taxIds.isEmpty) return {};
    final rows = await (_db.select(_db.taxRatesCache)
          ..where((t) => t.taxId.isIn(taxIds) & t.isActive.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(t.effectiveFrom)]))
        .get();
    final asOf = DateTime.tryParse(asOfDate) ?? DateTime.now();
    return selectActiveRates(
      rows.map((r) => {
            'tax_id': r.taxId,
            'rate': r.rate,
            'effective_from': r.effectiveFrom,
            'effective_to': r.effectiveTo,
          }),
      asOf,
    );
  }

  /// Pure function — no DB access — so it's independently unit-testable.
  /// [rows] is expected pre-ordered effective_from DESC (or any order; the
  /// first matching row per tax_id wins, same "skip once matched" rule the
  /// remote query uses).
  static Map<String, double> selectActiveRates(Iterable<Map<String, dynamic>> rows, DateTime asOf) {
    final result = <String, double>{};
    for (final m in rows) {
      final taxId = m['tax_id'] as String;
      if (result.containsKey(taxId)) continue;
      final from = DateTime.tryParse(m['effective_from'] as String? ?? '');
      final toStr = m['effective_to'] as String?;
      final to = toStr != null ? DateTime.tryParse(toStr) : null;
      if (from != null && !asOf.isBefore(from) && (to == null || !asOf.isAfter(to))) {
        result[taxId] = (m['rate'] as num).toDouble();
      }
    }
    return result;
  }

  Future<void> upsert(List<Map<String, dynamic>> rows) async {
    await _db.batch((batch) {
      for (final r in rows) {
        batch.insert(
          _db.taxRatesCache,
          TaxRatesCacheCompanion.insert(
            taxId: r['tax_id'] as String,
            rateLabel: Value(r['rate_label'] as String? ?? 'STANDARD'),
            rate: Value((r['rate'] as num?)?.toDouble() ?? 0),
            effectiveFrom: r['effective_from'] as String,
            effectiveTo: Value(r['effective_to'] as String?),
            isActive: Value(r['is_active'] as bool? ?? true),
            cachedAt: Value(DateTime.now()),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }
}

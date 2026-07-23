import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class ExpenseVoucherLocalDs {
  final AppDatabase _db;
  ExpenseVoucherLocalDs(this._db);

  Future<List<Map<String, dynamic>>> listVouchers({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final q = _db.select(_db.expenseVoucherHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.transDate), (t) => OrderingTerm.desc(t.transNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['trans_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
  }) async {
    final row = await (_db.select(_db.expenseVoucherHeadersCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transNo.equals(transNo))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.transDate)])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
  }) async {
    final rows = await (_db.select(_db.expenseVoucherLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transNo.equals(transNo))
          ..where((t) => t.transDate.equals(transDate))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from raw save-payload Maps (offline save path) ────────────────

  Future<void> cacheFromMaps(
    String effectiveTransNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now = DateTime.now();
    final clientId = headerMap['client_id'] as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final transDate = headerMap['trans_date'] as String? ?? '';

    await _db.into(_db.expenseVoucherHeadersCache).insertOnConflictUpdate(
          ExpenseVoucherHeadersCacheCompanion.insert(
            clientId: clientId,
            companyId: companyId,
            locationId: Value(headerMap['location_id'] as String? ?? ''),
            transNo: effectiveTransNo,
            transDate: transDate,
            supplierId: headerMap['supplier_id'] as String? ?? '',
            supplierCode: Value(headerMap['supplier_code'] as String? ?? ''),
            supplierName: Value(headerMap['supplier_name'] as String? ?? ''),
            currencyId: headerMap['currency_id'] as String? ?? '',
            currencyCode: Value(headerMap['currency_code'] as String? ?? ''),
            rateToBase: Value((headerMap['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal: Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            billNo: Value(headerMap['bill_no'] as String? ?? ''),
            billDate: Value(headerMap['bill_date'] as String? ?? ''),
            remarks: Value(headerMap['remarks'] as String? ?? ''),
            status: const Value('DRAFT'),
            isDeleted: const Value(false),
            cachedAt: Value(now),
          ),
        );

    await (_db.delete(_db.expenseVoucherLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transNo.equals(effectiveTransNo))
          ..where((t) => t.transDate.equals(transDate)))
        .go();
    for (var i = 0; i < lineMaps.length; i++) {
      final line = lineMaps[i];
      await _db.into(_db.expenseVoucherLinesCache).insert(
            ExpenseVoucherLinesCacheCompanion.insert(
              clientId: clientId,
              companyId: companyId,
              transNo: effectiveTransNo,
              transDate: transDate,
              serialNo: i + 1,
              accountId: line['account_id'] as String? ?? '',
              accountCode: Value(line['account_code'] as String? ?? ''),
              accountName: Value(line['account_name'] as String? ?? ''),
              amount: Value((line['amount'] as num? ?? 0).toDouble()),
              taxGroupId: Value(line['tax_group_id'] as String? ?? ''),
              taxGroupName: Value(line['tax_group_name'] as String? ?? ''),
              lineRemarks: Value(line['line_remarks'] as String? ?? ''),
              cachedAt: Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(ExpenseVoucherCacheEntry r) => {
        'client_id': r.clientId,
        'company_id': r.companyId,
        'location_id': r.locationId,
        'location': {'location_name': ''},
        'trans_no': r.transNo,
        'trans_date': r.transDate,
        'supplier_id': r.supplierId,
        'supplier': {'account_code': r.supplierCode, 'account_name': r.supplierName},
        'currency_id': r.currencyId,
        'currency': {'currency_id': r.currencyCode},
        'rate_to_base': r.rateToBase,
        'rate_to_local': r.rateToLocal,
        'bill_no': r.billNo,
        'bill_date': r.billDate,
        'remarks': r.remarks,
        'status': r.status,
      };

  Map<String, dynamic> _lineToMap(ExpenseVoucherLineCacheEntry r) => {
        'serial_no': r.serialNo,
        'account_id': r.accountId,
        'account': {'account_code': r.accountCode, 'account_name': r.accountName},
        'amount': r.amount,
        'tax_group_id': r.taxGroupId.isEmpty ? null : r.taxGroupId,
        'tax_group': r.taxGroupId.isEmpty ? null : {'group_name': r.taxGroupName},
        'line_remarks': r.lineRemarks,
      };
}

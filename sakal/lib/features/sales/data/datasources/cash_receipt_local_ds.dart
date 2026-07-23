import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class CashReceiptLocalDs {
  final AppDatabase _db;
  CashReceiptLocalDs(this._db);

  Future<List<Map<String, dynamic>>> listReceipts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final q = _db.select(_db.cashReceiptHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.receiptDate), (t) => OrderingTerm.desc(t.receiptNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['receipt_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String receiptNo,
  }) async {
    final row = await (_db.select(_db.cashReceiptHeadersCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.receiptNo.equals(receiptNo))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.receiptDate)])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  }) async {
    final rows = await (_db.select(_db.cashReceiptLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.receiptNo.equals(receiptNo))
          ..where((t) => t.receiptDate.equals(receiptDate))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from raw save-payload Maps (offline save path) ────────────────

  Future<void> cacheFromMaps(
    String effectiveReceiptNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now = DateTime.now();
    final clientId = headerMap['client_id'] as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final receiptDate = headerMap['receipt_date'] as String? ?? '';

    await _db.into(_db.cashReceiptHeadersCache).insertOnConflictUpdate(
          CashReceiptHeadersCacheCompanion.insert(
            clientId: clientId,
            companyId: companyId,
            locationId: Value(headerMap['location_id'] as String? ?? ''),
            receiptNo: effectiveReceiptNo,
            receiptDate: receiptDate,
            customerId: headerMap['customer_id'] as String? ?? '',
            localAmount: Value((headerMap['local_amount'] as num? ?? 0).toDouble()),
            baseAmount: Value((headerMap['base_amount'] as num? ?? 0).toDouble()),
            remarks: Value(headerMap['remarks'] as String? ?? ''),
            status: const Value('DRAFT'),
            isDeleted: const Value(false),
            cachedAt: Value(now),
          ),
        );

    await (_db.delete(_db.cashReceiptLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.receiptNo.equals(effectiveReceiptNo))
          ..where((t) => t.receiptDate.equals(receiptDate)))
        .go();
    for (var i = 0; i < lineMaps.length; i++) {
      final line = lineMaps[i];
      await _db.into(_db.cashReceiptLinesCache).insert(
            CashReceiptLinesCacheCompanion.insert(
              clientId: clientId,
              companyId: companyId,
              receiptNo: effectiveReceiptNo,
              receiptDate: receiptDate,
              serialNo: i + 1,
              invBillNo: line['inv_bill_no'] as String? ?? '',
              invBillDate: line['inv_bill_date'] as String? ?? '',
              billCurrency: Value(line['bill_currency'] as String? ?? ''),
              appliedAmountLocal: Value((line['applied_amount_local'] as num? ?? 0).toDouble()),
              cachedAt: Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(CashReceiptCacheEntry r) => {
        'client_id': r.clientId,
        'company_id': r.companyId,
        'location_id': r.locationId,
        'location': {'location_name': r.locationName},
        'receipt_no': r.receiptNo,
        'receipt_date': r.receiptDate,
        'customer_id': r.customerId,
        'customer': {'account_code': r.customerCode, 'account_name': r.customerName},
        'local_amount': r.localAmount,
        'base_amount': r.baseAmount,
        'remarks': r.remarks,
        'status': r.status,
        'crv_local_voucher_no': r.crvLocalVoucherNo.isEmpty ? null : r.crvLocalVoucherNo,
        'crv_base_voucher_no': r.crvBaseVoucherNo.isEmpty ? null : r.crvBaseVoucherNo,
        'exc_voucher_no': r.excVoucherNo.isEmpty ? null : r.excVoucherNo,
      };

  Map<String, dynamic> _lineToMap(CashReceiptLineCacheEntry r) => {
        'serial_no': r.serialNo,
        'inv_bill_no': r.invBillNo,
        'inv_bill_date': r.invBillDate,
        'bill_currency': r.billCurrency,
        'applied_amount_local': r.appliedAmountLocal,
      };
}

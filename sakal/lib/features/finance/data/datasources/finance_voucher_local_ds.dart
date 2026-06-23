import 'package:drift/drift.dart' show Value;
import '../../../../core/database/app_database.dart';
import '../../../../core/database/tables/finance_voucher_cache_tables.dart';
import '../models/finance_voucher_model.dart';

class FinanceVoucherLocalDs {
  final AppDatabase _db;
  FinanceVoucherLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<FinanceVoucherHeader?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
    String? transDate,
  }) async {
    final q = _db.select(_db.financeVoucherHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.transNo.equals(transNo))
      ..where((t) => t.isDeleted.equals(false));
    if (transDate != null && transDate.isNotEmpty) {
      q.where((t) => t.transDate.equals(transDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.transDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerFromCache(row);
  }

  Future<List<FinanceVoucherLine>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
  }) async {
    final rows = await (_db.select(_db.financeVoucherLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transNo.equals(transNo))
          ..where((t) => t.transDate.equals(transDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineFromCache).toList();
  }

  // ── Write — from model objects (after remote fetch) ───────────────────────

  Future<void> cacheHeader(FinanceVoucherHeader h) =>
      _db.into(_db.financeVoucherHeadersCache).insertOnConflictUpdate(
            FinanceVoucherHeadersCacheCompanion.insert(
              clientId:        h.clientId,
              companyId:       h.companyId,
              locationId:      Value(h.locationId),
              transNo:         h.transNo,
              transDate:       h.transDate,
              voucherTypeCode: h.voucherTypeCode,
              paymentModeCode: Value(h.paymentModeCode),
              isOnAccount:     Value(h.isOnAccount),
              referenceNo:     Value(h.referenceNo),
              referenceDate:   Value(h.referenceDate),
              chequeNo:        Value(h.chequeNo),
              chequeDate:      Value(h.chequeDate),
              remarks:         Value(h.remarks),
              isPosted:        Value(h.isPosted),
              isDeleted:       Value(h.isDeleted),
              cachedAt:        Value(DateTime.now()),
            ),
          );

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String transNo,
    String transDate,
    List<FinanceVoucherLine> lines,
  ) async {
    await (_db.delete(_db.financeVoucherLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transNo.equals(transNo))
          ..where((t) => t.transDate.equals(transDate)))
        .go();
    for (final line in lines) {
      await _db.into(_db.financeVoucherLinesCache).insert(
            FinanceVoucherLinesCacheCompanion.insert(
              clientId:      clientId,
              companyId:     companyId,
              transNo:       transNo,
              transDate:     transDate,
              serialNo:      line.serialNo,
              accountId:     line.accountId,
              transNature:   line.transNature,
              transAmount:   Value(line.transAmount),
              transCurrency: Value(line.transCurrency),
              baseAmount:    Value(line.baseAmount),
              baseRate:      Value(line.baseRate),
              localAmount:   Value(line.localAmount),
              localRate:     Value(line.localRate),
              partyAmount:   Value(line.partyAmount),
              partyCurrency: Value(line.partyCurrency),
              partyRate:     Value(line.partyRate),
              invBillNo:     Value(line.invBillNo),
              invBillDate:   Value(line.invBillDate),
              lineRemarks:   Value(line.lineRemarks),
              cachedAt:      Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw Maps (offline save path before server round-trip) ────

  Future<void> cacheFromMaps(
    String effectiveTransNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now = DateTime.now();
    final clientId  = headerMap['client_id']  as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final locationId = headerMap['location_id'] as String? ?? '';
    final transDate = headerMap['trans_date'] as String? ?? '';

    await _db.into(_db.financeVoucherHeadersCache).insertOnConflictUpdate(
          FinanceVoucherHeadersCacheCompanion.insert(
            clientId:        clientId,
            companyId:       companyId,
            locationId:      Value(locationId),
            transNo:         effectiveTransNo,
            transDate:       transDate,
            voucherTypeCode: headerMap['voucher_type_code'] as String? ?? '',
            paymentModeCode: Value(headerMap['payment_mode_code'] as String? ?? ''),
            isOnAccount:     Value(headerMap['is_on_account'] as bool? ?? false),
            referenceNo:     Value(headerMap['reference_no']   as String? ?? ''),
            referenceDate:   Value(headerMap['reference_date'] as String? ?? ''),
            chequeNo:        Value(headerMap['cheque_no']      as String? ?? ''),
            chequeDate:      Value(headerMap['cheque_date']    as String? ?? ''),
            remarks:         Value(headerMap['remarks']        as String? ?? ''),
            isPosted:        Value(false),
            isDeleted:       Value(false),
            cachedAt:        Value(now),
          ),
        );

    await (_db.delete(_db.financeVoucherLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transNo.equals(effectiveTransNo))
          ..where((t) => t.transDate.equals(transDate)))
        .go();

    for (final line in lineMaps) {
      await _db.into(_db.financeVoucherLinesCache).insert(
            FinanceVoucherLinesCacheCompanion.insert(
              clientId:      clientId,
              companyId:     companyId,
              locationId:    Value(locationId),
              transNo:       effectiveTransNo,
              transDate:     transDate,
              serialNo:      (line['serial_no'] as num? ?? 0).toInt(),
              accountId:     line['account_id']    as String? ?? '',
              transNature:   line['trans_nature']  as String? ?? '',
              transAmount:   Value((line['trans_amount']  as num? ?? 0).toDouble()),
              transCurrency: Value(line['trans_currency'] as String? ?? ''),
              baseAmount:    Value((line['base_amount']   as num? ?? 0).toDouble()),
              baseRate:      Value((line['base_rate']     as num? ?? 1).toDouble()),
              localAmount:   Value((line['local_amount']  as num? ?? 0).toDouble()),
              localRate:     Value((line['local_rate']    as num? ?? 1).toDouble()),
              partyAmount:   Value((line['party_amount']  as num? ?? 0).toDouble()),
              partyCurrency: Value(line['party_currency'] as String? ?? ''),
              partyRate:     Value((line['party_rate']    as num? ?? 1).toDouble()),
              invBillNo:     Value(line['inv_bill_no']    as String? ?? ''),
              invBillDate:   Value(line['inv_bill_date']  as String? ?? ''),
              lineRemarks:   Value(line['line_remarks']   as String? ?? ''),
              cachedAt:      Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  FinanceVoucherHeader _headerFromCache(FinanceVoucherHeadersCacheEntry r) =>
      FinanceVoucherHeader(
        clientId:        r.clientId,
        companyId:       r.companyId,
        locationId:      r.locationId,
        transNo:         r.transNo,
        transDate:       r.transDate,
        voucherTypeCode: r.voucherTypeCode,
        paymentModeCode: r.paymentModeCode,
        isOnAccount:     r.isOnAccount,
        referenceNo:     r.referenceNo,
        referenceDate:   r.referenceDate,
        chequeNo:        r.chequeNo,
        chequeDate:      r.chequeDate,
        remarks:         r.remarks,
        isPosted:        r.isPosted,
        isDeleted:       r.isDeleted,
      );

  FinanceVoucherLine _lineFromCache(FinanceVoucherLinesCacheEntry r) =>
      FinanceVoucherLine(
        serialNo:      r.serialNo,
        accountId:     r.accountId,
        transNature:   r.transNature,
        transAmount:   r.transAmount,
        transCurrency: r.transCurrency,
        baseAmount:    r.baseAmount,
        baseRate:      r.baseRate,
        localAmount:   r.localAmount,
        localRate:     r.localRate,
        partyAmount:   r.partyAmount,
        partyCurrency: r.partyCurrency,
        partyRate:     r.partyRate,
        invBillNo:     r.invBillNo,
        invBillDate:   r.invBillDate,
        lineRemarks:   r.lineRemarks,
      );
}

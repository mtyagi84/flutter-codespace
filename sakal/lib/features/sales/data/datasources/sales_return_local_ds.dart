import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

/// Offline-SAVE support for Sales Return (retrofit, 2026-07-21) — mirrors
/// SalesInvoiceLocalDs's shape. Approve is never queued offline for this
/// module (see sales_return_entry_screen.dart), so this façade only ever
/// needs to serve a just-saved-offline DRAFT back to its own device.
class SalesReturnLocalDs {
  final AppDatabase _db;
  SalesReturnLocalDs(this._db);

  Future<List<Map<String, dynamic>>> listReturns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.salesReturnHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.returnDate), (t) => OrderingTerm.desc(t.returnNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) =>
          (r['return_no'] as String).toLowerCase().contains(s) ||
          (r['invoice_no'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  }) async {
    final q = _db.select(_db.salesReturnHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.returnNo.equals(returnNo))
      ..where((t) => t.isDeleted.equals(false));
    if (returnDate != null && returnDate.isNotEmpty) {
      q.where((t) => t.returnDate.equals(returnDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.returnDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final rows = await (_db.select(_db.salesReturnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(returnNo))
          ..where((t) => t.returnDate.equals(returnDate))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from raw save-payload Maps (offline save path) ────────────────

  Future<void> cacheFromMaps(
    String effectiveReturnNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now        = DateTime.now();
    final clientId    = headerMap['client_id']  as String? ?? '';
    final companyId   = headerMap['company_id'] as String? ?? '';
    final returnDate = headerMap['return_date'] as String? ?? '';

    await _db.into(_db.salesReturnHeadersCache).insertOnConflictUpdate(
          SalesReturnHeadersCacheCompanion.insert(
            clientId:        clientId,
            companyId:       companyId,
            returnNo:        effectiveReturnNo,
            returnDate:      returnDate,
            invoiceNo:       Value(headerMap['invoice_no'] as String? ?? ''),
            invoiceDate:     Value(headerMap['invoice_date'] as String? ?? ''),
            taxableAmount:   Value((headerMap['taxable_amount'] as num? ?? 0).toDouble()),
            taxAmount:       Value((headerMap['tax_amount'] as num? ?? 0).toDouble()),
            chargesAmount:   Value((headerMap['charges_amount'] as num? ?? 0).toDouble()),
            returnTotal:     Value((headerMap['return_total'] as num? ?? 0).toDouble()),
            refundAmountLocal: Value((headerMap['refund_amount_local'] as num? ?? 0).toDouble()),
            refundAmountBase:  Value((headerMap['refund_amount_base'] as num? ?? 0).toDouble()),
            reason:          Value(headerMap['reason'] as String? ?? ''),
            remarks:         Value(headerMap['remarks'] as String? ?? ''),
            status:          const Value('DRAFT'),
            isDeleted:       const Value(false),
            cachedAt:        Value(now),
          ),
        );

    await (_db.delete(_db.salesReturnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(effectiveReturnNo))
          ..where((t) => t.returnDate.equals(returnDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.salesReturnLinesCache).insert(
            SalesReturnLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              returnNo:            effectiveReturnNo,
              returnDate:          returnDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              invoiceLineSerial:   Value((line['invoice_line_serial'] as num? ?? 0).toInt()),
              productId:           line['product_id'] as String? ?? '',
              barcode:             Value(line['barcode'] as String? ?? ''),
              uomId:               line['uom_id'] as String? ?? '',
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              rate:                Value((line['rate'] as num? ?? 0).toDouble()),
              taxGroupId:          Value(line['tax_group_id'] as String? ?? ''),
              taxAmount:           Value((line['tax_amount'] as num? ?? 0).toDouble()),
              finalAmount:         Value((line['final_amount'] as num? ?? 0).toDouble()),
              chargeAmount:        Value((line['charge_amount'] as num? ?? 0).toDouble()),
              landedAmount:        Value((line['landed_amount'] as num? ?? 0).toDouble()),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(SalesReturnCacheEntry r) => {
        'client_id':          r.clientId,
        'company_id':         r.companyId,
        'location_id':        r.locationId,
        'return_no':          r.returnNo,
        'return_date':        r.returnDate,
        'invoice_no':         r.invoiceNo,
        'invoice_date':       r.invoiceDate,
        'customer_id':        r.customerId,
        'customer':           {'account_code': r.customerCode, 'account_name': r.customerName},
        'return_currency_id': r.returnCurrencyId.isEmpty ? null : r.returnCurrencyId,
        'rate_to_base':       r.rateToBase,
        'rate_to_local':      r.rateToLocal,
        'taxable_amount':     r.taxableAmount,
        'tax_amount':         r.taxAmount,
        'charges_amount':     r.chargesAmount,
        'return_total':       r.returnTotal,
        'refund_amount_local': r.refundAmountLocal,
        'refund_amount_base':  r.refundAmountBase,
        'reason':             r.reason,
        'remarks':            r.remarks,
        'status':             r.status,
        'credit_note_voucher_no': r.creditNoteVoucherNo.isEmpty ? null : r.creditNoteVoucherNo,
        'cos_voucher_no':     r.cosVoucherNo.isEmpty ? null : r.cosVoucherNo,
      };

  Map<String, dynamic> _lineToMap(SalesReturnLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'invoice_line_serial':   r.invoiceLineSerial,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName},
        'barcode':               r.barcode,
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'qty_pack':              r.qtyPack,
        'qty_loose':             r.qtyLoose,
        'base_qty':              r.baseQty,
        'rate':                  r.rate,
        'tax_group_id':          r.taxGroupId,
        'tax_amount':            r.taxAmount,
        'final_amount':          r.finalAmount,
        'charge_amount':         r.chargeAmount,
        'landed_amount':         r.landedAmount,
      };
}

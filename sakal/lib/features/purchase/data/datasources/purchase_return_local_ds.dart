import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';
import '../models/purchase_return_model.dart';

class PurchaseReturnLocalDs {
  final AppDatabase _db;
  PurchaseReturnLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<PurchaseReturnModel>> listPurchaseReturns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.purchaseReturnHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.returnDate), (t) => OrderingTerm.desc(t.returnNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerFromCache).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) =>
          r.returnNo.toLowerCase().contains(s) ||
          (r.supplierName ?? '').toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<PurchaseReturnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  }) async {
    final q = _db.select(_db.purchaseReturnHeadersCache)
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
    return row == null ? null : _headerFromCache(row);
  }

  Future<List<Map<String, dynamic>>> getReturnLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final rows = await (_db.select(_db.purchaseReturnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(returnNo))
          ..where((t) => t.returnDate.equals(returnDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getReturnCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final rows = await (_db.select(_db.purchaseReturnChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(returnNo))
          ..where((t) => t.returnDate.equals(returnDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_chargeToMap).toList();
  }

  // ── Write — from raw Maps (after remote fetch — remote's own leaner select,
  // not the richer save-payload shape cacheFromMaps stores) ──────────────────

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String returnNo,
    String returnDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.purchaseReturnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(returnNo))
          ..where((t) => t.returnDate.equals(returnDate)))
        .go();
    for (final line in lines) {
      await _db.into(_db.purchaseReturnLinesCache).insert(
            PurchaseReturnLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              returnNo:            returnNo,
              returnDate:          returnDate,
              serialNo:            line['serial_no'] as int,
              sourceGrnNo:         Value(line['source_grn_no'] as String? ?? ''),
              sourceGrnDate:       Value(line['source_grn_date'] as String? ?? ''),
              sourceGrnLineSerial: Value(line['source_grn_line_serial'] as int?),
              productId:           line['product_id'] as String,
              baseQty:             Value((line['base_qty'] as num? ?? 0).toDouble()),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  Future<void> cacheCharges(
    String clientId,
    String companyId,
    String returnNo,
    String returnDate,
    List<Map<String, dynamic>> charges,
  ) async {
    await (_db.delete(_db.purchaseReturnChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(returnNo))
          ..where((t) => t.returnDate.equals(returnDate)))
        .go();
    for (final c in charges) {
      await _db.into(_db.purchaseReturnChargeLinesCache).insert(
            PurchaseReturnChargeLinesCacheCompanion.insert(
              clientId:      clientId,
              companyId:     companyId,
              returnNo:      returnNo,
              returnDate:    returnDate,
              serialNo:      c['serial_no'] as int,
              chargeId:      c['charge_id'] as String,
              chargeName:    Value(c['charge_name'] as String? ?? ''),
              isTaxable:     Value(c['is_taxable'] as bool? ?? false),
              taxId:         Value(c['tax_id'] as String? ?? ''),
              nature:        Value(c['nature'] as String? ?? 'ADD'),
              glAccountId:   Value(c['gl_account_id'] as String? ?? ''),
              amount:        Value((c['amount'] as num? ?? 0).toDouble()),
              taxAmount:     Value((c['tax_amount'] as num? ?? 0).toDouble()),
              sourceGrnNo:   Value(c['source_grn_no'] as String? ?? ''),
              sourceGrnDate: Value(c['source_grn_date'] as String? ?? ''),
              cachedAt:      Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from a fetched model (after remote fetch) ──────────────────────

  Future<void> cacheHeader(PurchaseReturnModel h) => _db.into(_db.purchaseReturnHeadersCache).insertOnConflictUpdate(
        PurchaseReturnHeadersCacheCompanion.insert(
          clientId:           h.clientId,
          companyId:          h.companyId,
          locationId:         Value(h.locationId),
          locationName:       Value(h.locationName ?? ''),
          returnNo:           h.returnNo,
          returnDate:         h.returnDate,
          supplierId:         h.supplierId,
          supplierCode:       Value(h.supplierCode ?? ''),
          supplierName:       Value(h.supplierName ?? ''),
          returnCurrencyId:   Value(h.returnCurrencyId ?? ''),
          returnCurrencyCode: Value(h.returnCurrencyCode ?? ''),
          rateToBase:         Value(h.rateToBase),
          rateToLocal:        Value(h.rateToLocal),
          taxableAmount:      Value(h.taxableAmount),
          taxAmount:          Value(h.taxAmount),
          chargesAmount:      Value(h.chargesAmount),
          returnTotal:        Value(h.returnTotal),
          reason:             Value(h.reason ?? ''),
          remarks:            Value(h.remarks ?? ''),
          status:             Value(h.status),
          approvedBy:         Value(h.approvedBy ?? ''),
          approvedAt:         Value(h.approvedAt ?? ''),
          postedVoucherNo:    Value(h.postedVoucherNo ?? ''),
          postedVoucherDate:  Value(h.postedVoucherDate ?? ''),
          cachedAt:           Value(DateTime.now()),
        ),
      );

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────
  //
  // cacheFromMaps only ever receives the maps sent to fn_save_purchase_return
  // — display-only fields (product name, uom label) are NOT available at this
  // point, so getReturnLines' read-back on a return that was only ever cached
  // via cacheFromMaps (never a live getReturnLines fetch while online) will
  // have product_id/qty/rate but no display text. This mirrors the module's
  // documented offline scope: its GRN/supplier picker needs live data, so
  // brand-new returns can't meaningfully be started fully offline anyway —
  // this path exists for the "already mid-edit online, lost signal, hit
  // Save" case, where the screen's own in-memory state already has the
  // display text and doesn't need to re-read it back from cache.
  Future<void> cacheFromMaps(
    String effectiveReturnNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
    List<Map<String, dynamic>> chargeMaps,
  ) async {
    final now = DateTime.now();
    final clientId   = headerMap['client_id']  as String? ?? '';
    final companyId  = headerMap['company_id'] as String? ?? '';
    final returnDate = headerMap['return_date'] as String? ?? '';

    await _db.into(_db.purchaseReturnHeadersCache).insertOnConflictUpdate(
          PurchaseReturnHeadersCacheCompanion.insert(
            clientId:         clientId,
            companyId:        companyId,
            locationId:       Value(headerMap['location_id'] as String? ?? ''),
            returnNo:         effectiveReturnNo,
            returnDate:       returnDate,
            supplierId:       headerMap['supplier_id'] as String? ?? '',
            returnCurrencyId: Value(headerMap['return_currency_id'] as String? ?? ''),
            rateToBase:       Value((headerMap['rate_to_base']  as num? ?? 1).toDouble()),
            rateToLocal:      Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            taxableAmount:    Value((headerMap['taxable_amount'] as num? ?? 0).toDouble()),
            taxAmount:        Value((headerMap['tax_amount'] as num? ?? 0).toDouble()),
            returnTotal:      Value((headerMap['return_total'] as num? ?? 0).toDouble()),
            reason:           Value(headerMap['reason'] as String? ?? ''),
            remarks:          Value(headerMap['remarks'] as String? ?? ''),
            status:           const Value('DRAFT'),
            isDeleted:        const Value(false),
            cachedAt:         Value(now),
          ),
        );

    final batchesByLine = <int, List<Map<String, dynamic>>>{};
    for (final b in batchMaps) {
      batchesByLine.putIfAbsent((b['line_serial'] as num).toInt(), () => []).add(b);
    }
    final serialsByLine = <int, List<Map<String, dynamic>>>{};
    for (final s in serialMaps) {
      serialsByLine.putIfAbsent((s['line_serial'] as num).toInt(), () => []).add(s);
    }

    await (_db.delete(_db.purchaseReturnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(effectiveReturnNo))
          ..where((t) => t.returnDate.equals(returnDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.purchaseReturnLinesCache).insert(
            PurchaseReturnLinesCacheCompanion.insert(
              clientId:           clientId,
              companyId:          companyId,
              returnNo:           effectiveReturnNo,
              returnDate:         returnDate,
              serialNo:           serialNo,
              sourceGrnNo:        Value(line['source_grn_no'] as String? ?? ''),
              sourceGrnDate:      Value(line['source_grn_date'] as String? ?? ''),
              sourceGrnLineSerial: Value((line['source_grn_line_serial'] as num?)?.toInt()),
              productId:          line['product_id'] as String? ?? '',
              uomId:              Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:            Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:           Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:            Value((line['base_qty']  as num? ?? 0).toDouble()),
              rate:               Value((line['rate'] as num? ?? 0).toDouble()),
              taxGroupId:         Value(line['tax_group_id'] as String? ?? ''),
              grossAmount:        Value((line['gross_amount'] as num? ?? 0).toDouble()),
              taxAmount:          Value((line['tax_amount'] as num? ?? 0).toDouble()),
              finalAmount:        Value((line['final_amount'] as num? ?? 0).toDouble()),
              batchesJson:        Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:        Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:           Value(now),
            ),
          );
    }

    await (_db.delete(_db.purchaseReturnChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.returnNo.equals(effectiveReturnNo))
          ..where((t) => t.returnDate.equals(returnDate)))
        .go();
    for (final c in chargeMaps) {
      await _db.into(_db.purchaseReturnChargeLinesCache).insert(
            PurchaseReturnChargeLinesCacheCompanion.insert(
              clientId:     clientId,
              companyId:    companyId,
              returnNo:     effectiveReturnNo,
              returnDate:   returnDate,
              serialNo:     (c['serial_no'] as num? ?? 0).toInt(),
              chargeId:     c['charge_id'] as String? ?? '',
              chargeName:   Value(c['charge_name'] as String? ?? ''),
              isTaxable:    Value(c['is_taxable'] as bool? ?? false),
              taxId:        Value(c['tax_id'] as String? ?? ''),
              nature:       Value(c['nature'] as String? ?? 'ADD'),
              glAccountId:  Value(c['gl_account_id'] as String? ?? ''),
              amount:       Value((c['amount'] as num? ?? 0).toDouble()),
              taxAmount:    Value((c['tax_amount'] as num? ?? 0).toDouble()),
              sourceGrnNo:  Value(c['source_grn_no'] as String? ?? ''),
              sourceGrnDate: Value(c['source_grn_date'] as String? ?? ''),
              cachedAt:     Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  PurchaseReturnModel _headerFromCache(PurchaseReturnHeaderCacheEntry r) => PurchaseReturnModel(
        id:                 '${r.returnNo}_${r.returnDate}',
        clientId:           r.clientId,
        companyId:          r.companyId,
        locationId:         r.locationId,
        locationName:       r.locationName,
        returnNo:           r.returnNo,
        returnDate:         r.returnDate,
        supplierId:         r.supplierId,
        supplierCode:       r.supplierCode,
        supplierName:       r.supplierName,
        returnCurrencyId:   r.returnCurrencyId,
        returnCurrencyCode: r.returnCurrencyCode,
        rateToBase:         r.rateToBase,
        rateToLocal:        r.rateToLocal,
        taxableAmount:      r.taxableAmount,
        taxAmount:          r.taxAmount,
        chargesAmount:      r.chargesAmount,
        returnTotal:        r.returnTotal,
        reason:             r.reason,
        remarks:            r.remarks,
        status:             r.status,
        approvedBy:         r.approvedBy,
        approvedAt:         r.approvedAt,
        postedVoucherNo:    r.postedVoucherNo,
        postedVoucherDate:  r.postedVoucherDate,
      );

  Map<String, dynamic> _lineToMap(PurchaseReturnLineCacheEntry r) => {
        'serial_no':               r.serialNo,
        'source_grn_no':           r.sourceGrnNo,
        'source_grn_date':         r.sourceGrnDate,
        'source_grn_line_serial':  r.sourceGrnLineSerial,
        'product_id':              r.productId,
        'uom_id':                  r.uomId,
        'uom_conversion_factor':   r.uomConversionFactor,
        'qty_pack':                r.qtyPack,
        'qty_loose':               r.qtyLoose,
        'base_qty':                r.baseQty,
        'rate':                    r.rate,
        'tax_group_id':            r.taxGroupId,
        'gross_amount':            r.grossAmount,
        'tax_amount':              r.taxAmount,
        'final_amount':            r.finalAmount,
      };

  Map<String, dynamic> _chargeToMap(PurchaseReturnChargeLineCacheEntry r) => {
        'serial_no':       r.serialNo,
        'charge_id':       r.chargeId,
        'charge_name':     r.chargeName,
        'is_taxable':      r.isTaxable,
        'tax_id':          r.taxId,
        'nature':          r.nature,
        'gl_account_id':   r.glAccountId,
        'amount':          r.amount,
        'tax_amount':      r.taxAmount,
        'source_grn_no':   r.sourceGrnNo,
        'source_grn_date': r.sourceGrnDate,
      };
}

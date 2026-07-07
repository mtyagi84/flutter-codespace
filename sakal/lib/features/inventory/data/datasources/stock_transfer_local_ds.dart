import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class StockTransferLocalDs {
  final AppDatabase _db;
  StockTransferLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listTransfers({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.stockTransferHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.transferDate), (t) => OrderingTerm.desc(t.transferNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['transfer_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String transferNo,
    String? transferDate,
  }) async {
    final q = _db.select(_db.stockTransferHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.transferNo.equals(transferNo))
      ..where((t) => t.isDeleted.equals(false));
    if (transferDate != null && transferDate.isNotEmpty) {
      q.where((t) => t.transferDate.equals(transferDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.transferDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) async {
    final rows = await (_db.select(_db.stockTransferLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transferNo.equals(transferNo))
          ..where((t) => t.transferDate.equals(transferDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) async {
    final rows = await (_db.select(_db.stockTransferChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transferNo.equals(transferNo))
          ..where((t) => t.transferDate.equals(transferDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_chargeToMap).toList();
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final from = h['from_location'] as Map<String, dynamic>?;
    final to   = h['to_location'] as Map<String, dynamic>?;
    await _db.into(_db.stockTransferHeadersCache).insertOnConflictUpdate(
          StockTransferHeadersCacheCompanion.insert(
            clientId:          h['client_id'] as String,
            companyId:         h['company_id'] as String,
            fromLocationId:    Value(h['from_location_id'] as String? ?? ''),
            fromLocationName:  Value(from?['location_name'] as String? ?? ''),
            toLocationId:      Value(h['to_location_id'] as String? ?? ''),
            toLocationName:    Value(to?['location_name'] as String? ?? ''),
            transferNo:        h['transfer_no'] as String,
            transferDate:      h['transfer_date'] as String,
            againstRequest:    Value(h['against_request'] as bool? ?? false),
            sourceRequestNo:   Value(h['source_request_no'] as String? ?? ''),
            sourceRequestDate: Value(h['source_request_date'] as String? ?? ''),
            remarks:           Value(h['remarks'] as String? ?? ''),
            chargesAmount:     Value((h['charges_amount'] as num? ?? 0).toDouble()),
            status:            Value(h['status'] as String? ?? 'DRAFT'),
            postingMode:       Value(h['posting_mode'] as String? ?? ''),
            cachedAt:          Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String transferNo,
    String transferDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.stockTransferLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transferNo.equals(transferNo))
          ..where((t) => t.transferDate.equals(transferDate)))
        .go();
    for (final line in lines) {
      final product = line['product'] as Map<String, dynamic>?;
      final uom     = line['uom'] as Map<String, dynamic>?;
      await _db.into(_db.stockTransferLinesCache).insert(
            StockTransferLinesCacheCompanion.insert(
              clientId:                clientId,
              companyId:               companyId,
              transferNo:              transferNo,
              transferDate:            transferDate,
              serialNo:                line['serial_no'] as int,
              sourceRequestNo:         Value(line['source_request_no'] as String? ?? ''),
              sourceRequestDate:       Value(line['source_request_date'] as String? ?? ''),
              sourceRequestLineSerial: Value(line['source_request_line_serial'] as int?),
              productId:               line['product_id'] as String,
              productCode:             Value(product?['product_code'] as String? ?? ''),
              productName:             Value(product?['product_name'] as String? ?? ''),
              uomId:                   Value(line['uom_id'] as String? ?? ''),
              uomLabel:                Value(uom?['description'] as String? ?? ''),
              uomConversionFactor:     Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:                 Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:                Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:                 Value((line['base_qty']  as num? ?? 0).toDouble()),
              costPrice:               Value((line['cost_price'] as num? ?? 0).toDouble()),
              salesPrice:              Value((line['sales_price'] as num?)?.toDouble()),
              chargeAmount:            Value((line['charge_amount'] as num? ?? 0).toDouble()),
              remarks:                 Value(line['remarks'] as String? ?? ''),
              cachedAt:                Value(DateTime.now()),
            ),
          );
    }
  }

  Future<void> cacheCharges(
    String clientId,
    String companyId,
    String transferNo,
    String transferDate,
    List<Map<String, dynamic>> charges,
  ) async {
    await (_db.delete(_db.stockTransferChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transferNo.equals(transferNo))
          ..where((t) => t.transferDate.equals(transferDate)))
        .go();
    for (final c in charges) {
      await _db.into(_db.stockTransferChargeLinesCache).insert(
            StockTransferChargeLinesCacheCompanion.insert(
              clientId:        clientId,
              companyId:       companyId,
              transferNo:      transferNo,
              transferDate:    transferDate,
              serialNo:        c['serial_no'] as int,
              chargeId:        c['charge_id'] as String,
              chargeName:      Value(c['charge_name'] as String? ?? ''),
              nature:          Value(c['nature'] as String? ?? 'ADD'),
              glAccountId:     Value(c['gl_account_id'] as String? ?? ''),
              amountOrPercent: Value(c['amount_or_percent'] as String? ?? 'AMOUNT'),
              percent:         Value((c['percent'] as num?)?.toDouble()),
              amount:          Value((c['amount'] as num? ?? 0).toDouble()),
              cachedAt:        Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveTransferNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
    List<Map<String, dynamic>> chargeMaps,
  ) async {
    final now = DateTime.now();
    final clientId     = headerMap['client_id']  as String? ?? '';
    final companyId    = headerMap['company_id'] as String? ?? '';
    final transferDate = headerMap['transfer_date'] as String? ?? '';

    var chargesTotal = 0.0;
    for (final c in chargeMaps) { chargesTotal += (c['amount'] as num? ?? 0).toDouble(); }

    await _db.into(_db.stockTransferHeadersCache).insertOnConflictUpdate(
          StockTransferHeadersCacheCompanion.insert(
            clientId:          clientId,
            companyId:         companyId,
            fromLocationId:    Value(headerMap['from_location_id'] as String? ?? ''),
            toLocationId:      Value(headerMap['to_location_id'] as String? ?? ''),
            transferNo:        effectiveTransferNo,
            transferDate:      transferDate,
            againstRequest:    Value(headerMap['against_request'] as bool? ?? false),
            sourceRequestNo:   Value(headerMap['source_request_no'] as String? ?? ''),
            sourceRequestDate: Value(headerMap['source_request_date'] as String? ?? ''),
            remarks:           Value(headerMap['remarks'] as String? ?? ''),
            chargesAmount:     Value(chargesTotal),
            status:            const Value('DRAFT'),
            isDeleted:         const Value(false),
            cachedAt:          Value(now),
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

    await (_db.delete(_db.stockTransferLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transferNo.equals(effectiveTransferNo))
          ..where((t) => t.transferDate.equals(transferDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.stockTransferLinesCache).insert(
            StockTransferLinesCacheCompanion.insert(
              clientId:                clientId,
              companyId:               companyId,
              transferNo:              effectiveTransferNo,
              transferDate:            transferDate,
              serialNo:                serialNo,
              sourceRequestNo:         Value(line['source_request_no'] as String? ?? ''),
              sourceRequestDate:       Value(line['source_request_date'] as String? ?? ''),
              sourceRequestLineSerial: Value((line['source_request_line_serial'] as num?)?.toInt()),
              productId:               line['product_id'] as String? ?? '',
              uomId:                   Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor:     Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:                 Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:                Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:                 Value((line['base_qty']  as num? ?? 0).toDouble()),
              salesPrice:              Value((line['sales_price'] as num?)?.toDouble()),
              chargeAmount:            Value((line['charge_amount'] as num? ?? 0).toDouble()),
              remarks:                 Value(line['remarks'] as String? ?? ''),
              batchesJson:             Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:             Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:                Value(now),
            ),
          );
    }

    await (_db.delete(_db.stockTransferChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.transferNo.equals(effectiveTransferNo))
          ..where((t) => t.transferDate.equals(transferDate)))
        .go();
    for (final c in chargeMaps) {
      await _db.into(_db.stockTransferChargeLinesCache).insert(
            StockTransferChargeLinesCacheCompanion.insert(
              clientId:        clientId,
              companyId:       companyId,
              transferNo:      effectiveTransferNo,
              transferDate:    transferDate,
              serialNo:        (c['serial_no'] as num? ?? 0).toInt(),
              chargeId:        c['charge_id'] as String? ?? '',
              chargeName:      Value(c['charge_name'] as String? ?? ''),
              nature:          Value(c['nature'] as String? ?? 'ADD'),
              glAccountId:     Value(c['gl_account_id'] as String? ?? ''),
              amountOrPercent: Value(c['amount_or_percent'] as String? ?? 'AMOUNT'),
              percent:         Value((c['percent'] as num?)?.toDouble()),
              amount:          Value((c['amount'] as num? ?? 0).toDouble()),
              cachedAt:        Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(StockTransferHeaderCacheEntry r) => {
        'client_id':           r.clientId,
        'company_id':          r.companyId,
        'from_location_id':    r.fromLocationId,
        'from_location':       {'location_name': r.fromLocationName},
        'to_location_id':      r.toLocationId,
        'to_location':         {'location_name': r.toLocationName},
        'transfer_no':         r.transferNo,
        'transfer_date':       r.transferDate,
        'against_request':     r.againstRequest,
        'source_request_no':   r.sourceRequestNo,
        'source_request_date': r.sourceRequestDate,
        'remarks':             r.remarks,
        'charges_amount':      r.chargesAmount,
        'status':              r.status,
        'posting_mode':        r.postingMode,
      };

  Map<String, dynamic> _lineToMap(StockTransferLineCacheEntry r) => {
        'serial_no':                    r.serialNo,
        'source_request_no':            r.sourceRequestNo,
        'source_request_date':          r.sourceRequestDate,
        'source_request_line_serial':   r.sourceRequestLineSerial,
        'product_id':                   r.productId,
        'product':                      {'product_code': r.productCode, 'product_name': r.productName},
        'uom_id':                       r.uomId,
        'uom':                          {'description': r.uomLabel},
        'uom_conversion_factor':        r.uomConversionFactor,
        'qty_pack':                     r.qtyPack,
        'qty_loose':                    r.qtyLoose,
        'base_qty':                     r.baseQty,
        'cost_price':                   r.costPrice,
        'sales_price':                  r.salesPrice,
        'charge_amount':                r.chargeAmount,
        'remarks':                      r.remarks,
      };

  Map<String, dynamic> _chargeToMap(StockTransferChargeLineCacheEntry r) => {
        'serial_no':         r.serialNo,
        'charge_id':         r.chargeId,
        'charge_name':       r.chargeName,
        'nature':            r.nature,
        'gl_account_id':     r.glAccountId,
        'amount_or_percent': r.amountOrPercent,
        'percent':           r.percent,
        'amount':            r.amount,
      };
}

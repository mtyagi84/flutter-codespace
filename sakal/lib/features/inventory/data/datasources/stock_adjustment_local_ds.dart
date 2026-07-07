import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class StockAdjustmentLocalDs {
  final AppDatabase _db;
  StockAdjustmentLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listAdjustments({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.stockAdjustmentHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.adjustmentDate), (t) => OrderingTerm.desc(t.adjustmentNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['adjustment_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    String? adjustmentDate,
  }) async {
    final q = _db.select(_db.stockAdjustmentHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.adjustmentNo.equals(adjustmentNo))
      ..where((t) => t.isDeleted.equals(false));
    if (adjustmentDate != null && adjustmentDate.isNotEmpty) {
      q.where((t) => t.adjustmentDate.equals(adjustmentDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.adjustmentDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
  }) async {
    final rows = await (_db.select(_db.stockAdjustmentLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.adjustmentNo.equals(adjustmentNo))
          ..where((t) => t.adjustmentDate.equals(adjustmentDate))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  }) async {
    final row = await (_db.select(_db.stockAdjustmentLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.adjustmentNo.equals(adjustmentNo))
          ..where((t) => t.adjustmentDate.equals(adjustmentDate))
          ..where((t) => t.serialNo.equals(lineSerial)))
        .getSingleOrNull();
    if (row == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(row.batchesJson) as List);
  }

  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  }) async {
    final row = await (_db.select(_db.stockAdjustmentLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.adjustmentNo.equals(adjustmentNo))
          ..where((t) => t.adjustmentDate.equals(adjustmentDate))
          ..where((t) => t.serialNo.equals(lineSerial)))
        .getSingleOrNull();
    if (row == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(row.serialsJson) as List);
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location = h['location'] as Map<String, dynamic>?;
    final reason   = h['reason'] as Map<String, dynamic>?;
    await _db.into(_db.stockAdjustmentHeadersCache).insertOnConflictUpdate(
          StockAdjustmentHeadersCacheCompanion.insert(
            clientId:     h['client_id'] as String,
            companyId:    h['company_id'] as String,
            locationId:   Value(h['location_id'] as String? ?? ''),
            locationName: Value(location?['location_name'] as String? ?? ''),
            adjustmentNo: h['adjustment_no'] as String,
            adjustmentDate: h['adjustment_date'] as String,
            reasonId:     Value(h['reason_id'] as String? ?? ''),
            reasonLabel:  Value(reason?['description'] as String? ?? ''),
            remarks:      Value(h['remarks'] as String? ?? ''),
            status:       Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:     Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String adjustmentNo,
    String adjustmentDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.stockAdjustmentLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.adjustmentNo.equals(adjustmentNo))
          ..where((t) => t.adjustmentDate.equals(adjustmentDate)))
        .go();
    for (final line in lines) {
      final product = line['product'] as Map<String, dynamic>?;
      final uom     = line['uom'] as Map<String, dynamic>?;
      final reason  = line['reason'] as Map<String, dynamic>?;
      await _db.into(_db.stockAdjustmentLinesCache).insert(
            StockAdjustmentLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              adjustmentNo:        adjustmentNo,
              adjustmentDate:      adjustmentDate,
              serialNo:            (line['serial_no'] as num).toInt(),
              productId:           line['product_id'] as String,
              productCode:         Value(product?['product_code'] as String? ?? ''),
              productName:         Value(product?['product_name'] as String? ?? ''),
              trackingType:        Value(product?['tracking_type'] as String? ?? 'NONE'),
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomLabel:            Value(uom?['description'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              adjustFlag:          line['adjust_flag'] as String,
              systemQty:           Value((line['system_qty'] as num?)?.toDouble()),
              unitCost:            Value((line['unit_cost'] as num?)?.toDouble()),
              unitCostSpecific:    Value((line['unit_cost_specific'] as num?)?.toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              reasonId:            Value(line['reason_id'] as String? ?? ''),
              reasonLabel:         Value(reason?['description'] as String? ?? ''),
              remarks:             Value(line['remarks'] as String? ?? ''),
              batchesJson:         const Value('[]'),
              serialsJson:         const Value('[]'),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveAdjustmentNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
  ) async {
    final now = DateTime.now();
    final clientId       = headerMap['client_id']  as String? ?? '';
    final companyId      = headerMap['company_id'] as String? ?? '';
    final adjustmentDate = headerMap['adjustment_date'] as String? ?? '';

    await _db.into(_db.stockAdjustmentHeadersCache).insertOnConflictUpdate(
          StockAdjustmentHeadersCacheCompanion.insert(
            clientId:       clientId,
            companyId:      companyId,
            locationId:     Value(headerMap['location_id'] as String? ?? ''),
            adjustmentNo:   effectiveAdjustmentNo,
            adjustmentDate: adjustmentDate,
            reasonId:       Value(headerMap['reason_id'] as String? ?? ''),
            remarks:        Value(headerMap['remarks'] as String? ?? ''),
            status:         const Value('DRAFT'),
            isDeleted:      const Value(false),
            cachedAt:       Value(now),
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

    await (_db.delete(_db.stockAdjustmentLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.adjustmentNo.equals(effectiveAdjustmentNo))
          ..where((t) => t.adjustmentDate.equals(adjustmentDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.stockAdjustmentLinesCache).insert(
            StockAdjustmentLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              adjustmentNo:        effectiveAdjustmentNo,
              adjustmentDate:      adjustmentDate,
              serialNo:            serialNo,
              productId:           line['product_id'] as String? ?? '',
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              adjustFlag:          line['adjust_flag'] as String? ?? '+',
              systemQty:           Value((line['system_qty'] as num?)?.toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              reasonId:            Value(line['reason_id'] as String? ?? ''),
              remarks:             Value(line['remarks'] as String? ?? ''),
              batchesJson:         Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:         Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(StockAdjustmentHeaderCacheEntry r) => {
        'client_id':       r.clientId,
        'company_id':      r.companyId,
        'location_id':     r.locationId,
        'location':        {'location_name': r.locationName},
        'adjustment_no':   r.adjustmentNo,
        'adjustment_date': r.adjustmentDate,
        'reason_id':       r.reasonId,
        'reason':          {'description': r.reasonLabel},
        'remarks':         r.remarks,
        'status':          r.status,
      };

  Map<String, dynamic> _lineToMap(StockAdjustmentLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName, 'tracking_type': r.trackingType},
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'qty_pack':              r.qtyPack,
        'qty_loose':             r.qtyLoose,
        'base_qty':              r.baseQty,
        'adjust_flag':           r.adjustFlag,
        'system_qty':            r.systemQty,
        'unit_cost':             r.unitCost,
        'unit_cost_specific':    r.unitCostSpecific,
        'barcode':               r.barcode,
        'reason_id':             r.reasonId,
        'reason':                {'description': r.reasonLabel},
        'remarks':               r.remarks,
      };
}

import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class StockCountLocalDs {
  final AppDatabase _db;
  StockCountLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listStockCounts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.stockCountHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.countDate), (t) => OrderingTerm.desc(t.countNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['count_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String countNo,
    String? countDate,
  }) async {
    final q = _db.select(_db.stockCountHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.countNo.equals(countNo))
      ..where((t) => t.isDeleted.equals(false));
    if (countDate != null && countDate.isNotEmpty) {
      q.where((t) => t.countDate.equals(countDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.countDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
  }) async {
    final rows = await (_db.select(_db.stockCountLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.countNo.equals(countNo))
          ..where((t) => t.countDate.equals(countDate))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  }) async {
    final row = await (_db.select(_db.stockCountLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.countNo.equals(countNo))
          ..where((t) => t.countDate.equals(countDate))
          ..where((t) => t.serialNo.equals(lineSerial)))
        .getSingleOrNull();
    if (row == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(row.batchesJson) as List);
  }

  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String countNo,
    required String countDate,
    required int    lineSerial,
  }) async {
    final row = await (_db.select(_db.stockCountLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.countNo.equals(countNo))
          ..where((t) => t.countDate.equals(countDate))
          ..where((t) => t.serialNo.equals(lineSerial)))
        .getSingleOrNull();
    if (row == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(row.serialsJson) as List);
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location = h['location'] as Map<String, dynamic>?;
    await _db.into(_db.stockCountHeadersCache).insertOnConflictUpdate(
          StockCountHeadersCacheCompanion.insert(
            clientId:         h['client_id'] as String,
            companyId:        h['company_id'] as String,
            locationId:       Value(h['location_id'] as String? ?? ''),
            locationName:     Value(location?['location_name'] as String? ?? ''),
            countNo:          h['count_no'] as String,
            countDate:        h['count_date'] as String,
            categoryFilterId: Value(h['category_filter_id'] as String? ?? ''),
            natureFilter:     Value(h['nature_filter'] as String? ?? ''),
            remarks:          Value(h['remarks'] as String? ?? ''),
            status:           Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:         Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String countNo,
    String countDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.stockCountLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.countNo.equals(countNo))
          ..where((t) => t.countDate.equals(countDate)))
        .go();
    for (final line in lines) {
      final product = line['product'] as Map<String, dynamic>?;
      final uom     = line['uom'] as Map<String, dynamic>?;
      await _db.into(_db.stockCountLinesCache).insert(
            StockCountLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              countNo:             countNo,
              countDate:           countDate,
              serialNo:            (line['serial_no'] as num).toInt(),
              productId:           line['product_id'] as String,
              productCode:         Value(product?['product_code'] as String? ?? ''),
              productName:         Value(product?['product_name'] as String? ?? ''),
              trackingType:        Value(product?['tracking_type'] as String? ?? 'NONE'),
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomLabel:            Value(uom?['description'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              productBarcode:      Value(product?['barcode'] as String? ?? ''),
              productPartNumber:   Value(product?['part_number'] as String? ?? ''),
              isCounted:           Value(line['is_counted'] as bool? ?? false),
              countedQtyPack:      Value((line['counted_qty_pack'] as num?)?.toDouble()),
              countedQtyLoose:     Value((line['counted_qty_loose'] as num?)?.toDouble()),
              countedBaseQty:      Value((line['counted_base_qty'] as num?)?.toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
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
    String effectiveCountNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
  ) async {
    final now = DateTime.now();
    final clientId  = headerMap['client_id']  as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final countDate = headerMap['count_date'] as String? ?? '';

    await _db.into(_db.stockCountHeadersCache).insertOnConflictUpdate(
          StockCountHeadersCacheCompanion.insert(
            clientId:         clientId,
            companyId:        companyId,
            locationId:       Value(headerMap['location_id'] as String? ?? ''),
            countNo:          effectiveCountNo,
            countDate:        countDate,
            categoryFilterId: Value(headerMap['category_filter_id'] as String? ?? ''),
            natureFilter:     Value(headerMap['nature_filter'] as String? ?? ''),
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

    await (_db.delete(_db.stockCountLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.countNo.equals(effectiveCountNo))
          ..where((t) => t.countDate.equals(countDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.stockCountLinesCache).insert(
            StockCountLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              countNo:             effectiveCountNo,
              countDate:           countDate,
              serialNo:            serialNo,
              productId:           line['product_id'] as String? ?? '',
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              isCounted:           Value(line['is_counted'] as bool? ?? false),
              countedQtyPack:      Value((line['counted_qty_pack'] as num?)?.toDouble()),
              countedQtyLoose:     Value((line['counted_qty_loose'] as num?)?.toDouble()),
              countedBaseQty:      Value((line['counted_base_qty'] as num?)?.toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              remarks:             Value(line['remarks'] as String? ?? ''),
              batchesJson:         Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:         Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(StockCountHeaderCacheEntry r) => {
        'client_id':          r.clientId,
        'company_id':         r.companyId,
        'location_id':        r.locationId,
        'location':           {'location_name': r.locationName},
        'count_no':           r.countNo,
        'count_date':         r.countDate,
        'category_filter_id': r.categoryFilterId,
        'nature_filter':      r.natureFilter,
        'remarks':            r.remarks,
        'status':             r.status,
      };

  Map<String, dynamic> _lineToMap(StockCountLineCacheEntry r) => {
        'serial_no':              r.serialNo,
        'product_id':             r.productId,
        'product':                {'product_code': r.productCode, 'product_name': r.productName, 'tracking_type': r.trackingType,
                                    'barcode': r.productBarcode, 'part_number': r.productPartNumber},
        'uom_id':                 r.uomId,
        'uom':                    {'description': r.uomLabel},
        'uom_conversion_factor':  r.uomConversionFactor,
        'is_counted':             r.isCounted,
        'counted_qty_pack':       r.countedQtyPack,
        'counted_qty_loose':      r.countedQtyLoose,
        'counted_base_qty':       r.countedBaseQty,
        'barcode':                r.barcode,
        'remarks':                r.remarks,
      };
}

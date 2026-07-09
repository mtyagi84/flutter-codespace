import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class OpeningStockLocalDs {
  final AppDatabase _db;
  OpeningStockLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listOpeningStocks({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.openingStockHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.openingDate), (t) => OrderingTerm.desc(t.openingNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['opening_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String openingNo,
    String? openingDate,
  }) async {
    final q = _db.select(_db.openingStockHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.openingNo.equals(openingNo))
      ..where((t) => t.isDeleted.equals(false));
    if (openingDate != null && openingDate.isNotEmpty) {
      q.where((t) => t.openingDate.equals(openingDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.openingDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String openingNo,
    required String openingDate,
  }) async {
    final rows = await (_db.select(_db.openingStockLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.openingNo.equals(openingNo))
          ..where((t) => t.openingDate.equals(openingDate))
          ..orderBy([(t) => OrderingTerm.asc(t.lineNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location = h['location'] as Map<String, dynamic>?;
    await _db.into(_db.openingStockHeadersCache).insertOnConflictUpdate(
          OpeningStockHeadersCacheCompanion.insert(
            clientId:     h['client_id'] as String,
            companyId:    h['company_id'] as String,
            locationId:   Value(h['location_id'] as String? ?? ''),
            locationName: Value(location?['location_name'] as String? ?? ''),
            openingNo:    h['opening_no'] as String,
            openingDate:  h['opening_date'] as String,
            remarks:      Value(h['remarks'] as String? ?? ''),
            status:       Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:     Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String openingNo,
    String openingDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.openingStockLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.openingNo.equals(openingNo))
          ..where((t) => t.openingDate.equals(openingDate)))
        .go();
    for (final line in lines) {
      final product = line['product'] as Map<String, dynamic>?;
      final uom     = line['uom'] as Map<String, dynamic>?;
      await _db.into(_db.openingStockLinesCache).insert(
            OpeningStockLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              openingNo:           openingNo,
              openingDate:         openingDate,
              lineNo:              (line['line_no'] as num).toInt(),
              productId:           line['product_id'] as String,
              productCode:         Value(product?['product_code'] as String? ?? ''),
              productName:         Value(product?['product_name'] as String? ?? ''),
              trackingType:        Value(product?['tracking_type'] as String? ?? 'NONE'),
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomLabel:            Value(uom?['description'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              packQty:             Value((line['pack_qty']  as num? ?? 0).toDouble()),
              looseQty:            Value((line['loose_qty'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              batchNo:             Value(line['batch_no'] as String? ?? ''),
              expiryDate:          Value(line['expiry_date'] as String? ?? ''),
              manufacturingDate:   Value(line['manufacturing_date'] as String? ?? ''),
              serialNo:            Value(line['serial_no'] as String? ?? ''),
              unitCost:            Value((line['unit_cost'] as num? ?? 0).toDouble()),
              unitCostSpecific:    Value((line['unit_cost_specific'] as num?)?.toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveOpeningNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now = DateTime.now();
    final clientId    = headerMap['client_id']  as String? ?? '';
    final companyId   = headerMap['company_id'] as String? ?? '';
    final openingDate = headerMap['opening_date'] as String? ?? '';

    await _db.into(_db.openingStockHeadersCache).insertOnConflictUpdate(
          OpeningStockHeadersCacheCompanion.insert(
            clientId:    clientId,
            companyId:   companyId,
            locationId:  Value(headerMap['location_id'] as String? ?? ''),
            openingNo:   effectiveOpeningNo,
            openingDate: openingDate,
            remarks:     Value(headerMap['remarks'] as String? ?? ''),
            status:      const Value('DRAFT'),
            isDeleted:   const Value(false),
            cachedAt:    Value(now),
          ),
        );

    await (_db.delete(_db.openingStockLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.openingNo.equals(effectiveOpeningNo))
          ..where((t) => t.openingDate.equals(openingDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.openingStockLinesCache).insert(
            OpeningStockLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              openingNo:           effectiveOpeningNo,
              openingDate:         openingDate,
              lineNo:              (line['line_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              packQty:             Value((line['pack_qty']  as num? ?? 0).toDouble()),
              looseQty:            Value((line['loose_qty'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              batchNo:             Value(line['batch_no'] as String? ?? ''),
              expiryDate:          Value(line['expiry_date'] as String? ?? ''),
              manufacturingDate:   Value(line['manufacturing_date'] as String? ?? ''),
              serialNo:            Value(line['serial_no'] as String? ?? ''),
              unitCost:            Value((line['unit_cost'] as num? ?? 0).toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(OpeningStockHeaderCacheEntry r) => {
        'client_id':     r.clientId,
        'company_id':    r.companyId,
        'location_id':   r.locationId,
        'location':      {'location_name': r.locationName},
        'opening_no':    r.openingNo,
        'opening_date':  r.openingDate,
        'remarks':       r.remarks,
        'status':        r.status,
      };

  Map<String, dynamic> _lineToMap(OpeningStockLineCacheEntry r) => {
        'line_no':               r.lineNo,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName, 'tracking_type': r.trackingType},
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'pack_qty':              r.packQty,
        'loose_qty':             r.looseQty,
        'base_qty':              r.baseQty,
        'batch_no':              r.batchNo,
        'expiry_date':           r.expiryDate,
        'manufacturing_date':    r.manufacturingDate,
        'serial_no':             r.serialNo,
        'unit_cost':             r.unitCost,
        'unit_cost_specific':    r.unitCostSpecific,
        'barcode':               r.barcode,
        'remarks':               r.remarks,
      };
}

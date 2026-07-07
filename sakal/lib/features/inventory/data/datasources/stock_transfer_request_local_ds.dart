import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class StockTransferRequestLocalDs {
  final AppDatabase _db;
  StockTransferRequestLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listRequests({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.stockTransferRequestHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.requestDate), (t) => OrderingTerm.desc(t.requestNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['request_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requestNo,
    String? requestDate,
  }) async {
    final q = _db.select(_db.stockTransferRequestHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.requestNo.equals(requestNo))
      ..where((t) => t.isDeleted.equals(false));
    if (requestDate != null && requestDate.isNotEmpty) {
      q.where((t) => t.requestDate.equals(requestDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.requestDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  }) async {
    final rows = await (_db.select(_db.stockTransferRequestLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.requestNo.equals(requestNo))
          ..where((t) => t.requestDate.equals(requestDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final from = h['from_location'] as Map<String, dynamic>?;
    final to   = h['to_location'] as Map<String, dynamic>?;
    await _db.into(_db.stockTransferRequestHeadersCache).insertOnConflictUpdate(
          StockTransferRequestHeadersCacheCompanion.insert(
            clientId:        h['client_id'] as String,
            companyId:       h['company_id'] as String,
            fromLocationId:  Value(h['from_location_id'] as String? ?? ''),
            fromLocationName: Value(from?['location_name'] as String? ?? ''),
            toLocationId:    Value(h['to_location_id'] as String? ?? ''),
            toLocationName:  Value(to?['location_name'] as String? ?? ''),
            requestNo:       h['request_no'] as String,
            requestDate:     h['request_date'] as String,
            remarks:         Value(h['remarks'] as String? ?? ''),
            status:          Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:        Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String requestNo,
    String requestDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.stockTransferRequestLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.requestNo.equals(requestNo))
          ..where((t) => t.requestDate.equals(requestDate)))
        .go();
    for (final line in lines) {
      final product = line['product'] as Map<String, dynamic>?;
      final uom     = line['uom'] as Map<String, dynamic>?;
      await _db.into(_db.stockTransferRequestLinesCache).insert(
            StockTransferRequestLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              requestNo:           requestNo,
              requestDate:         requestDate,
              serialNo:            line['serial_no'] as int,
              productId:           line['product_id'] as String,
              productCode:         Value(product?['product_code'] as String? ?? ''),
              productName:         Value(product?['product_name'] as String? ?? ''),
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomLabel:            Value(uom?['description'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              transferredQty:      Value((line['transferred_qty'] as num? ?? 0).toDouble()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveRequestNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now = DateTime.now();
    final clientId    = headerMap['client_id']  as String? ?? '';
    final companyId   = headerMap['company_id'] as String? ?? '';
    final requestDate = headerMap['request_date'] as String? ?? '';

    await _db.into(_db.stockTransferRequestHeadersCache).insertOnConflictUpdate(
          StockTransferRequestHeadersCacheCompanion.insert(
            clientId:       clientId,
            companyId:      companyId,
            fromLocationId: Value(headerMap['from_location_id'] as String? ?? ''),
            toLocationId:   Value(headerMap['to_location_id'] as String? ?? ''),
            requestNo:      effectiveRequestNo,
            requestDate:    requestDate,
            remarks:        Value(headerMap['remarks'] as String? ?? ''),
            status:         const Value('DRAFT'),
            isDeleted:      const Value(false),
            cachedAt:       Value(now),
          ),
        );

    await (_db.delete(_db.stockTransferRequestLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.requestNo.equals(effectiveRequestNo))
          ..where((t) => t.requestDate.equals(requestDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.stockTransferRequestLinesCache).insert(
            StockTransferRequestLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              requestNo:           effectiveRequestNo,
              requestDate:         requestDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(StockTransferRequestHeaderCacheEntry r) => {
        'client_id':        r.clientId,
        'company_id':       r.companyId,
        'from_location_id': r.fromLocationId,
        'from_location':    {'location_name': r.fromLocationName},
        'to_location_id':   r.toLocationId,
        'to_location':      {'location_name': r.toLocationName},
        'request_no':       r.requestNo,
        'request_date':     r.requestDate,
        'remarks':          r.remarks,
        'status':           r.status,
      };

  Map<String, dynamic> _lineToMap(StockTransferRequestLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName},
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'qty_pack':              r.qtyPack,
        'qty_loose':             r.qtyLoose,
        'base_qty':              r.baseQty,
        'transferred_qty':       r.transferredQty,
        'remarks':               r.remarks,
      };
}

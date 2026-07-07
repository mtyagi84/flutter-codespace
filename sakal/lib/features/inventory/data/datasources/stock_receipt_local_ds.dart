import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class StockReceiptLocalDs {
  final AppDatabase _db;
  StockReceiptLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listReceipts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.stockReceiptHeadersCache)
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
    String? receiptDate,
  }) async {
    final q = _db.select(_db.stockReceiptHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.receiptNo.equals(receiptNo))
      ..where((t) => t.isDeleted.equals(false));
    if (receiptDate != null && receiptDate.isNotEmpty) {
      q.where((t) => t.receiptDate.equals(receiptDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.receiptDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  }) async {
    final rows = await (_db.select(_db.stockReceiptLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.receiptNo.equals(receiptNo))
          ..where((t) => t.receiptDate.equals(receiptDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final from = h['from_location'] as Map<String, dynamic>?;
    final to   = h['to_location'] as Map<String, dynamic>?;
    await _db.into(_db.stockReceiptHeadersCache).insertOnConflictUpdate(
          StockReceiptHeadersCacheCompanion.insert(
            clientId:           h['client_id'] as String,
            companyId:          h['company_id'] as String,
            fromLocationId:     Value(h['from_location_id'] as String? ?? ''),
            fromLocationName:   Value(from?['location_name'] as String? ?? ''),
            toLocationId:       Value(h['to_location_id'] as String? ?? ''),
            toLocationName:     Value(to?['location_name'] as String? ?? ''),
            sourceTransferNo:   Value(h['source_transfer_no'] as String? ?? ''),
            sourceTransferDate: Value(h['source_transfer_date'] as String? ?? ''),
            receiptNo:          h['receipt_no'] as String,
            receiptDate:        h['receipt_date'] as String,
            remarks:            Value(h['remarks'] as String? ?? ''),
            status:             Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:           Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String receiptNo,
    String receiptDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.stockReceiptLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.receiptNo.equals(receiptNo))
          ..where((t) => t.receiptDate.equals(receiptDate)))
        .go();
    for (final line in lines) {
      final product = line['product'] as Map<String, dynamic>?;
      final uom     = line['uom'] as Map<String, dynamic>?;
      await _db.into(_db.stockReceiptLinesCache).insert(
            StockReceiptLinesCacheCompanion.insert(
              clientId:                 clientId,
              companyId:                companyId,
              receiptNo:                receiptNo,
              receiptDate:              receiptDate,
              serialNo:                 line['serial_no'] as int,
              sourceTransferLineSerial: Value(line['source_transfer_line_serial'] as int?),
              productId:                line['product_id'] as String,
              productCode:              Value(product?['product_code'] as String? ?? ''),
              productName:              Value(product?['product_name'] as String? ?? ''),
              uomId:                    Value(line['uom_id'] as String? ?? ''),
              uomLabel:                 Value(uom?['description'] as String? ?? ''),
              uomConversionFactor:      Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              receivedQtyPack:          Value((line['received_qty_pack']  as num? ?? 0).toDouble()),
              receivedQtyLoose:         Value((line['received_qty_loose'] as num? ?? 0).toDouble()),
              receivedBaseQty:          Value((line['received_base_qty']  as num? ?? 0).toDouble()),
              remarks:                  Value(line['remarks'] as String? ?? ''),
              cachedAt:                 Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveReceiptNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
  ) async {
    final now = DateTime.now();
    final clientId    = headerMap['client_id']  as String? ?? '';
    final companyId   = headerMap['company_id'] as String? ?? '';
    final receiptDate = headerMap['receipt_date'] as String? ?? '';

    await _db.into(_db.stockReceiptHeadersCache).insertOnConflictUpdate(
          StockReceiptHeadersCacheCompanion.insert(
            clientId:           clientId,
            companyId:          companyId,
            sourceTransferNo:   Value(headerMap['source_transfer_no'] as String? ?? ''),
            sourceTransferDate: Value(headerMap['source_transfer_date'] as String? ?? ''),
            receiptNo:          effectiveReceiptNo,
            receiptDate:        receiptDate,
            remarks:            Value(headerMap['remarks'] as String? ?? ''),
            status:             const Value('DRAFT'),
            isDeleted:          const Value(false),
            cachedAt:           Value(now),
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

    await (_db.delete(_db.stockReceiptLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.receiptNo.equals(effectiveReceiptNo))
          ..where((t) => t.receiptDate.equals(receiptDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.stockReceiptLinesCache).insert(
            StockReceiptLinesCacheCompanion.insert(
              clientId:                 clientId,
              companyId:                companyId,
              receiptNo:                effectiveReceiptNo,
              receiptDate:              receiptDate,
              serialNo:                 serialNo,
              sourceTransferLineSerial: Value((line['source_transfer_line_serial'] as num?)?.toInt()),
              productId:                line['product_id'] as String? ?? '',
              uomId:                    Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor:      Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              receivedQtyPack:          Value((line['received_qty_pack']  as num? ?? 0).toDouble()),
              receivedQtyLoose:         Value((line['received_qty_loose'] as num? ?? 0).toDouble()),
              receivedBaseQty:          Value((line['received_base_qty']  as num? ?? 0).toDouble()),
              remarks:                  Value(line['remarks'] as String? ?? ''),
              batchesJson:              Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:              Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:                 Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(StockReceiptHeaderCacheEntry r) => {
        'client_id':            r.clientId,
        'company_id':           r.companyId,
        'from_location_id':     r.fromLocationId,
        'from_location':        {'location_name': r.fromLocationName},
        'to_location_id':       r.toLocationId,
        'to_location':          {'location_name': r.toLocationName},
        'source_transfer_no':   r.sourceTransferNo,
        'source_transfer_date': r.sourceTransferDate,
        'receipt_no':           r.receiptNo,
        'receipt_date':         r.receiptDate,
        'remarks':              r.remarks,
        'status':               r.status,
      };

  Map<String, dynamic> _lineToMap(StockReceiptLineCacheEntry r) => {
        'serial_no':                    r.serialNo,
        'source_transfer_line_serial':  r.sourceTransferLineSerial,
        'product_id':                   r.productId,
        'product':                      {'product_code': r.productCode, 'product_name': r.productName},
        'uom_id':                       r.uomId,
        'uom':                          {'description': r.uomLabel},
        'uom_conversion_factor':        r.uomConversionFactor,
        'received_qty_pack':            r.receivedQtyPack,
        'received_qty_loose':           r.receivedQtyLoose,
        'received_base_qty':            r.receivedBaseQty,
        'remarks':                      r.remarks,
      };
}

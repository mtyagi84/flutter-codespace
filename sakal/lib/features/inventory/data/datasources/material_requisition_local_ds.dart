import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class MaterialRequisitionLocalDs {
  final AppDatabase _db;
  MaterialRequisitionLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listRequisitions({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.materialRequisitionHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.requisitionDate), (t) => OrderingTerm.desc(t.requisitionNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) =>
          (r['requisition_no'] as String).toLowerCase().contains(s) ||
          (r['requested_by'] as String? ?? '').toLowerCase().contains(s) ||
          (r['reason'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    String? requisitionDate,
  }) async {
    final q = _db.select(_db.materialRequisitionHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.requisitionNo.equals(requisitionNo))
      ..where((t) => t.isDeleted.equals(false));
    if (requisitionDate != null && requisitionDate.isNotEmpty) {
      q.where((t) => t.requisitionDate.equals(requisitionDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.requisitionDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  }) async {
    final rows = await (_db.select(_db.materialRequisitionLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.requisitionNo.equals(requisitionNo))
          ..where((t) => t.requisitionDate.equals(requisitionDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from Maps (after remote fetch, or the offline-save path) ──────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location = h['location'] as Map<String, dynamic>?;
    await _db.into(_db.materialRequisitionHeadersCache).insertOnConflictUpdate(
          MaterialRequisitionHeadersCacheCompanion.insert(
            clientId:        h['client_id'] as String,
            companyId:       h['company_id'] as String,
            locationId:      Value(h['location_id'] as String? ?? ''),
            locationName:    Value(location?['location_name'] as String? ?? ''),
            requisitionNo:   h['requisition_no'] as String,
            requisitionDate: h['requisition_date'] as String,
            requestedBy:     Value(h['requested_by'] as String? ?? ''),
            reason:          Value(h['reason'] as String? ?? ''),
            remarks:         Value(h['remarks'] as String? ?? ''),
            status:          Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:        Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String requisitionNo,
    String requisitionDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.materialRequisitionLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.requisitionNo.equals(requisitionNo))
          ..where((t) => t.requisitionDate.equals(requisitionDate)))
        .go();
    for (final line in lines) {
      final product    = line['product'] as Map<String, dynamic>?;
      final uom         = line['uom'] as Map<String, dynamic>?;
      final department  = line['department'] as Map<String, dynamic>?;
      final area        = line['area'] as Map<String, dynamic>?;
      await _db.into(_db.materialRequisitionLinesCache).insert(
            MaterialRequisitionLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              requisitionNo:       requisitionNo,
              requisitionDate:     requisitionDate,
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
              departmentId:        Value(line['department_id'] as String? ?? ''),
              departmentLabel:     Value(department?['description'] as String? ?? ''),
              consumptionAreaId:   Value(line['consumption_area_id'] as String? ?? ''),
              areaLabel:           Value(area?['description'] as String? ?? ''),
              issuedQty:           Value((line['issued_qty'] as num? ?? 0).toDouble()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveRequisitionNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now = DateTime.now();
    final clientId        = headerMap['client_id']  as String? ?? '';
    final companyId       = headerMap['company_id'] as String? ?? '';
    final requisitionDate = headerMap['requisition_date'] as String? ?? '';

    await _db.into(_db.materialRequisitionHeadersCache).insertOnConflictUpdate(
          MaterialRequisitionHeadersCacheCompanion.insert(
            clientId:        clientId,
            companyId:       companyId,
            locationId:      Value(headerMap['location_id'] as String? ?? ''),
            requisitionNo:   effectiveRequisitionNo,
            requisitionDate: requisitionDate,
            requestedBy:     Value(headerMap['requested_by'] as String? ?? ''),
            reason:          Value(headerMap['reason'] as String? ?? ''),
            remarks:         Value(headerMap['remarks'] as String? ?? ''),
            status:          const Value('DRAFT'),
            isDeleted:       const Value(false),
            cachedAt:        Value(now),
          ),
        );

    await (_db.delete(_db.materialRequisitionLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.requisitionNo.equals(effectiveRequisitionNo))
          ..where((t) => t.requisitionDate.equals(requisitionDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.materialRequisitionLinesCache).insert(
            MaterialRequisitionLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              requisitionNo:       effectiveRequisitionNo,
              requisitionDate:     requisitionDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              departmentId:        Value(line['department_id'] as String? ?? ''),
              consumptionAreaId:   Value(line['consumption_area_id'] as String? ?? ''),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(MaterialRequisitionHeaderCacheEntry r) => {
        'client_id':         r.clientId,
        'company_id':        r.companyId,
        'location_id':       r.locationId,
        'location':          {'location_name': r.locationName},
        'requisition_no':    r.requisitionNo,
        'requisition_date':  r.requisitionDate,
        'requested_by':      r.requestedBy,
        'reason':            r.reason,
        'remarks':           r.remarks,
        'status':            r.status,
      };

  Map<String, dynamic> _lineToMap(MaterialRequisitionLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName},
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'qty_pack':              r.qtyPack,
        'qty_loose':             r.qtyLoose,
        'base_qty':              r.baseQty,
        'department_id':         r.departmentId,
        'department':            {'description': r.departmentLabel},
        'consumption_area_id':   r.consumptionAreaId,
        'area':                  {'description': r.areaLabel},
        'issued_qty':            r.issuedQty,
        'remarks':               r.remarks,
      };
}

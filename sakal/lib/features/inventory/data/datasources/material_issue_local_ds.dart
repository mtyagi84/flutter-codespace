import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class MaterialIssueLocalDs {
  final AppDatabase _db;
  MaterialIssueLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listIssues({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.materialIssueHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.issueDate), (t) => OrderingTerm.desc(t.issueNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['issue_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String issueNo,
    String? issueDate,
  }) async {
    final q = _db.select(_db.materialIssueHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.issueNo.equals(issueNo))
      ..where((t) => t.isDeleted.equals(false));
    if (issueDate != null && issueDate.isNotEmpty) {
      q.where((t) => t.issueDate.equals(issueDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.issueDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  // ── Write — from Maps (after remote fetch) ─────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location = h['location'] as Map<String, dynamic>?;
    await _db.into(_db.materialIssueHeadersCache).insertOnConflictUpdate(
          MaterialIssueHeadersCacheCompanion.insert(
            clientId:     h['client_id'] as String,
            companyId:    h['company_id'] as String,
            locationId:   Value(h['location_id'] as String? ?? ''),
            locationName: Value(location?['location_name'] as String? ?? ''),
            issueNo:      h['issue_no'] as String,
            issueDate:    h['issue_date'] as String,
            remarks:      Value(h['remarks'] as String? ?? ''),
            status:       Value(h['status'] as String? ?? 'DRAFT'),
            cachedAt:     Value(DateTime.now()),
          ),
        );
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveIssueNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
  ) async {
    final now = DateTime.now();
    final clientId  = headerMap['client_id']  as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final issueDate = headerMap['issue_date'] as String? ?? '';

    await _db.into(_db.materialIssueHeadersCache).insertOnConflictUpdate(
          MaterialIssueHeadersCacheCompanion.insert(
            clientId:   clientId,
            companyId:  companyId,
            locationId: Value(headerMap['location_id'] as String? ?? ''),
            issueNo:    effectiveIssueNo,
            issueDate:  issueDate,
            remarks:    Value(headerMap['remarks'] as String? ?? ''),
            status:     const Value('DRAFT'),
            isDeleted:  const Value(false),
            cachedAt:   Value(now),
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

    await (_db.delete(_db.materialIssueLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.issueNo.equals(effectiveIssueNo))
          ..where((t) => t.issueDate.equals(issueDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.materialIssueLinesCache).insert(
            MaterialIssueLinesCacheCompanion.insert(
              clientId:                    clientId,
              companyId:                   companyId,
              issueNo:                     effectiveIssueNo,
              issueDate:                   issueDate,
              serialNo:                    serialNo,
              sourceRequisitionNo:         Value(line['source_requisition_no'] as String? ?? ''),
              sourceRequisitionDate:       Value(line['source_requisition_date'] as String? ?? ''),
              sourceRequisitionLineSerial: Value((line['source_requisition_line_serial'] as num?)?.toInt()),
              productId:                   line['product_id'] as String? ?? '',
              uomId:                       Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor:         Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:                     Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:                    Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:                     Value((line['base_qty']  as num? ?? 0).toDouble()),
              departmentId:                Value(line['department_id'] as String? ?? ''),
              consumptionAreaId:           Value(line['consumption_area_id'] as String? ?? ''),
              batchesJson:                 Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:                 Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:                    Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(MaterialIssueHeaderCacheEntry r) => {
        'client_id':    r.clientId,
        'company_id':   r.companyId,
        'location_id':  r.locationId,
        'location':     {'location_name': r.locationName},
        'issue_no':     r.issueNo,
        'issue_date':   r.issueDate,
        'remarks':      r.remarks,
        'status':       r.status,
      };
}

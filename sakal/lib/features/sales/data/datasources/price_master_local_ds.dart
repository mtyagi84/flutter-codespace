import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class PriceMasterLocalDs {
  final AppDatabase _db;
  PriceMasterLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listBatches({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? priceType,
    String? locationId,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.priceMasterHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.entryDate), (t) => OrderingTerm.desc(t.entryNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    if (priceType != null && priceType.isNotEmpty) q.where((t) => t.priceType.equals(priceType));
    if (locationId != null && locationId.isNotEmpty) q.where((t) => t.locationId.equals(locationId));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) =>
          (r['entry_no'] as String).toLowerCase().contains(s) ||
          ((r['customer'] as Map)['account_name'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String entryNo,
    String? entryDate,
  }) async {
    final q = _db.select(_db.priceMasterHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.entryNo.equals(entryNo))
      ..where((t) => t.isDeleted.equals(false));
    if (entryDate != null && entryDate.isNotEmpty) {
      q.where((t) => t.entryDate.equals(entryDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.entryDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String entryNo,
    required String entryDate,
  }) async {
    final rows = await (_db.select(_db.priceMasterLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.entryNo.equals(entryNo))
          ..where((t) => t.entryDate.equals(entryDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from Maps (after remote fetch, or the offline-save path) ──────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final customer = h['customer'] as Map<String, dynamic>?;
    final location = h['location'] as Map<String, dynamic>?;
    final currency = h['currency'] as Map<String, dynamic>?;
    await _db.into(_db.priceMasterHeadersCache).insertOnConflictUpdate(
          PriceMasterHeadersCacheCompanion.insert(
            clientId:     h['client_id'] as String,
            companyId:    h['company_id'] as String,
            entryNo:      h['entry_no'] as String,
            entryDate:    h['entry_date'] as String,
            locationId:    Value(h['location_id'] as String? ?? ''),
            locationName:  Value(location?['location_name'] as String? ?? ''),
            priceType:    Value(h['price_type'] as String? ?? 'GENERIC'),
            customerId:   Value(h['customer_id'] as String? ?? ''),
            customerCode: Value(customer?['account_code'] as String? ?? ''),
            customerName: Value(customer?['account_name'] as String? ?? ''),
            effectiveDate: Value(h['effective_date'] as String? ?? ''),
            priceCurrencyId: Value(h['price_currency_id'] as String? ?? ''),
            currencyCode:    Value(currency?['currency_id'] as String? ?? ''),
            rateToBase:      Value((h['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal:     Value((h['rate_to_local'] as num? ?? 1).toDouble()),
            status:       Value(h['status'] as String? ?? 'DRAFT'),
            approvedBy:   Value(h['approved_by'] as String? ?? ''),
            approvedAt:   Value(h['approved_at'] as String? ?? ''),
            remarks:      Value(h['remarks'] as String? ?? ''),
            lineCount:    Value((h['line_count'] as num? ?? 0).toInt()),
            cachedAt:     Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId, String companyId, String entryNo, String entryDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.priceMasterLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.entryNo.equals(entryNo))
          ..where((t) => t.entryDate.equals(entryDate)))
        .go();
    for (final line in lines) {
      final product         = line['product'] as Map<String, dynamic>?;
      final uom             = line['uom'] as Map<String, dynamic>?;
      final belowCostReason = line['below_cost_reason'] as Map<String, dynamic>?;
      await _db.into(_db.priceMasterLinesCache).insert(
            PriceMasterLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              entryNo:             entryNo,
              entryDate:           entryDate,
              serialNo:            line['serial_no'] as int,
              productId:           line['product_id'] as String,
              productCode:         Value(product?['product_code'] as String? ?? ''),
              productName:         Value(product?['product_name'] as String? ?? ''),
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomLabel:            Value(uom?['description'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              costPrice:           Value((line['cost_price'] as num? ?? 0).toDouble()),
              marginPercent:       Value((line['margin_percent'] as num?)?.toDouble()),
              sellingPrice:        Value((line['selling_price'] as num? ?? 0).toDouble()),
              belowCostReasonId:   Value(line['below_cost_reason_id'] as String? ?? ''),
              belowCostReasonName: Value(belowCostReason?['description'] as String? ?? ''),
              isTaxInclusive:      Value(line['is_tax_inclusive'] as bool? ?? false),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveEntryNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now       = DateTime.now();
    final clientId  = headerMap['client_id']  as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final entryDate = headerMap['entry_date'] as String? ?? '';

    await _db.into(_db.priceMasterHeadersCache).insertOnConflictUpdate(
          PriceMasterHeadersCacheCompanion.insert(
            clientId:      clientId,
            companyId:     companyId,
            entryNo:       effectiveEntryNo,
            entryDate:     entryDate,
            locationId:    Value(headerMap['location_id'] as String? ?? ''),
            priceType:     Value(headerMap['price_type'] as String? ?? 'GENERIC'),
            customerId:    Value(headerMap['customer_id'] as String? ?? ''),
            effectiveDate: Value(headerMap['effective_date'] as String? ?? ''),
            priceCurrencyId: Value(headerMap['price_currency_id'] as String? ?? ''),
            rateToBase:      Value((headerMap['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal:     Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            status:        const Value('DRAFT'),
            remarks:       Value(headerMap['remarks'] as String? ?? ''),
            lineCount:     Value(lineMaps.length),
            isDeleted:     const Value(false),
            cachedAt:      Value(now),
          ),
        );

    await (_db.delete(_db.priceMasterLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.entryNo.equals(effectiveEntryNo))
          ..where((t) => t.entryDate.equals(entryDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.priceMasterLinesCache).insert(
            PriceMasterLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              entryNo:             effectiveEntryNo,
              entryDate:           entryDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              uomId:               Value(line['uom_id'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              barcode:             Value(line['barcode'] as String? ?? ''),
              costPrice:           Value((line['cost_price'] as num? ?? 0).toDouble()),
              marginPercent:       Value((line['margin_percent'] as num?)?.toDouble()),
              sellingPrice:        Value((line['selling_price'] as num? ?? 0).toDouble()),
              belowCostReasonId:   Value(line['below_cost_reason_id'] as String? ?? ''),
              isTaxInclusive:      Value(line['is_tax_inclusive'] as bool? ?? false),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(PriceMasterHeaderCacheEntry r) => {
        'client_id':      r.clientId,
        'company_id':     r.companyId,
        'entry_no':       r.entryNo,
        'entry_date':     r.entryDate,
        'location_id':    r.locationId.isEmpty ? null : r.locationId,
        'location':       {'location_name': r.locationName},
        'price_type':     r.priceType,
        'customer_id':    r.customerId.isEmpty ? null : r.customerId,
        'customer':       {'account_code': r.customerCode, 'account_name': r.customerName},
        'effective_date': r.effectiveDate,
        'price_currency_id': r.priceCurrencyId.isEmpty ? null : r.priceCurrencyId,
        'currency':       {'currency_id': r.currencyCode},
        'rate_to_base':   r.rateToBase,
        'rate_to_local':  r.rateToLocal,
        'status':         r.status,
        'approved_by':    r.approvedBy,
        'approved_at':    r.approvedAt,
        'remarks':        r.remarks,
        'line_count':     r.lineCount,
      };

  Map<String, dynamic> _lineToMap(PriceMasterLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName},
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'barcode':               r.barcode.isEmpty ? null : r.barcode,
        'cost_price':            r.costPrice,
        'margin_percent':        r.marginPercent,
        'selling_price':         r.sellingPrice,
        'below_cost_reason_id':  r.belowCostReasonId.isEmpty ? null : r.belowCostReasonId,
        'below_cost_reason':     {'description': r.belowCostReasonName},
        'is_tax_inclusive':      r.isTaxInclusive,
        'remarks':               r.remarks,
      };
}

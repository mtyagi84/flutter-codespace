import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class SalesDeliveryLocalDs {
  final AppDatabase _db;
  SalesDeliveryLocalDs(this._db);

  Future<List<Map<String, dynamic>>> listDeliveries({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.salesDeliveriesCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.deliveryDate), (t) => OrderingTerm.desc(t.deliveryNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) =>
          (r['delivery_no'] as String).toLowerCase().contains(s) ||
          (r['invoice_no'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    String? deliveryDate,
  }) async {
    final q = _db.select(_db.salesDeliveriesCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.deliveryNo.equals(deliveryNo))
      ..where((t) => t.isDeleted.equals(false));
    if (deliveryDate != null && deliveryDate.isNotEmpty) {
      q.where((t) => t.deliveryDate.equals(deliveryDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.deliveryDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String deliveryNo,
    required String deliveryDate,
  }) async {
    final rows = await (_db.select(_db.salesDeliveryLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.deliveryNo.equals(deliveryNo))
          ..where((t) => t.deliveryDate.equals(deliveryDate))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from raw save-payload Maps (offline save path) ────────────────

  Future<void> cacheFromMaps(
    String effectiveDeliveryNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now          = DateTime.now();
    final clientId     = headerMap['client_id']  as String? ?? '';
    final companyId    = headerMap['company_id'] as String? ?? '';
    final deliveryDate = headerMap['delivery_date'] as String? ?? '';

    await _db.into(_db.salesDeliveriesCache).insertOnConflictUpdate(
          SalesDeliveriesCacheCompanion.insert(
            clientId:            clientId,
            companyId:           companyId,
            deliveryNo:          effectiveDeliveryNo,
            deliveryDate:        deliveryDate,
            invoiceNo:           headerMap['invoice_no'] as String? ?? '',
            invoiceDate:         headerMap['invoice_date'] as String? ?? '',
            customerId:          headerMap['customer_id'] as String? ?? '',
            shipToLocationId:    Value(headerMap['ship_to_location_id'] as String? ?? ''),
            shipToLocationName:  Value(headerMap['ship_to_location_name'] as String? ?? ''),
            shipToAddressLine1:  Value(headerMap['ship_to_address_line1'] as String? ?? ''),
            shipToAddressLine2:  Value(headerMap['ship_to_address_line2'] as String? ?? ''),
            shipToCityId:        Value(headerMap['ship_to_city_id'] as String? ?? ''),
            shipToContactPerson: Value(headerMap['ship_to_contact_person'] as String? ?? ''),
            shipToContactPhone:  Value(headerMap['ship_to_contact_phone'] as String? ?? ''),
            receivedByName:      Value(headerMap['received_by_name'] as String? ?? ''),
            reason:              Value(headerMap['reason'] as String? ?? ''),
            remarks:             Value(headerMap['remarks'] as String? ?? ''),
            status:              const Value('DRAFT'),
            isDeleted:           const Value(false),
            cachedAt:            Value(now),
          ),
        );

    await (_db.delete(_db.salesDeliveryLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.deliveryNo.equals(effectiveDeliveryNo))
          ..where((t) => t.deliveryDate.equals(deliveryDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.salesDeliveryLinesCache).insert(
            SalesDeliveryLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              deliveryNo:          effectiveDeliveryNo,
              deliveryDate:        deliveryDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              invoiceLineSerial:   Value((line['invoice_line_serial'] as num? ?? 0).toInt()),
              productId:           line['product_id'] as String? ?? '',
              barcode:             Value(line['barcode'] as String? ?? ''),
              uomId:               line['uom_id'] as String? ?? '',
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(SalesDeliveryCacheEntry r) => {
        'client_id':              r.clientId,
        'company_id':             r.companyId,
        'location_id':            r.locationId,
        'location':               {'location_name': r.locationName},
        'delivery_no':            r.deliveryNo,
        'delivery_date':          r.deliveryDate,
        'invoice_no':             r.invoiceNo,
        'invoice_date':           r.invoiceDate,
        'customer_id':            r.customerId,
        'customer':               {'account_code': r.customerCode, 'account_name': r.customerName},
        'ship_to_location_id':    r.shipToLocationId.isEmpty ? null : r.shipToLocationId,
        'ship_to_location_name':  r.shipToLocationName,
        'ship_to_address_line1':  r.shipToAddressLine1,
        'ship_to_address_line2':  r.shipToAddressLine2,
        'ship_to_city_id':        r.shipToCityId.isEmpty ? null : r.shipToCityId,
        'ship_to_contact_person': r.shipToContactPerson,
        'ship_to_contact_phone':  r.shipToContactPhone,
        'received_by_name':      r.receivedByName,
        'reason':                r.reason,
        'remarks':               r.remarks,
        'status':                r.status,
        'cos_voucher_no':        r.cosVoucherNo.isEmpty ? null : r.cosVoucherNo,
        'cos_voucher_date':      r.cosVoucherDate.isEmpty ? null : r.cosVoucherDate,
      };

  Map<String, dynamic> _lineToMap(SalesDeliveryLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'invoice_line_serial':   r.invoiceLineSerial,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName},
        'barcode':               r.barcode,
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'qty_pack':              r.qtyPack,
        'qty_loose':             r.qtyLoose,
        'base_qty':              r.baseQty,
      };
}

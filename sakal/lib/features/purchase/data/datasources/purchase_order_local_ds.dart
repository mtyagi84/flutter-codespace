import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';
import '../models/po_charge_line_model.dart';
import '../models/purchase_order_line_model.dart';
import '../models/purchase_order_model.dart';

class PurchaseOrderLocalDs {
  final AppDatabase _db;
  PurchaseOrderLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<PurchaseOrderModel>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.purchaseOrdersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.orderDate), (t) => OrderingTerm.desc(t.orderNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerFromCache).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((o) => o.orderNo.toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<PurchaseOrderModel?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate,
  }) async {
    final q = _db.select(_db.purchaseOrdersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.orderNo.equals(orderNo))
      ..where((t) => t.isDeleted.equals(false));
    if (orderDate != null && orderDate.isNotEmpty) {
      q.where((t) => t.orderDate.equals(orderDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.orderDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerFromCache(row);
  }

  Future<List<PurchaseOrderLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final rows = await (_db.select(_db.purchaseOrderLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.orderNo.equals(orderNo))
          ..where((t) => t.orderDate.equals(orderDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineFromCache).toList();
  }

  Future<List<PoChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final rows = await (_db.select(_db.poChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.orderNo.equals(orderNo))
          ..where((t) => t.orderDate.equals(orderDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_chargeFromCache).toList();
  }

  // ── Write — from model objects (after remote fetch) ───────────────────────

  Future<void> cacheHeader(PurchaseOrderModel h) =>
      _db.into(_db.purchaseOrdersCache).insertOnConflictUpdate(
            PurchaseOrdersCacheCompanion.insert(
              clientId:        h.clientId,
              companyId:       h.companyId,
              locationId:      Value(h.locationId),
              locationName:    Value(h.locationName ?? ''),
              orderNo:         h.orderNo,
              orderDate:       h.orderDate,
              poType:          Value(h.poType),
              supplierId:      h.supplierId,
              supplierCode:    Value(h.supplierCode ?? ''),
              supplierName:    Value(h.supplierName ?? ''),
              supplierRefNo:   Value(h.supplierRefNo ?? ''),
              supplierRefDate: Value(h.supplierRefDate ?? ''),
              indentNo:        Value(h.indentNo ?? ''),
              indentDate:      Value(h.indentDate ?? ''),
              rfqNo:           Value(h.rfqNo ?? ''),
              rfqDate:         Value(h.rfqDate ?? ''),
              quotationNo:     Value(h.quotationNo ?? ''),
              quotationDate:   Value(h.quotationDate ?? ''),
              paymentTerms:    Value(h.paymentTerms ?? ''),
              poCurrencyId:    h.poCurrencyId,
              poCurrencyCode:  Value(h.poCurrencyCode ?? ''),
              rateToBase:      Value(h.rateToBase),
              rateToLocal:     Value(h.rateToLocal),
              grossAmount:     Value(h.grossAmount),
              discountAmount:  Value(h.discountAmount),
              chargesAmount:   Value(h.chargesAmount),
              itemTaxAmount:   Value(h.itemTaxAmount),
              chargeTaxAmount: Value(h.chargeTaxAmount),
              grandTotal:      Value(h.grandTotal),
              buyerId:         Value(h.buyerId ?? ''),
              buyerName:       Value(h.buyerName ?? ''),
              status:          Value(h.status),
              approvedBy:      Value(h.approvedBy ?? ''),
              approvedAt:      Value(h.approvedAt ?? ''),
              orderSubject:    Value(h.orderSubject ?? ''),
              billTo:          Value(h.billTo ?? ''),
              shipTo:          Value(h.shipTo ?? ''),
              remarks:         Value(h.remarks ?? ''),
              cachedAt:        Value(DateTime.now()),
            ),
          );

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String orderNo,
    String orderDate,
    List<PurchaseOrderLineModel> lines,
  ) async {
    await (_db.delete(_db.purchaseOrderLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.orderNo.equals(orderNo))
          ..where((t) => t.orderDate.equals(orderDate)))
        .go();
    for (final line in lines) {
      await _db.into(_db.purchaseOrderLinesCache).insert(
            PurchaseOrderLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              orderNo:             orderNo,
              orderDate:           orderDate,
              serialNo:            line.serialNo,
              productId:           line.productId,
              productCode:         Value(line.productCode ?? ''),
              productName:         Value(line.productName ?? ''),
              itemDescription:     Value(line.itemDescription ?? ''),
              barcode:             Value(line.barcode ?? ''),
              uomId:               line.uomId,
              uomLabel:            Value(line.uomLabel ?? ''),
              uomConversionFactor: Value(line.uomConversionFactor),
              qtyPack:             Value(line.qtyPack),
              qtyLoose:            Value(line.qtyLoose),
              baseQty:             Value(line.baseQty),
              rate:                Value(line.rate),
              grossAmount:         Value(line.grossAmount),
              discountPercent:     Value(line.discountPercent),
              discountAmount:      Value(line.discountAmount),
              taxGroupId:          Value(line.taxGroupId ?? ''),
              taxGroupName:        Value(line.taxGroupName ?? ''),
              taxAmount:           Value(line.taxAmount),
              finalAmount:         Value(line.finalAmount),
              baseAmount:          Value(line.baseAmount),
              localAmount:         Value(line.localAmount),
              chargeAmount:        Value(line.chargeAmount),
              landedAmount:        Value(line.landedAmount),
              departmentId:        Value(line.departmentId ?? ''),
              consumptionAreaId:   Value(line.consumptionAreaId ?? ''),
              qtyOnHandAtOrder:    Value(line.qtyOnHandAtOrder),
              reorderLevelAtOrder: Value(line.reorderLevelAtOrder),
              qtyReceived:         Value(line.qtyReceived),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  Future<void> cacheCharges(
    String clientId,
    String companyId,
    String orderNo,
    String orderDate,
    List<PoChargeLineModel> charges,
  ) async {
    await (_db.delete(_db.poChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.orderNo.equals(orderNo))
          ..where((t) => t.orderDate.equals(orderDate)))
        .go();
    for (final c in charges) {
      await _db.into(_db.poChargeLinesCache).insert(
            PoChargeLinesCacheCompanion.insert(
              clientId:         clientId,
              companyId:        companyId,
              orderNo:          orderNo,
              orderDate:        orderDate,
              serialNo:         c.serialNo,
              chargeId:         c.chargeId,
              chargeName:       Value(c.chargeName),
              isTaxable:        Value(c.isTaxable),
              taxId:            Value(c.taxId ?? ''),
              nature:           Value(c.nature),
              glAccountId:      Value(c.glAccountId ?? ''),
              amountOrPercent:  Value(c.amountOrPercent),
              percent:          Value(c.percent),
              amount:           Value(c.amount),
              taxAmount:        Value(c.taxAmount),
              allocationFactor: Value(c.allocationFactor),
              cachedAt:         Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw Maps (offline save path before server round-trip) ────

  Future<void> cacheFromMaps(
    String effectiveOrderNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> chargeMaps,
  ) async {
    final now = DateTime.now();
    final clientId   = headerMap['client_id']   as String? ?? '';
    final companyId  = headerMap['company_id']  as String? ?? '';
    final locationId = headerMap['location_id'] as String? ?? '';
    final orderDate  = headerMap['order_date']  as String? ?? '';

    await _db.into(_db.purchaseOrdersCache).insertOnConflictUpdate(
          PurchaseOrdersCacheCompanion.insert(
            clientId:        clientId,
            companyId:       companyId,
            locationId:      Value(locationId),
            orderNo:         effectiveOrderNo,
            orderDate:       orderDate,
            poType:          Value(headerMap['po_type'] as String? ?? 'LOCAL'),
            supplierId:      headerMap['supplier_id'] as String? ?? '',
            supplierRefNo:   Value(headerMap['supplier_ref_no']   as String? ?? ''),
            supplierRefDate: Value(headerMap['supplier_ref_date'] as String? ?? ''),
            indentNo:        Value(headerMap['indent_no']    as String? ?? ''),
            indentDate:      Value(headerMap['indent_date']  as String? ?? ''),
            rfqNo:           Value(headerMap['rfq_no']       as String? ?? ''),
            rfqDate:         Value(headerMap['rfq_date']     as String? ?? ''),
            quotationNo:     Value(headerMap['quotation_no']   as String? ?? ''),
            quotationDate:   Value(headerMap['quotation_date'] as String? ?? ''),
            paymentTerms:    Value(headerMap['payment_terms'] as String? ?? ''),
            poCurrencyId:    headerMap['po_currency_id'] as String? ?? '',
            rateToBase:      Value((headerMap['rate_to_base']  as num? ?? 1).toDouble()),
            rateToLocal:     Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            grossAmount:     Value((headerMap['gross_amount']      as num? ?? 0).toDouble()),
            discountAmount:  Value((headerMap['discount_amount']   as num? ?? 0).toDouble()),
            chargesAmount:   Value((headerMap['charges_amount']    as num? ?? 0).toDouble()),
            itemTaxAmount:   Value((headerMap['item_tax_amount']   as num? ?? 0).toDouble()),
            chargeTaxAmount: Value((headerMap['charge_tax_amount'] as num? ?? 0).toDouble()),
            grandTotal:      Value((headerMap['grand_total']       as num? ?? 0).toDouble()),
            buyerId:         Value(headerMap['buyer_id'] as String? ?? ''),
            orderSubject:    Value(headerMap['order_subject'] as String? ?? ''),
            billTo:          Value(headerMap['bill_to'] as String? ?? ''),
            shipTo:          Value(headerMap['ship_to'] as String? ?? ''),
            remarks:         Value(headerMap['remarks'] as String? ?? ''),
            status:          const Value('DRAFT'),
            isDeleted:       const Value(false),
            cachedAt:        Value(now),
          ),
        );

    await (_db.delete(_db.purchaseOrderLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.orderNo.equals(effectiveOrderNo))
          ..where((t) => t.orderDate.equals(orderDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.purchaseOrderLinesCache).insert(
            PurchaseOrderLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              orderNo:             effectiveOrderNo,
              orderDate:           orderDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              itemDescription:     Value(line['item_description'] as String? ?? ''),
              barcode:             Value(line['barcode'] as String? ?? ''),
              uomId:               line['uom_id'] as String? ?? '',
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              rate:                Value((line['rate']         as num? ?? 0).toDouble()),
              grossAmount:         Value((line['gross_amount'] as num? ?? 0).toDouble()),
              discountPercent:     Value((line['discount_percent'] as num? ?? 0).toDouble()),
              discountAmount:      Value((line['discount_amount']  as num? ?? 0).toDouble()),
              taxGroupId:          Value(line['tax_group_id'] as String? ?? ''),
              taxAmount:           Value((line['tax_amount']   as num? ?? 0).toDouble()),
              finalAmount:         Value((line['final_amount'] as num? ?? 0).toDouble()),
              baseAmount:          Value((line['base_amount']  as num? ?? 0).toDouble()),
              localAmount:         Value((line['local_amount'] as num? ?? 0).toDouble()),
              chargeAmount:        Value((line['charge_amount'] as num? ?? 0).toDouble()),
              landedAmount:        Value((line['landed_amount'] as num? ?? 0).toDouble()),
              departmentId:        Value(line['department_id'] as String? ?? ''),
              consumptionAreaId:   Value(line['consumption_area_id'] as String? ?? ''),
              qtyOnHandAtOrder:    Value((line['qty_on_hand_at_order'] as num?)?.toDouble()),
              reorderLevelAtOrder: Value((line['reorder_level_at_order'] as num?)?.toDouble()),
              cachedAt:            Value(now),
            ),
          );
    }

    await (_db.delete(_db.poChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.orderNo.equals(effectiveOrderNo))
          ..where((t) => t.orderDate.equals(orderDate)))
        .go();
    for (final c in chargeMaps) {
      await _db.into(_db.poChargeLinesCache).insert(
            PoChargeLinesCacheCompanion.insert(
              clientId:         clientId,
              companyId:        companyId,
              orderNo:          effectiveOrderNo,
              orderDate:        orderDate,
              serialNo:         (c['serial_no'] as num? ?? 0).toInt(),
              chargeId:         c['charge_id'] as String? ?? '',
              chargeName:       Value(c['charge_name'] as String? ?? ''),
              isTaxable:        Value(c['is_taxable'] as bool? ?? false),
              taxId:            Value(c['tax_id'] as String? ?? ''),
              nature:           Value(c['nature'] as String? ?? 'ADD'),
              glAccountId:      Value(c['gl_account_id'] as String? ?? ''),
              amountOrPercent:  Value(c['amount_or_percent'] as String? ?? 'AMOUNT'),
              percent:          Value((c['percent'] as num?)?.toDouble()),
              amount:           Value((c['amount']     as num? ?? 0).toDouble()),
              taxAmount:        Value((c['tax_amount']  as num? ?? 0).toDouble()),
              allocationFactor: Value((c['allocation_factor'] as num?)?.toDouble()),
              cachedAt:         Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  PurchaseOrderModel _headerFromCache(PurchaseOrderCacheEntry r) => PurchaseOrderModel(
        id:              '${r.orderNo}_${r.orderDate}',
        clientId:        r.clientId,
        companyId:       r.companyId,
        locationId:      r.locationId,
        locationName:    r.locationName,
        orderNo:         r.orderNo,
        orderDate:       r.orderDate,
        poType:          r.poType,
        supplierId:      r.supplierId,
        supplierCode:    r.supplierCode,
        supplierName:    r.supplierName,
        supplierRefNo:   r.supplierRefNo,
        supplierRefDate: r.supplierRefDate,
        indentNo:        r.indentNo,
        indentDate:      r.indentDate,
        rfqNo:           r.rfqNo,
        rfqDate:         r.rfqDate,
        quotationNo:     r.quotationNo,
        quotationDate:   r.quotationDate,
        paymentTerms:    r.paymentTerms,
        poCurrencyId:    r.poCurrencyId,
        poCurrencyCode:  r.poCurrencyCode,
        rateToBase:      r.rateToBase,
        rateToLocal:     r.rateToLocal,
        grossAmount:     r.grossAmount,
        discountAmount:  r.discountAmount,
        chargesAmount:   r.chargesAmount,
        itemTaxAmount:   r.itemTaxAmount,
        chargeTaxAmount: r.chargeTaxAmount,
        grandTotal:      r.grandTotal,
        buyerId:         r.buyerId,
        buyerName:       r.buyerName,
        status:          r.status,
        approvedBy:      r.approvedBy,
        approvedAt:      r.approvedAt,
        orderSubject:    r.orderSubject,
        billTo:          r.billTo,
        shipTo:          r.shipTo,
        remarks:         r.remarks,
      );

  PurchaseOrderLineModel _lineFromCache(PurchaseOrderLineCacheEntry r) => PurchaseOrderLineModel(
        id:                  '${r.orderNo}_${r.orderDate}_${r.serialNo}',
        serialNo:            r.serialNo,
        productId:           r.productId,
        productCode:         r.productCode,
        productName:         r.productName,
        itemDescription:     r.itemDescription,
        barcode:             r.barcode,
        uomId:               r.uomId,
        uomLabel:            r.uomLabel,
        uomConversionFactor: r.uomConversionFactor,
        qtyPack:             r.qtyPack,
        qtyLoose:            r.qtyLoose,
        baseQty:             r.baseQty,
        rate:                r.rate,
        grossAmount:         r.grossAmount,
        discountPercent:     r.discountPercent,
        discountAmount:      r.discountAmount,
        taxGroupId:          r.taxGroupId,
        taxGroupName:        r.taxGroupName,
        taxAmount:           r.taxAmount,
        finalAmount:         r.finalAmount,
        baseAmount:          r.baseAmount,
        localAmount:         r.localAmount,
        chargeAmount:        r.chargeAmount,
        landedAmount:        r.landedAmount,
        departmentId:        r.departmentId,
        consumptionAreaId:   r.consumptionAreaId,
        qtyOnHandAtOrder:    r.qtyOnHandAtOrder,
        reorderLevelAtOrder: r.reorderLevelAtOrder,
        qtyReceived:         r.qtyReceived,
      );

  PoChargeLineModel _chargeFromCache(PoChargeLineCacheEntry r) => PoChargeLineModel(
        id:               '${r.orderNo}_${r.orderDate}_${r.serialNo}',
        serialNo:         r.serialNo,
        chargeId:         r.chargeId,
        chargeName:       r.chargeName,
        isTaxable:        r.isTaxable,
        taxId:            r.taxId,
        nature:           r.nature,
        glAccountId:      r.glAccountId,
        amountOrPercent:  r.amountOrPercent,
        percent:          r.percent,
        amount:           r.amount,
        taxAmount:        r.taxAmount,
        allocationFactor: r.allocationFactor,
      );
}

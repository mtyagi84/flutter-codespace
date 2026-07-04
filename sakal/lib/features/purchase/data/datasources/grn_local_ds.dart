import 'dart:convert';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';
import '../models/grn_charge_line_model.dart';
import '../models/grn_line_model.dart';
import '../models/grn_model.dart';

class GrnLocalDs {
  final AppDatabase _db;
  GrnLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<GrnModel>> listGrns({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.grnHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.grnDate), (t) => OrderingTerm.desc(t.grnNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerFromCache).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((g) => g.grnNo.toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<GrnModel?> getHeader({
    required String clientId,
    required String companyId,
    required String grnNo,
    String? grnDate,
  }) async {
    final q = _db.select(_db.grnHeadersCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.grnNo.equals(grnNo))
      ..where((t) => t.isDeleted.equals(false));
    if (grnDate != null && grnDate.isNotEmpty) {
      q.where((t) => t.grnDate.equals(grnDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.grnDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerFromCache(row);
  }

  Future<List<GrnLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final rows = await (_db.select(_db.grnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.grnNo.equals(grnNo))
          ..where((t) => t.grnDate.equals(grnDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineFromCache).toList();
  }

  Future<List<GrnChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final rows = await (_db.select(_db.grnChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.grnNo.equals(grnNo))
          ..where((t) => t.grnDate.equals(grnDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_chargeFromCache).toList();
  }

  // ── Write — from model objects (after remote fetch) ───────────────────────

  Future<void> cacheHeader(GrnModel h) =>
      _db.into(_db.grnHeadersCache).insertOnConflictUpdate(
            GrnHeadersCacheCompanion.insert(
              clientId:             h.clientId,
              companyId:            h.companyId,
              locationId:           Value(h.locationId),
              locationName:         Value(h.locationName ?? ''),
              grnNo:                h.grnNo,
              grnDate:              h.grnDate,
              supplierId:           h.supplierId,
              supplierCode:         Value(h.supplierCode ?? ''),
              supplierName:         Value(h.supplierName ?? ''),
              receiptMode:          Value(h.receiptMode),
              supplierDeliveryNo:   Value(h.supplierDeliveryNo ?? ''),
              supplierDeliveryDate: Value(h.supplierDeliveryDate ?? ''),
              grnCurrencyId:        Value(h.grnCurrencyId ?? ''),
              grnCurrencyCode:      Value(h.grnCurrencyCode ?? ''),
              rateToBase:           Value(h.rateToBase),
              rateToLocal:          Value(h.rateToLocal),
              grossAmount:          Value(h.grossAmount),
              discountAmount:       Value(h.discountAmount),
              chargesAmount:        Value(h.chargesAmount),
              itemTaxAmount:        Value(h.itemTaxAmount),
              chargeTaxAmount:      Value(h.chargeTaxAmount),
              grandTotal:           Value(h.grandTotal),
              billTo:               Value(h.billTo ?? ''),
              shipTo:               Value(h.shipTo ?? ''),
              remarks:              Value(h.remarks ?? ''),
              status:               Value(h.status),
              approvedBy:           Value(h.approvedBy ?? ''),
              approvedAt:           Value(h.approvedAt ?? ''),
              postedVoucherNo:      Value(h.postedVoucherNo ?? ''),
              postedVoucherDate:    Value(h.postedVoucherDate ?? ''),
              cachedAt:             Value(DateTime.now()),
            ),
          );

  Future<void> cacheLines(
    String clientId,
    String companyId,
    String grnNo,
    String grnDate,
    List<GrnLineModel> lines,
  ) async {
    await (_db.delete(_db.grnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.grnNo.equals(grnNo))
          ..where((t) => t.grnDate.equals(grnDate)))
        .go();
    for (final line in lines) {
      await _db.into(_db.grnLinesCache).insert(
            GrnLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              grnNo:               grnNo,
              grnDate:             grnDate,
              serialNo:            line.serialNo,
              productId:           line.productId,
              productCode:         Value(line.productCode ?? ''),
              productName:         Value(line.productName ?? ''),
              sourcePoOrderNo:     Value(line.sourcePoOrderNo ?? ''),
              sourcePoOrderDate:   Value(line.sourcePoOrderDate ?? ''),
              sourcePoLineSerial:  Value(line.sourcePoLineSerial),
              itemDescription:     Value(line.itemDescription ?? ''),
              uomId:               Value(line.uomId),
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
              batchesJson:         Value(jsonEncode(line.batches.map((b) => b.toJson()).toList())),
              serialsJson:         Value(jsonEncode(line.serials.map((s) => s.toJson()).toList())),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  Future<void> cacheCharges(
    String clientId,
    String companyId,
    String grnNo,
    String grnDate,
    List<GrnChargeLineModel> charges,
  ) async {
    await (_db.delete(_db.grnChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.grnNo.equals(grnNo))
          ..where((t) => t.grnDate.equals(grnDate)))
        .go();
    for (final c in charges) {
      await _db.into(_db.grnChargeLinesCache).insert(
            GrnChargeLinesCacheCompanion.insert(
              clientId:          clientId,
              companyId:         companyId,
              grnNo:             grnNo,
              grnDate:           grnDate,
              serialNo:          c.serialNo,
              chargeId:          c.chargeId,
              chargeName:        Value(c.chargeName),
              isTaxable:         Value(c.isTaxable),
              taxId:             Value(c.taxId ?? ''),
              nature:            Value(c.nature),
              glAccountId:       Value(c.glAccountId ?? ''),
              amountOrPercent:   Value(c.amountOrPercent),
              percent:           Value(c.percent),
              amount:            Value(c.amount),
              taxAmount:         Value(c.taxAmount),
              allocationFactor:  Value(c.allocationFactor),
              sourcePoOrderNo:   Value(c.sourcePoOrderNo ?? ''),
              sourcePoOrderDate: Value(c.sourcePoOrderDate ?? ''),
              cachedAt:          Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw Maps (offline save path before server round-trip) ────

  Future<void> cacheFromMaps(
    String effectiveGrnNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> batchMaps,
    List<Map<String, dynamic>> serialMaps,
    List<Map<String, dynamic>> chargeMaps,
  ) async {
    final now = DateTime.now();
    final clientId  = headerMap['client_id']  as String? ?? '';
    final companyId = headerMap['company_id'] as String? ?? '';
    final grnDate   = headerMap['grn_date']   as String? ?? '';

    await _db.into(_db.grnHeadersCache).insertOnConflictUpdate(
          GrnHeadersCacheCompanion.insert(
            clientId:             clientId,
            companyId:            companyId,
            locationId:           Value(headerMap['location_id'] as String? ?? ''),
            grnNo:                effectiveGrnNo,
            grnDate:              grnDate,
            supplierId:           headerMap['supplier_id'] as String? ?? '',
            receiptMode:          Value(headerMap['receipt_mode'] as String? ?? 'DIRECT'),
            supplierDeliveryNo:   Value(headerMap['supplier_delivery_no'] as String? ?? ''),
            supplierDeliveryDate: Value(headerMap['supplier_delivery_date'] as String? ?? ''),
            grnCurrencyId:        Value(headerMap['grn_currency_id'] as String? ?? ''),
            rateToBase:           Value((headerMap['rate_to_base']  as num? ?? 1).toDouble()),
            rateToLocal:          Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            grossAmount:          Value((headerMap['gross_amount']      as num? ?? 0).toDouble()),
            discountAmount:       Value((headerMap['discount_amount']   as num? ?? 0).toDouble()),
            chargesAmount:        Value((headerMap['charges_amount']    as num? ?? 0).toDouble()),
            itemTaxAmount:        Value((headerMap['item_tax_amount']   as num? ?? 0).toDouble()),
            chargeTaxAmount:      Value((headerMap['charge_tax_amount'] as num? ?? 0).toDouble()),
            grandTotal:           Value((headerMap['grand_total']       as num? ?? 0).toDouble()),
            billTo:               Value(headerMap['bill_to'] as String? ?? ''),
            shipTo:               Value(headerMap['ship_to'] as String? ?? ''),
            remarks:              Value(headerMap['remarks'] as String? ?? ''),
            status:               const Value('DRAFT'),
            isDeleted:            const Value(false),
            cachedAt:             Value(now),
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

    await (_db.delete(_db.grnLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.grnNo.equals(effectiveGrnNo))
          ..where((t) => t.grnDate.equals(grnDate)))
        .go();
    for (final line in lineMaps) {
      final serialNo = (line['serial_no'] as num? ?? 0).toInt();
      await _db.into(_db.grnLinesCache).insert(
            GrnLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              grnNo:               effectiveGrnNo,
              grnDate:             grnDate,
              serialNo:            serialNo,
              productId:           line['product_id'] as String? ?? '',
              sourcePoOrderNo:     Value(line['source_po_order_no'] as String? ?? ''),
              sourcePoOrderDate:   Value(line['source_po_order_date'] as String? ?? ''),
              sourcePoLineSerial:  Value((line['source_po_line_serial'] as num?)?.toInt()),
              itemDescription:     Value(line['item_description'] as String? ?? ''),
              uomId:               Value(line['uom_id'] as String? ?? ''),
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
              batchesJson:         Value(jsonEncode(batchesByLine[serialNo] ?? const [])),
              serialsJson:         Value(jsonEncode(serialsByLine[serialNo] ?? const [])),
              cachedAt:            Value(now),
            ),
          );
    }

    await (_db.delete(_db.grnChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.grnNo.equals(effectiveGrnNo))
          ..where((t) => t.grnDate.equals(grnDate)))
        .go();
    for (final c in chargeMaps) {
      await _db.into(_db.grnChargeLinesCache).insert(
            GrnChargeLinesCacheCompanion.insert(
              clientId:          clientId,
              companyId:         companyId,
              grnNo:             effectiveGrnNo,
              grnDate:           grnDate,
              serialNo:          (c['serial_no'] as num? ?? 0).toInt(),
              chargeId:          c['charge_id'] as String? ?? '',
              chargeName:        Value(c['charge_name'] as String? ?? ''),
              isTaxable:         Value(c['is_taxable'] as bool? ?? false),
              taxId:             Value(c['tax_id'] as String? ?? ''),
              nature:            Value(c['nature'] as String? ?? 'ADD'),
              glAccountId:       Value(c['gl_account_id'] as String? ?? ''),
              amountOrPercent:   Value(c['amount_or_percent'] as String? ?? 'AMOUNT'),
              percent:           Value((c['percent'] as num?)?.toDouble()),
              amount:            Value((c['amount']     as num? ?? 0).toDouble()),
              taxAmount:         Value((c['tax_amount']  as num? ?? 0).toDouble()),
              allocationFactor:  Value((c['allocation_factor'] as num?)?.toDouble()),
              sourcePoOrderNo:   Value(c['source_po_order_no'] as String? ?? ''),
              sourcePoOrderDate: Value(c['source_po_order_date'] as String? ?? ''),
              cachedAt:          Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  GrnModel _headerFromCache(GrnHeaderCacheEntry r) => GrnModel(
        id:                   '${r.grnNo}_${r.grnDate}',
        clientId:             r.clientId,
        companyId:            r.companyId,
        locationId:           r.locationId,
        locationName:         r.locationName,
        grnNo:                r.grnNo,
        grnDate:              r.grnDate,
        supplierId:           r.supplierId,
        supplierCode:         r.supplierCode,
        supplierName:         r.supplierName,
        receiptMode:          r.receiptMode,
        supplierDeliveryNo:   r.supplierDeliveryNo,
        supplierDeliveryDate: r.supplierDeliveryDate,
        grnCurrencyId:        r.grnCurrencyId,
        grnCurrencyCode:      r.grnCurrencyCode,
        rateToBase:           r.rateToBase,
        rateToLocal:          r.rateToLocal,
        grossAmount:          r.grossAmount,
        discountAmount:       r.discountAmount,
        chargesAmount:        r.chargesAmount,
        itemTaxAmount:        r.itemTaxAmount,
        chargeTaxAmount:      r.chargeTaxAmount,
        grandTotal:           r.grandTotal,
        billTo:               r.billTo,
        shipTo:               r.shipTo,
        remarks:              r.remarks,
        status:               r.status,
        approvedBy:           r.approvedBy,
        approvedAt:           r.approvedAt,
        postedVoucherNo:      r.postedVoucherNo,
        postedVoucherDate:    r.postedVoucherDate,
      );

  GrnLineModel _lineFromCache(GrnLineCacheEntry r) => GrnLineModel(
        id:                  '${r.grnNo}_${r.grnDate}_${r.serialNo}',
        serialNo:            r.serialNo,
        productId:           r.productId,
        productCode:         r.productCode,
        productName:         r.productName,
        sourcePoOrderNo:     r.sourcePoOrderNo,
        sourcePoOrderDate:   r.sourcePoOrderDate,
        sourcePoLineSerial:  r.sourcePoLineSerial,
        itemDescription:     r.itemDescription,
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
        batches:             (jsonDecode(r.batchesJson) as List)
            .map((e) => GrnBatchModel.fromJson(e as Map<String, dynamic>)).toList(),
        serials:             (jsonDecode(r.serialsJson) as List)
            .map((e) => GrnSerialModel.fromJson(e as Map<String, dynamic>)).toList(),
      );

  GrnChargeLineModel _chargeFromCache(GrnChargeLineCacheEntry r) => GrnChargeLineModel(
        id:                '${r.grnNo}_${r.grnDate}_${r.serialNo}',
        serialNo:          r.serialNo,
        chargeId:          r.chargeId,
        chargeName:        r.chargeName,
        isTaxable:         r.isTaxable,
        taxId:             r.taxId,
        nature:            r.nature,
        glAccountId:       r.glAccountId,
        amountOrPercent:   r.amountOrPercent,
        percent:           r.percent,
        amount:            r.amount,
        taxAmount:         r.taxAmount,
        allocationFactor:  r.allocationFactor,
        sourcePoOrderNo:   r.sourcePoOrderNo,
        sourcePoOrderDate: r.sourcePoOrderDate,
      );
}

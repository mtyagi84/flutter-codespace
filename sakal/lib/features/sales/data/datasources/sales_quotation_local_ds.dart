import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';

class SalesQuotationLocalDs {
  final AppDatabase _db;
  SalesQuotationLocalDs(this._db);

  // ── Read ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listQuotations({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.salesQuotationsCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.quotationDate), (t) => OrderingTerm.desc(t.quotationNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) => (r['quotation_no'] as String).toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    String? quotationDate,
  }) async {
    final q = _db.select(_db.salesQuotationsCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.quotationNo.equals(quotationNo))
      ..where((t) => t.isDeleted.equals(false));
    if (quotationDate != null && quotationDate.isNotEmpty) {
      q.where((t) => t.quotationDate.equals(quotationDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.quotationDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    final rows = await (_db.select(_db.salesQuotationLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.quotationNo.equals(quotationNo))
          ..where((t) => t.quotationDate.equals(quotationDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    final rows = await (_db.select(_db.salesQuotationChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.quotationNo.equals(quotationNo))
          ..where((t) => t.quotationDate.equals(quotationDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_chargeToMap).toList();
  }

  // ── Write — from Maps (after remote fetch, or the offline-save path) ──────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location     = h['location'] as Map<String, dynamic>?;
    final customer      = h['customer'] as Map<String, dynamic>?;
    final salesPerson   = h['sales_person'] as Map<String, dynamic>?;
    final currency       = h['currency'] as Map<String, dynamic>?;
    await _db.into(_db.salesQuotationsCache).insertOnConflictUpdate(
          SalesQuotationsCacheCompanion.insert(
            clientId:              h['client_id'] as String,
            companyId:             h['company_id'] as String,
            locationId:            Value(h['location_id'] as String? ?? ''),
            locationName:          Value(location?['location_name'] as String? ?? ''),
            quotationNo:           h['quotation_no'] as String,
            quotationDate:         h['quotation_date'] as String,
            validUntilDate:        Value(h['valid_until_date'] as String? ?? ''),
            customerType:          Value(h['customer_type'] as String? ?? 'CUSTOMER'),
            customerId:            Value(h['customer_id'] as String? ?? ''),
            customerCode:          Value(customer?['account_code'] as String? ?? ''),
            customerName:          Value(customer?['account_name'] as String? ?? ''),
            partyName:             Value(h['party_name'] as String? ?? ''),
            partyPhone:            Value(h['party_phone'] as String? ?? ''),
            partyEmail:            Value(h['party_email'] as String? ?? ''),
            partyAddress:          Value(h['party_address'] as String? ?? ''),
            salesPersonId:         Value(h['sales_person_id'] as String? ?? ''),
            salesPersonName:       Value(salesPerson?['full_name'] as String? ?? ''),
            quotationCurrencyId:   h['quotation_currency_id'] as String,
            quotationCurrencyCode: Value(currency?['currency_id'] as String? ?? ''),
            rateToBase:            Value((h['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal:           Value((h['rate_to_local'] as num? ?? 1).toDouble()),
            paymentTerms:          Value(h['payment_terms'] as String? ?? ''),
            deliveryTerms:         Value(h['delivery_terms'] as String? ?? ''),
            grossAmount:           Value((h['gross_amount'] as num? ?? 0).toDouble()),
            discountAmount:        Value((h['discount_amount'] as num? ?? 0).toDouble()),
            chargesAmount:         Value((h['charges_amount'] as num? ?? 0).toDouble()),
            taxAmount:             Value((h['tax_amount'] as num? ?? 0).toDouble()),
            grandTotal:            Value((h['grand_total'] as num? ?? 0).toDouble()),
            status:                Value(h['status'] as String? ?? 'DRAFT'),
            remarks:               Value(h['remarks'] as String? ?? ''),
            cachedAt:              Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId, String companyId, String quotationNo, String quotationDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.salesQuotationLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.quotationNo.equals(quotationNo))
          ..where((t) => t.quotationDate.equals(quotationDate)))
        .go();
    for (final line in lines) {
      final product  = line['product'] as Map<String, dynamic>?;
      final uom       = line['uom'] as Map<String, dynamic>?;
      final taxGroup   = line['tax_group'] as Map<String, dynamic>?;
      await _db.into(_db.salesQuotationLinesCache).insert(
            SalesQuotationLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              quotationNo:         quotationNo,
              quotationDate:       quotationDate,
              serialNo:            line['serial_no'] as int,
              productId:           line['product_id'] as String,
              productCode:         Value(product?['product_code'] as String? ?? ''),
              productName:         Value(product?['product_name'] as String? ?? ''),
              itemDescription:     Value(line['item_description'] as String? ?? ''),
              barcode:             Value(line['barcode'] as String? ?? ''),
              uomId:               line['uom_id'] as String? ?? '',
              uomLabel:            Value(uom?['description'] as String? ?? ''),
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              rate:                Value((line['rate'] as num? ?? 0).toDouble()),
              grossAmount:         Value((line['gross_amount'] as num? ?? 0).toDouble()),
              discountPercent:     Value((line['discount_percent'] as num? ?? 0).toDouble()),
              discountAmount:      Value((line['discount_amount'] as num? ?? 0).toDouble()),
              taxGroupId:          Value(line['tax_group_id'] as String? ?? ''),
              taxGroupName:        Value(taxGroup?['group_name'] as String? ?? ''),
              taxAmount:           Value((line['tax_amount'] as num? ?? 0).toDouble()),
              finalAmount:         Value((line['final_amount'] as num? ?? 0).toDouble()),
              baseAmount:          Value((line['base_amount'] as num? ?? 0).toDouble()),
              localAmount:         Value((line['local_amount'] as num? ?? 0).toDouble()),
              chargeAmount:        Value((line['charge_amount'] as num? ?? 0).toDouble()),
              landedAmount:        Value((line['landed_amount'] as num? ?? 0).toDouble()),
              convertedQty:        Value((line['converted_qty'] as num? ?? 0).toDouble()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  Future<void> cacheCharges(
    String clientId, String companyId, String quotationNo, String quotationDate,
    List<Map<String, dynamic>> charges,
  ) async {
    await (_db.delete(_db.salesQuotationChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.quotationNo.equals(quotationNo))
          ..where((t) => t.quotationDate.equals(quotationDate)))
        .go();
    for (final charge in charges) {
      await _db.into(_db.salesQuotationChargeLinesCache).insert(
            SalesQuotationChargeLinesCacheCompanion.insert(
              clientId:        clientId,
              companyId:       companyId,
              quotationNo:     quotationNo,
              quotationDate:   quotationDate,
              serialNo:        charge['serial_no'] as int,
              chargeId:        charge['charge_id'] as String,
              chargeName:      Value(charge['charge_name'] as String? ?? ''),
              isTaxable:       Value(charge['is_taxable'] as bool? ?? false),
              taxId:           Value(charge['tax_id'] as String? ?? ''),
              nature:          Value(charge['nature'] as String? ?? 'ADD'),
              glAccountId:     Value(charge['gl_account_id'] as String? ?? ''),
              amountOrPercent: Value(charge['amount_or_percent'] as String? ?? 'AMOUNT'),
              percent:         Value((charge['percent'] as num?)?.toDouble()),
              amount:          Value((charge['amount'] as num? ?? 0).toDouble()),
              taxAmount:       Value((charge['tax_amount'] as num? ?? 0).toDouble()),
              allocationFactor: Value((charge['allocation_factor'] as num?)?.toDouble()),
              cachedAt:        Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path) ─────────────────

  Future<void> cacheFromMaps(
    String effectiveQuotationNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
    List<Map<String, dynamic>> chargeMaps,
  ) async {
    final now            = DateTime.now();
    final clientId        = headerMap['client_id']  as String? ?? '';
    final companyId       = headerMap['company_id'] as String? ?? '';
    final quotationDate   = headerMap['quotation_date'] as String? ?? '';

    await _db.into(_db.salesQuotationsCache).insertOnConflictUpdate(
          SalesQuotationsCacheCompanion.insert(
            clientId:              clientId,
            companyId:             companyId,
            locationId:            Value(headerMap['location_id'] as String? ?? ''),
            quotationNo:           effectiveQuotationNo,
            quotationDate:         quotationDate,
            validUntilDate:        Value(headerMap['valid_until_date'] as String? ?? ''),
            customerType:          Value(headerMap['customer_type'] as String? ?? 'CUSTOMER'),
            customerId:            Value(headerMap['customer_id'] as String? ?? ''),
            partyName:             Value(headerMap['party_name'] as String? ?? ''),
            partyPhone:            Value(headerMap['party_phone'] as String? ?? ''),
            partyEmail:            Value(headerMap['party_email'] as String? ?? ''),
            partyAddress:          Value(headerMap['party_address'] as String? ?? ''),
            salesPersonId:         Value(headerMap['sales_person_id'] as String? ?? ''),
            quotationCurrencyId:   headerMap['quotation_currency_id'] as String? ?? '',
            rateToBase:            Value((headerMap['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal:           Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            paymentTerms:          Value(headerMap['payment_terms'] as String? ?? ''),
            deliveryTerms:         Value(headerMap['delivery_terms'] as String? ?? ''),
            grossAmount:           Value((headerMap['gross_amount'] as num? ?? 0).toDouble()),
            discountAmount:        Value((headerMap['discount_amount'] as num? ?? 0).toDouble()),
            chargesAmount:         Value((headerMap['charges_amount'] as num? ?? 0).toDouble()),
            taxAmount:             Value((headerMap['tax_amount'] as num? ?? 0).toDouble()),
            grandTotal:            Value((headerMap['grand_total'] as num? ?? 0).toDouble()),
            status:                const Value('DRAFT'),
            remarks:               Value(headerMap['remarks'] as String? ?? ''),
            isDeleted:             const Value(false),
            cachedAt:              Value(now),
          ),
        );

    await (_db.delete(_db.salesQuotationLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.quotationNo.equals(effectiveQuotationNo))
          ..where((t) => t.quotationDate.equals(quotationDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.salesQuotationLinesCache).insert(
            SalesQuotationLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              quotationNo:         effectiveQuotationNo,
              quotationDate:       quotationDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              uomId:               line['uom_id'] as String? ?? '',
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              rate:                Value((line['rate'] as num? ?? 0).toDouble()),
              grossAmount:         Value((line['gross_amount'] as num? ?? 0).toDouble()),
              discountPercent:     Value((line['discount_percent'] as num? ?? 0).toDouble()),
              discountAmount:      Value((line['discount_amount'] as num? ?? 0).toDouble()),
              taxGroupId:          Value(line['tax_group_id'] as String? ?? ''),
              taxAmount:           Value((line['tax_amount'] as num? ?? 0).toDouble()),
              finalAmount:         Value((line['final_amount'] as num? ?? 0).toDouble()),
              baseAmount:          Value((line['base_amount'] as num? ?? 0).toDouble()),
              localAmount:         Value((line['local_amount'] as num? ?? 0).toDouble()),
              chargeAmount:        Value((line['charge_amount'] as num? ?? 0).toDouble()),
              landedAmount:        Value((line['landed_amount'] as num? ?? 0).toDouble()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(now),
            ),
          );
    }

    await (_db.delete(_db.salesQuotationChargeLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.quotationNo.equals(effectiveQuotationNo))
          ..where((t) => t.quotationDate.equals(quotationDate)))
        .go();
    for (final charge in chargeMaps) {
      await _db.into(_db.salesQuotationChargeLinesCache).insert(
            SalesQuotationChargeLinesCacheCompanion.insert(
              clientId:        clientId,
              companyId:       companyId,
              quotationNo:     effectiveQuotationNo,
              quotationDate:   quotationDate,
              serialNo:        (charge['serial_no'] as num? ?? 0).toInt(),
              chargeId:        charge['charge_id'] as String? ?? '',
              chargeName:      Value(charge['charge_name'] as String? ?? ''),
              isTaxable:       Value(charge['is_taxable'] as bool? ?? false),
              taxId:           Value(charge['tax_id'] as String? ?? ''),
              nature:          Value(charge['nature'] as String? ?? 'ADD'),
              glAccountId:     Value(charge['gl_account_id'] as String? ?? ''),
              amountOrPercent: Value(charge['amount_or_percent'] as String? ?? 'AMOUNT'),
              percent:         Value((charge['percent'] as num?)?.toDouble()),
              amount:          Value((charge['amount'] as num? ?? 0).toDouble()),
              taxAmount:       Value((charge['tax_amount'] as num? ?? 0).toDouble()),
              allocationFactor: Value((charge['allocation_factor'] as num?)?.toDouble()),
              cachedAt:        Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(SalesQuotationCacheEntry r) => {
        'client_id':              r.clientId,
        'company_id':             r.companyId,
        'location_id':            r.locationId,
        'location':               {'location_name': r.locationName},
        'quotation_no':           r.quotationNo,
        'quotation_date':         r.quotationDate,
        'valid_until_date':       r.validUntilDate,
        'customer_type':          r.customerType,
        'customer_id':            r.customerId.isEmpty ? null : r.customerId,
        'customer':               {'account_code': r.customerCode, 'account_name': r.customerName},
        'party_name':             r.partyName,
        'party_phone':            r.partyPhone,
        'party_email':            r.partyEmail,
        'party_address':          r.partyAddress,
        'sales_person_id':        r.salesPersonId,
        'sales_person':           {'full_name': r.salesPersonName},
        'quotation_currency_id':  r.quotationCurrencyId,
        'currency':               {'currency_id': r.quotationCurrencyCode},
        'rate_to_base':           r.rateToBase,
        'rate_to_local':          r.rateToLocal,
        'payment_terms':          r.paymentTerms,
        'delivery_terms':         r.deliveryTerms,
        'gross_amount':           r.grossAmount,
        'discount_amount':        r.discountAmount,
        'charges_amount':         r.chargesAmount,
        'tax_amount':             r.taxAmount,
        'grand_total':            r.grandTotal,
        'status':                 r.status,
        'remarks':                r.remarks,
      };

  Map<String, dynamic> _lineToMap(SalesQuotationLineCacheEntry r) => {
        'serial_no':             r.serialNo,
        'product_id':            r.productId,
        'product':               {'product_code': r.productCode, 'product_name': r.productName},
        'item_description':      r.itemDescription,
        'barcode':               r.barcode,
        'uom_id':                r.uomId,
        'uom':                   {'description': r.uomLabel},
        'uom_conversion_factor': r.uomConversionFactor,
        'qty_pack':              r.qtyPack,
        'qty_loose':             r.qtyLoose,
        'base_qty':              r.baseQty,
        'rate':                  r.rate,
        'gross_amount':          r.grossAmount,
        'discount_percent':      r.discountPercent,
        'discount_amount':       r.discountAmount,
        'tax_group_id':          r.taxGroupId,
        'tax_group':             {'group_name': r.taxGroupName},
        'tax_amount':            r.taxAmount,
        'final_amount':          r.finalAmount,
        'base_amount':           r.baseAmount,
        'local_amount':          r.localAmount,
        'charge_amount':         r.chargeAmount,
        'landed_amount':         r.landedAmount,
        'converted_qty':         r.convertedQty,
        'remarks':               r.remarks,
      };

  Map<String, dynamic> _chargeToMap(SalesQuotationChargeLineCacheEntry r) => {
        'serial_no':         r.serialNo,
        'charge_id':         r.chargeId,
        'charge_name':       r.chargeName,
        'is_taxable':        r.isTaxable,
        'tax_id':            r.taxId,
        'nature':            r.nature,
        'gl_account_id':     r.glAccountId,
        'amount_or_percent': r.amountOrPercent,
        'percent':           r.percent,
        'amount':            r.amount,
        'tax_amount':        r.taxAmount,
        'allocation_factor': r.allocationFactor,
      };
}

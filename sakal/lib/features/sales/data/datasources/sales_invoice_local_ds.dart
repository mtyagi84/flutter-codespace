import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/database/datasources/accounts_local_ds.dart';
import '../../../../core/database/datasources/product_uom_local_ds.dart';
import '../../../../core/database/datasources/tax_group_members_local_ds.dart';
import '../../../../core/database/datasources/tax_rates_local_ds.dart';
import '../../../master/data/datasources/products_local_ds.dart';

class SalesInvoiceLocalDs {
  final AppDatabase _db;
  SalesInvoiceLocalDs(this._db);

  // ── Master-data offline fallback (shared Master-Data Sync facility) ───────
  // Reads from the caches core/sync/master_data_sync_service.dart populates
  // (plus this repository's own per-read defense-in-depth write-through —
  // see sales_invoice_repository_impl.dart). None of these methods write —
  // that happens only via the shared sync service / repository cache-write,
  // never from this façade.

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final products = await ProductsLocalDs(_db).getProducts(
      clientId: clientId, companyId: companyId, isActive: true, search: search, limit: 500,
    );
    final lookupDs = GenericLookupLocalDs(_db);
    final result = <Map<String, dynamic>>[];
    for (final p in products) {
      Map<String, dynamic>? uomRow;
      if (p.baseUomId != null && p.baseUomId!.isNotEmpty) {
        uomRow = await lookupDs.getLookupById(cacheKey: 'COMMON_MASTERS_UNIT', id: p.baseUomId!);
      }
      result.add({
        'id': p.id,
        'product_code': p.productCode,
        'product_name': p.productName,
        'base_uom_id': p.baseUomId,
        'tracking_type': p.trackingType,
        'sales_tax_group_id': p.salesTaxGroupId,
        'cost_currency_id': p.costCurrencyId,
        'uom': {'description': uomRow?['description']},
      });
    }
    return result;
  }

  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) async {
    final byBarcode = await ProductUomLocalDs(_db).getByBarcode(code);
    if (byBarcode != null) return byBarcode;
    if (!tryPartNumber) return null;

    final row = await (_db.select(_db.productsCache)
          ..where((t) => t.partNumber.equals(code) & t.isDeleted.equals(false) & t.isActive.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return {
      'id': row.id,
      'product_code': row.productCode,
      'product_name': row.productName,
      'base_uom_id': row.baseUomId,
      'tracking_type': row.trackingType,
      'sales_tax_group_id': row.salesTaxGroupId,
    };
  }

  Future<List<Map<String, dynamic>>> getProductUoms(String productId) {
    return ProductUomLocalDs(_db).getForProduct(productId);
  }

  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) {
    return GenericLookupLocalDs(_db).getLookups(cacheKey: 'TAX_GROUPS', clientId: clientId, companyId: companyId);
  }

  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) {
    return TaxGroupMembersLocalDs(_db).getMemberTaxIds(groupIds);
  }

  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) {
    return TaxRatesLocalDs(_db).getRatesByIds(taxIds: taxIds, asOfDate: asOfDate);
  }

  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId}) {
    return AccountsLocalDs(_db).getById(customerId);
  }

  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
  }) {
    return GenericLookupLocalDs(_db).getLookupById(cacheKey: 'QUICK_INVOICE_SETUP', id: userId);
  }

  Future<Map<String, dynamic>?> getUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
  }) {
    return GenericLookupLocalDs(_db).getLookupById(cacheKey: 'USER_SALES_CONTROLS', id: userId);
  }

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) {
    return GenericLookupLocalDs(_db).getLookups(cacheKey: 'ADDITIONAL_CHARGES', clientId: clientId, companyId: companyId);
  }

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) {
    return GenericLookupLocalDs(_db).getLookups(cacheKey: 'USERS', clientId: clientId, companyId: companyId);
  }

  // ── Master-data write-through (defense-in-depth, see repository) ──────────

  Future<void> cacheAdditionalCharges({
    required String clientId,
    required String companyId,
    required List<Map<String, dynamic>> rows,
  }) {
    return GenericLookupLocalDs(_db).upsertLookups(
      cacheKey: 'ADDITIONAL_CHARGES', rows: rows, idOf: (r) => r['id'] as String,
      labelOf: (r) => r['charge_name'] as String? ?? '',
      clientId: clientId, companyId: companyId,
    );
  }

  Future<void> cacheUsersForAutocomplete({
    required String clientId,
    required String companyId,
    required List<Map<String, dynamic>> rows,
  }) {
    return GenericLookupLocalDs(_db).upsertLookups(
      cacheKey: 'USERS', rows: rows, idOf: (r) => r['id'] as String,
      labelOf: (r) => r['full_name'] as String? ?? '',
      clientId: clientId, companyId: companyId,
    );
  }

  Future<void> cacheUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
    required Map<String, dynamic> row,
  }) {
    return GenericLookupLocalDs(_db).upsertLookups(
      cacheKey: 'USER_SALES_CONTROLS', rows: [row], idOf: (_) => userId,
      clientId: clientId, companyId: companyId,
    );
  }

  Future<void> cacheQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
    required Map<String, dynamic> row,
  }) {
    return GenericLookupLocalDs(_db).upsertLookups(
      cacheKey: 'QUICK_INVOICE_SETUP', rows: [row], idOf: (_) => userId,
      clientId: clientId, companyId: companyId,
    );
  }

  Future<void> cacheTaxGroups({
    required String clientId,
    required String companyId,
    required List<Map<String, dynamic>> rows,
  }) {
    return GenericLookupLocalDs(_db).upsertLookups(
      cacheKey: 'TAX_GROUPS', rows: rows, idOf: (r) => r['id'] as String,
      labelOf: (r) => r['group_name'] as String? ?? '',
      clientId: clientId, companyId: companyId,
    );
  }

  Future<void> cacheProductUoms({
    required String productId,
    required List<Map<String, dynamic>> rows,
  }) {
    return ProductUomLocalDs(_db).upsert(rows.map((r) => {...r, 'product_id': productId}).toList());
  }

  // ── Read — invoice documents ────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listInvoices({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? saleType,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final q = _db.select(_db.salesInvoicesCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.invoiceDate), (t) => OrderingTerm.desc(t.invoiceNo)]);
    if (status != null && status.isNotEmpty) q.where((t) => t.status.equals(status));
    if (saleType != null && saleType.isNotEmpty) q.where((t) => t.saleType.equals(saleType));
    final rows = await q.get();
    var result = rows.map(_headerToMap).toList();
    if (search != null && search.isNotEmpty) {
      final s = search.toLowerCase();
      result = result.where((r) =>
          (r['invoice_no'] as String).toLowerCase().contains(s) ||
          (r['party_name'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    return result.skip(offset).take(limit).toList();
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    String? invoiceDate,
  }) async {
    final q = _db.select(_db.salesInvoicesCache)
      ..where((t) => t.clientId.equals(clientId))
      ..where((t) => t.companyId.equals(companyId))
      ..where((t) => t.invoiceNo.equals(invoiceNo))
      ..where((t) => t.isDeleted.equals(false));
    if (invoiceDate != null && invoiceDate.isNotEmpty) {
      q.where((t) => t.invoiceDate.equals(invoiceDate));
    } else {
      q.orderBy([(t) => OrderingTerm.desc(t.invoiceDate)]);
    }
    q.limit(1);
    final row = await q.getSingleOrNull();
    return row == null ? null : _headerToMap(row);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final rows = await (_db.select(_db.salesInvoiceLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.invoiceNo.equals(invoiceNo))
          ..where((t) => t.invoiceDate.equals(invoiceDate))
          ..where((t) => t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.serialNo)]))
        .get();
    return rows.map(_lineToMap).toList();
  }

  // ── Write — from Maps (after remote fetch) ────────────────────────────────

  Future<void> cacheHeader(Map<String, dynamic> h) async {
    final location    = h['location'] as Map<String, dynamic>?;
    final customer     = h['customer'] as Map<String, dynamic>?;
    final salesPerson  = h['sales_person'] as Map<String, dynamic>?;
    final currency      = h['currency'] as Map<String, dynamic>?;
    await _db.into(_db.salesInvoicesCache).insertOnConflictUpdate(
          SalesInvoicesCacheCompanion.insert(
            clientId:            h['client_id'] as String,
            companyId:           h['company_id'] as String,
            locationId:          Value(h['location_id'] as String? ?? ''),
            locationName:        Value(location?['location_name'] as String? ?? ''),
            invoiceNo:           h['invoice_no'] as String,
            invoiceDate:         h['invoice_date'] as String,
            invoiceMode:         Value(h['invoice_mode'] as String? ?? 'DIRECT'),
            quotationNo:         Value(h['quotation_no'] as String? ?? ''),
            quotationDate:       Value(h['quotation_date'] as String? ?? ''),
            orderNo:             Value(h['order_no'] as String? ?? ''),
            orderDate:           Value(h['order_date'] as String? ?? ''),
            saleType:            Value(h['sale_type'] as String? ?? 'CASH'),
            customerId:          h['customer_id'] as String,
            customerCode:        Value(customer?['account_code'] as String? ?? ''),
            customerName:        Value(customer?['account_name'] as String? ?? ''),
            partyName:           Value(h['party_name'] as String? ?? ''),
            partyPhone:          Value(h['party_phone'] as String? ?? ''),
            partyAddress:        Value(h['party_address'] as String? ?? ''),
            salesPersonId:       Value(h['sales_person_id'] as String? ?? ''),
            salesPersonName:     Value(salesPerson?['full_name'] as String? ?? ''),
            invoiceCurrencyId:   h['invoice_currency_id'] as String,
            invoiceCurrencyCode: Value(currency?['currency_id'] as String? ?? ''),
            rateToBase:          Value((h['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal:         Value((h['rate_to_local'] as num? ?? 1).toDouble()),
            discountPercent:     Value((h['discount_percent'] as num? ?? 0).toDouble()),
            grossAmount:         Value((h['gross_amount'] as num? ?? 0).toDouble()),
            discountAmount:      Value((h['discount_amount'] as num? ?? 0).toDouble()),
            chargesAmount:       Value((h['charges_amount'] as num? ?? 0).toDouble()),
            taxAmount:           Value((h['tax_amount'] as num? ?? 0).toDouble()),
            grandTotal:          Value((h['grand_total'] as num? ?? 0).toDouble()),
            stockDispatchMode:   Value(h['stock_dispatch_mode'] as String? ?? 'IMMEDIATE'),
            cashCollectionMode:  Value(h['cash_collection_mode'] as String? ?? 'IMMEDIATE'),
            status:              Value(h['status'] as String? ?? 'DRAFT'),
            salesVoucherNo:      Value(h['sales_voucher_no'] as String? ?? ''),
            salesVoucherDate:    Value(h['sales_voucher_date'] as String? ?? ''),
            cosVoucherNo:        Value(h['cos_voucher_no'] as String? ?? ''),
            cosVoucherDate:      Value(h['cos_voucher_date'] as String? ?? ''),
            localReceiptVoucherNo:   Value(h['local_receipt_voucher_no'] as String? ?? ''),
            localReceiptVoucherDate: Value(h['local_receipt_voucher_date'] as String? ?? ''),
            baseReceiptVoucherNo:    Value(h['base_receipt_voucher_no'] as String? ?? ''),
            baseReceiptVoucherDate:  Value(h['base_receipt_voucher_date'] as String? ?? ''),
            collectedAmountLocal: Value((h['collected_amount_local'] as num?)?.toDouble()),
            collectedAmountBase:  Value((h['collected_amount_base'] as num?)?.toDouble()),
            cancellationReason:  Value(h['cancellation_reason'] as String? ?? ''),
            remarks:             Value(h['remarks'] as String? ?? ''),
            cachedAt:            Value(DateTime.now()),
          ),
        );
  }

  Future<void> cacheLines(
    String clientId, String companyId, String invoiceNo, String invoiceDate,
    List<Map<String, dynamic>> lines,
  ) async {
    await (_db.delete(_db.salesInvoiceLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.invoiceNo.equals(invoiceNo))
          ..where((t) => t.invoiceDate.equals(invoiceDate)))
        .go();
    for (final line in lines) {
      final product  = line['product'] as Map<String, dynamic>?;
      final uom        = line['uom'] as Map<String, dynamic>?;
      final taxGroup    = line['tax_group'] as Map<String, dynamic>?;
      final discountGiver = line['discount_giver'] as Map<String, dynamic>?;
      await _db.into(_db.salesInvoiceLinesCache).insert(
            SalesInvoiceLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              invoiceNo:           invoiceNo,
              invoiceDate:         invoiceDate,
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
              priceSource:         Value(line['price_source'] as String? ?? 'PRICE_MASTER'),
              priceOverrideReason: Value(line['price_override_reason'] as String? ?? ''),
              priceSourceEntryNo:  Value(line['price_source_entry_no'] as String? ?? ''),
              grossAmount:         Value((line['gross_amount'] as num? ?? 0).toDouble()),
              discountPercent:     Value((line['discount_percent'] as num? ?? 0).toDouble()),
              discountAmount:      Value((line['discount_amount'] as num? ?? 0).toDouble()),
              discountGivenBy:     Value(line['discount_given_by'] as String? ?? ''),
              discountGivenByName: Value(discountGiver?['full_name'] as String? ?? ''),
              taxGroupId:          Value(line['tax_group_id'] as String? ?? ''),
              taxGroupName:        Value(taxGroup?['group_name'] as String? ?? ''),
              taxAmount:           Value((line['tax_amount'] as num? ?? 0).toDouble()),
              finalAmount:         Value((line['final_amount'] as num? ?? 0).toDouble()),
              baseAmount:          Value((line['base_amount'] as num? ?? 0).toDouble()),
              localAmount:         Value((line['local_amount'] as num? ?? 0).toDouble()),
              sourceQuotationLineSerial: Value((line['source_quotation_line_serial'] as num?)?.toInt()),
              sourceOrderLineSerial:     Value((line['source_order_line_serial'] as num?)?.toInt()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(DateTime.now()),
            ),
          );
    }
  }

  // ── Write — from raw save-payload Maps (offline save path, Direct only) ───

  Future<void> cacheFromMaps(
    String effectiveInvoiceNo,
    Map<String, dynamic> headerMap,
    List<Map<String, dynamic>> lineMaps,
  ) async {
    final now         = DateTime.now();
    final clientId    = headerMap['client_id']  as String? ?? '';
    final companyId   = headerMap['company_id'] as String? ?? '';
    final invoiceDate = headerMap['invoice_date'] as String? ?? '';

    await _db.into(_db.salesInvoicesCache).insertOnConflictUpdate(
          SalesInvoicesCacheCompanion.insert(
            clientId:            clientId,
            companyId:           companyId,
            locationId:          Value(headerMap['location_id'] as String? ?? ''),
            invoiceNo:           effectiveInvoiceNo,
            invoiceDate:         invoiceDate,
            invoiceMode:         Value(headerMap['invoice_mode'] as String? ?? 'DIRECT'),
            saleType:            Value(headerMap['sale_type'] as String? ?? 'CASH'),
            customerId:          headerMap['customer_id'] as String? ?? '',
            partyName:           Value(headerMap['party_name'] as String? ?? ''),
            partyPhone:          Value(headerMap['party_phone'] as String? ?? ''),
            partyAddress:        Value(headerMap['party_address'] as String? ?? ''),
            salesPersonId:       Value(headerMap['sales_person_id'] as String? ?? ''),
            invoiceCurrencyId:   headerMap['invoice_currency_id'] as String? ?? '',
            rateToBase:          Value((headerMap['rate_to_base'] as num? ?? 1).toDouble()),
            rateToLocal:         Value((headerMap['rate_to_local'] as num? ?? 1).toDouble()),
            discountPercent:     Value((headerMap['discount_percent'] as num? ?? 0).toDouble()),
            grossAmount:         Value((headerMap['gross_amount'] as num? ?? 0).toDouble()),
            discountAmount:      Value((headerMap['discount_amount'] as num? ?? 0).toDouble()),
            chargesAmount:       Value((headerMap['charges_amount'] as num? ?? 0).toDouble()),
            taxAmount:           Value((headerMap['tax_amount'] as num? ?? 0).toDouble()),
            grandTotal:          Value((headerMap['grand_total'] as num? ?? 0).toDouble()),
            collectedAmountLocal: Value((headerMap['collected_amount_local'] as num?)?.toDouble()),
            collectedAmountBase:  Value((headerMap['collected_amount_base'] as num?)?.toDouble()),
            status:              const Value('DRAFT'),
            remarks:             Value(headerMap['remarks'] as String? ?? ''),
            isDeleted:           const Value(false),
            cachedAt:            Value(now),
          ),
        );

    await (_db.delete(_db.salesInvoiceLinesCache)
          ..where((t) => t.clientId.equals(clientId))
          ..where((t) => t.companyId.equals(companyId))
          ..where((t) => t.invoiceNo.equals(effectiveInvoiceNo))
          ..where((t) => t.invoiceDate.equals(invoiceDate)))
        .go();
    for (final line in lineMaps) {
      await _db.into(_db.salesInvoiceLinesCache).insert(
            SalesInvoiceLinesCacheCompanion.insert(
              clientId:            clientId,
              companyId:           companyId,
              invoiceNo:           effectiveInvoiceNo,
              invoiceDate:         invoiceDate,
              serialNo:            (line['serial_no'] as num? ?? 0).toInt(),
              productId:           line['product_id'] as String? ?? '',
              uomId:               line['uom_id'] as String? ?? '',
              uomConversionFactor: Value((line['uom_conversion_factor'] as num? ?? 1).toDouble()),
              qtyPack:             Value((line['qty_pack']  as num? ?? 0).toDouble()),
              qtyLoose:            Value((line['qty_loose'] as num? ?? 0).toDouble()),
              baseQty:             Value((line['base_qty']  as num? ?? 0).toDouble()),
              rate:                Value((line['rate'] as num? ?? 0).toDouble()),
              priceSource:         Value(line['price_source'] as String? ?? 'PRICE_MASTER'),
              priceOverrideReason: Value(line['price_override_reason'] as String? ?? ''),
              priceSourceEntryNo:  Value(line['price_source_entry_no'] as String? ?? ''),
              grossAmount:         Value((line['gross_amount'] as num? ?? 0).toDouble()),
              discountPercent:     Value((line['discount_percent'] as num? ?? 0).toDouble()),
              discountAmount:      Value((line['discount_amount'] as num? ?? 0).toDouble()),
              discountGivenBy:     Value(line['discount_given_by'] as String? ?? ''),
              taxGroupId:          Value(line['tax_group_id'] as String? ?? ''),
              taxAmount:           Value((line['tax_amount'] as num? ?? 0).toDouble()),
              finalAmount:         Value((line['final_amount'] as num? ?? 0).toDouble()),
              baseAmount:          Value((line['base_amount'] as num? ?? 0).toDouble()),
              localAmount:         Value((line['local_amount'] as num? ?? 0).toDouble()),
              remarks:             Value(line['remarks'] as String? ?? ''),
              cachedAt:            Value(now),
            ),
          );
    }
  }

  // ── Converters ────────────────────────────────────────────────────────────

  Map<String, dynamic> _headerToMap(SalesInvoiceCacheEntry r) => {
        'client_id':            r.clientId,
        'company_id':           r.companyId,
        'location_id':          r.locationId,
        'location':             {'location_name': r.locationName},
        'invoice_no':           r.invoiceNo,
        'invoice_date':         r.invoiceDate,
        'invoice_mode':         r.invoiceMode,
        'quotation_no':         r.quotationNo.isEmpty ? null : r.quotationNo,
        'quotation_date':       r.quotationDate.isEmpty ? null : r.quotationDate,
        'order_no':             r.orderNo.isEmpty ? null : r.orderNo,
        'order_date':           r.orderDate.isEmpty ? null : r.orderDate,
        'sale_type':            r.saleType,
        'customer_id':          r.customerId,
        'customer':             {'account_code': r.customerCode, 'account_name': r.customerName},
        'party_name':           r.partyName,
        'party_phone':          r.partyPhone,
        'party_address':        r.partyAddress,
        'sales_person_id':      r.salesPersonId,
        'sales_person':         {'full_name': r.salesPersonName},
        'invoice_currency_id':  r.invoiceCurrencyId,
        'currency':             {'currency_id': r.invoiceCurrencyCode},
        'rate_to_base':         r.rateToBase,
        'rate_to_local':        r.rateToLocal,
        'discount_percent':     r.discountPercent,
        'gross_amount':         r.grossAmount,
        'discount_amount':      r.discountAmount,
        'charges_amount':       r.chargesAmount,
        'tax_amount':           r.taxAmount,
        'grand_total':          r.grandTotal,
        'stock_dispatch_mode':  r.stockDispatchMode,
        'cash_collection_mode': r.cashCollectionMode,
        'status':               r.status,
        'sales_voucher_no':     r.salesVoucherNo.isEmpty ? null : r.salesVoucherNo,
        'cos_voucher_no':       r.cosVoucherNo.isEmpty ? null : r.cosVoucherNo,
        'local_receipt_voucher_no': r.localReceiptVoucherNo.isEmpty ? null : r.localReceiptVoucherNo,
        'base_receipt_voucher_no':  r.baseReceiptVoucherNo.isEmpty ? null : r.baseReceiptVoucherNo,
        'collected_amount_local': r.collectedAmountLocal,
        'collected_amount_base':  r.collectedAmountBase,
        'cancellation_reason':  r.cancellationReason,
        'remarks':              r.remarks,
      };

  Map<String, dynamic> _lineToMap(SalesInvoiceLineCacheEntry r) => {
        'serial_no':                    r.serialNo,
        'product_id':                   r.productId,
        'product':                      {'product_code': r.productCode, 'product_name': r.productName},
        'item_description':             r.itemDescription,
        'barcode':                      r.barcode,
        'uom_id':                       r.uomId,
        'uom':                          {'description': r.uomLabel},
        'uom_conversion_factor':        r.uomConversionFactor,
        'qty_pack':                     r.qtyPack,
        'qty_loose':                    r.qtyLoose,
        'base_qty':                     r.baseQty,
        'rate':                         r.rate,
        'price_source':                 r.priceSource,
        'price_override_reason':        r.priceOverrideReason,
        'price_source_entry_no':        r.priceSourceEntryNo.isEmpty ? null : r.priceSourceEntryNo,
        'gross_amount':                 r.grossAmount,
        'discount_percent':             r.discountPercent,
        'discount_amount':              r.discountAmount,
        'discount_given_by':            r.discountGivenBy.isEmpty ? null : r.discountGivenBy,
        'discount_giver':               {'full_name': r.discountGivenByName},
        'tax_group_id':                 r.taxGroupId,
        'tax_group':                    {'group_name': r.taxGroupName},
        'tax_amount':                   r.taxAmount,
        'final_amount':                 r.finalAmount,
        'base_amount':                  r.baseAmount,
        'local_amount':                 r.localAmount,
        'source_quotation_line_serial': r.sourceQuotationLineSerial,
        'source_order_line_serial':     r.sourceOrderLineSerial,
        'remarks':                      r.remarks,
      };
}

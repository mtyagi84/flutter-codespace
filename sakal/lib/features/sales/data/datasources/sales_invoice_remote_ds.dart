import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class SalesInvoiceRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name),'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'sales_person:rim_users!sales_person_id(full_name),'
      'currency:rim_currencies!invoice_currency_id(currency_id)';

  Future<List<Map<String, dynamic>>> listInvoices({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? saleType,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'invoice_date.desc,invoice_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (saleType != null && saleType.isNotEmpty) params['sale_type'] = 'eq.$saleType';
    if (search != null && search.isNotEmpty) {
      params['or'] = '(invoice_no.ilike.*$search*,party_name.ilike.*$search*)';
    }
    final res = await _dio.get('/rih_sales_invoices', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    String? invoiceDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'invoice_no': 'eq.$invoiceNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'invoice_date.desc',
      'limit':      '1',
    };
    if (invoiceDate != null && invoiceDate.isNotEmpty) params['invoice_date'] = 'eq.$invoiceDate';
    final res = await _dio.get('/rih_sales_invoices', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// The GL lines fn_post_voucher created for ONE of this invoice's own
  /// vouchers — same pattern as GRN's/Purchase Invoice's own "Posted
  /// Journal Entries" section. An approved invoice can have up to four
  /// separate vouchers (sales_voucher_no always, cos_voucher_no only when
  /// stock dispatches immediately, local/base receipt voucher numbers only
  /// when cash was collected at Approve time) — the caller fetches each
  /// one present on the header individually and renders one block per
  /// voucher, rather than this method trying to merge them into one query.
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) async {
    final res = await _dio.get('/rid_finance_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'trans_no':   'eq.$voucherNo',
      'trans_date': 'eq.$voucherDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,trans_no,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_sales_invoice_lines', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'invoice_no':  'eq.$invoiceNo',
      'invoice_date': 'eq.$invoiceDate',
      'is_deleted':  'eq.false',
      'select':      'serial_no,product_id,item_description,barcode,uom_id,uom_conversion_factor,'
          'qty_pack,qty_loose,base_qty,rate,price_source,price_override_reason,price_source_entry_no,'
          'gross_amount,discount_percent,discount_amount,discount_given_by,'
          'tax_group_id,tax_amount,final_amount,base_amount,local_amount,charge_amount,landed_amount,'
          'source_quotation_line_serial,source_order_line_serial,remarks,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name),'
          'discount_giver:rim_users!discount_given_by(full_name)',
      'order':       'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Previously-saved batch allocations for a DRAFT invoice being resumed
  /// — without this, reopening a DRAFT with a batch-tracked line loses its
  /// existing allocation entirely (candidates reload at zero every time).
  Future<List<Map<String, dynamic>>> getLineBatchAllocations({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_INVOICE', 'source_doc_no': 'eq.$invoiceNo', 'source_doc_date': 'eq.$invoiceDate',
      'select': 'line_serial,batch_no,expiry_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLineSerialAllocations({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_INVOICE', 'source_doc_no': 'eq.$invoiceNo', 'source_doc_date': 'eq.$invoiceDate',
      'select': 'line_serial,serial_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// This invoice's own saved charges — for resuming a DRAFT (DIRECT mode
  /// only reaches here with meaningful edit intent; AGAINST_QUOTATION/
  /// AGAINST_ORDER charges are read-only carry-forward but are still
  /// fetched the same way to redisplay).
  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_sales_invoice_charges', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'invoice_no':  'eq.$invoiceNo',
      'invoice_date': 'eq.$invoiceDate',
      'is_deleted':  'eq.false',
      'select':      'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,'
          'amount_or_percent,percent,amount,tax_amount,allocation_factor',
      'order':       'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_additional_charges', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'or':         '(applicable_on.eq.SALES,applicable_on.eq.BOTH)',
      'select':     '*',
      'order':      'sort_order.asc,charge_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Source document's own charges — used to prefill (AGAINST_QUOTATION/
  /// AGAINST_ORDER, read-only display) the invoice's Charges card.
  /// fn_save_sales_invoice ignores the client's own p_charges in these two
  /// modes and copies these rows verbatim server-side anyway, but the UI
  /// still needs to show the cashier what will be carried forward.
  Future<List<Map<String, dynamic>>> getQuotationCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    final res = await _dio.get('/rid_sales_quotation_charges', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'quotation_no':   'eq.$quotationNo',
      'quotation_date': 'eq.$quotationDate',
      'is_deleted':     'eq.false',
      'select':         'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,'
          'amount_or_percent,percent,amount,tax_amount,allocation_factor',
      'order':          'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getOrderCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rid_sales_order_charges', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,'
          'amount_or_percent,percent,amount,tax_amount,allocation_factor',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Manager Review — DRAFT invoices for a location ────────────────────────
  // Online-only screen; no local cache needed (see docs/screens/sales_invoice.md).

  Future<List<Map<String, dynamic>>> listDraftInvoicesForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) async {
    final res = await _dio.get('/rih_sales_invoices', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'status':      'eq.DRAFT',
      'is_deleted':  'eq.false',
      'select':      _headerSelect,
      'order':       'invoice_date.asc,invoice_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Live stock position for a product at a location — read-only preview,
  /// no new backend logic (fn_approve_sales_invoice's own
  /// fn_post_stock_movement call is the real, authoritative check).
  Future<Map<String, dynamic>?> getStockPreview({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'select': 'current_stock',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getBatchStockBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/v_batch_stock_balance', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'balance': 'gt.0',
      'order': 'expiry_date.asc.nullslast',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getSerialStockStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/v_serial_stock_status', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'status': 'eq.IN_STOCK',
      'order': 'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Against-Quotation / Against-Order pickers ─────────────────────────────
  // Plain status-filtered fetches, same shape as Sales Order's own
  // getConvertibleQuotations — the picker is only ever a UX pre-check, the
  // authoritative "already invoiced?" check is the row-locked NOT EXISTS
  // inside fn_save_sales_invoice. A quotation with converted_qty>0 on any
  // line (status PARTIALLY_CONVERTED/CONVERTED) already means an Order
  // exists against it, so it's excluded here — only the resulting Order
  // becomes pickable.

  Future<List<Map<String, dynamic>>> getInvoiceableQuotations({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'status':     'in.(APPROVED,SENT,ACCEPTED)',
      'select':     '*,customer:rim_accounts!customer_id(account_code,account_name)',
      'order':      'quotation_date.desc',
      'limit':      '200',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(quotation_no.ilike.*$search*,party_name.ilike.*$search*)';
    }
    final res = await _dio.get('/rih_sales_quotations', queryParameters: params);
    final quotations = List<Map<String, dynamic>>.from(res.data as List);
    if (quotations.isEmpty) return quotations;

    final already = await _alreadyInvoicedKeys(
      clientId: clientId, companyId: companyId, field: 'quotation',
    );
    return quotations.where((q) => !already.contains('${q['quotation_no']}|${q['quotation_date']}')).toList();
  }

  Future<List<Map<String, dynamic>>> getInvoiceableOrders({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'status':     'eq.APPROVED',
      'select':     '*,customer:rim_accounts!customer_id(account_code,account_name)',
      'order':      'order_date.desc',
      'limit':      '200',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(order_no.ilike.*$search*,customer_po_ref.ilike.*$search*)';
    }
    final res = await _dio.get('/rih_sales_orders', queryParameters: params);
    final orders = List<Map<String, dynamic>>.from(res.data as List);
    if (orders.isEmpty) return orders;

    final already = await _alreadyInvoicedKeys(
      clientId: clientId, companyId: companyId, field: 'order',
    );
    return orders.where((o) => !already.contains('${o['order_no']}|${o['order_date']}')).toList();
  }

  Future<Set<String>> _alreadyInvoicedKeys({
    required String clientId,
    required String companyId,
    required String field, // 'quotation' or 'order'
  }) async {
    final res = await _dio.get('/rih_sales_invoices', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'status':     'neq.CANCELLED',
      '${field}_no': 'not.is.null',
      'select':     '${field}_no,${field}_date',
    });
    return {
      for (final e in (res.data as List))
        '${(e as Map<String, dynamic>)['${field}_no']}|${e['${field}_date']}',
    };
  }

  Future<Map<String, dynamic>?> getQuotationHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    final res = await _dio.get('/rih_sales_quotations', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'quotation_no':   'eq.$quotationNo',
      'quotation_date': 'eq.$quotationDate',
      'select':         '*,customer:rim_accounts!customer_id(account_code,account_name),'
          'currency:rim_currencies!quotation_currency_id(currency_id)',
      'limit':          '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getQuotationLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) async {
    final res = await _dio.get('/rid_sales_quotation_lines', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'quotation_no':   'eq.$quotationNo',
      'quotation_date': 'eq.$quotationDate',
      'is_deleted':     'eq.false',
      'select':         'serial_no,product_id,item_description,barcode,uom_id,uom_conversion_factor,'
          'base_qty,rate,discount_percent,discount_amount,'
          'tax_group_id,tax_amount,final_amount,base_amount,local_amount,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':          'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getOrderHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rih_sales_orders', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'select':     '*,customer:rim_accounts!customer_id(account_code,account_name),'
          'currency:rim_currencies!order_currency_id(currency_id)',
      'limit':      '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getOrderLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rid_sales_order_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,item_description,barcode,uom_id,uom_conversion_factor,'
          'base_qty,rate,discount_percent,discount_amount,'
          'tax_group_id,tax_amount,final_amount,base_amount,local_amount,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Direct mode: price/discount governance ───────────────────────────────

  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String customerId,
    required String asOfDate,
    required String currencyCode,
  }) async {
    final res = await _dio.post('/rpc/fn_get_active_price', data: {
      'p_client_id':       clientId,
      'p_company_id':      companyId,
      'p_location_id':     locationId,
      'p_product_id':      productId,
      'p_uom_id':          uomId,
      'p_customer_id':     customerId,
      'p_as_of_date':      asOfDate,
      'p_target_currency': currencyCode,
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<Map<String, dynamic>?> getUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    final res = await _dio.get('/ric_user_sales_controls', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'user_id':    'eq.$userId',
      'is_deleted': 'eq.false',
      'select':     'can_override_price,can_give_discount,max_discount_percent,can_view_cost_price',
      'limit':      '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// A missing row means this user has no Quick Invoice access at all —
  /// Cash-type sales are blocked entirely; Credit sales don't need one.
  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    final res = await _dio.get('/ric_user_quick_invoice_setup', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'user_id':    'eq.$userId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     '*,'
          'location:ric_locations!location_id(location_name),'
          'cash_customer:rim_accounts!cash_customer_id(account_code,account_name),'
          'default_sales_person:rim_users!default_sales_person_id(full_name)',
      'limit':      '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'select': 'current_stock,cost_price,cost_price_specific',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// Verifies a supervisor's credentials + their own discount eligibility
  /// in one atomic server-side call — never a client-side-only check.
  /// Returns the supervisor's {user_id, full_name} on success; throws
  /// (DioException) on invalid credentials / insufficient eligibility.
  Future<Map<String, dynamic>> verifyDiscountOverride({
    required String clientId,
    required String companyId,
    required String username,
    required String password,
    required double requestedDiscountPercent,
  }) async {
    final res = await _dio.post('/rpc/fn_verify_discount_override', data: {
      'p_client_id': clientId,
      'p_company_id': companyId,
      'p_username': username,
      'p_password': password,
      'p_requested_discount_percent': requestedDiscountPercent,
    });
    final list = res.data as List;
    return list.first as Map<String, dynamic>;
  }

  // ── Shared pickers (same shape as Sales Order) ────────────────────────────

  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId}) async {
    final res = await _dio.get('/rim_accounts', queryParameters: {
      'id':     'eq.$customerId',
      'select': 'id,account_code,account_name,credit_limit,credit_days,is_credit_blocked,'
          'phone,email,address_line1,address_line2,'
          'rim_currencies!account_currency_id(currency_id)',
      'limit':  '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_users', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'id,full_name',
      'order':      'full_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,product_code,product_name,base_uom_id,tracking_type,sales_tax_group_id,'
          'cost_currency_id,'
          'uom:rim_common_masters!base_uom_id(description)',
      'order':      'product_code.asc',
      'limit':      '500',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(product_code.ilike.*$search*,product_name.ilike.*$search*)';
    }
    final res = await _dio.get('/rim_products', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'barcode':    'eq.$code',
      'select':     'uom_id,conversion_factor,'
          'uom:rim_common_masters!uom_id(description),'
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,'
          'tracking_type,sales_tax_group_id,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isNotEmpty) {
      final row = list.first as Map<String, dynamic>;
      final product = row['product'] as Map<String, dynamic>?;
      if (product != null && product['is_deleted'] != true && product['is_active'] != false) {
        final uom = row['uom'] as Map<String, dynamic>?;
        return {
          ...product,
          'matched_uom_id': row['uom_id'],
          'matched_uom_conversion_factor': row['conversion_factor'],
          'matched_uom_label': uom?['description'],
        };
      }
    }

    if (!tryPartNumber) return null;

    final pRes = await _dio.get('/rim_products', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'part_number': 'eq.$code',
      'is_deleted':  'eq.false',
      'is_active':   'eq.true',
      'select':      'id,product_code,product_name,base_uom_id,tracking_type,sales_tax_group_id,'
          'uom:rim_common_masters!base_uom_id(description)',
      'limit':       '1',
    });
    final pList = pRes.data as List;
    if (pList.isEmpty) return null;
    final product = pList.first as Map<String, dynamic>;
    final uom = product['uom'] as Map<String, dynamic>?;
    return {
      ...product,
      'matched_uom_label': uom?['description'],
    };
  }

  // Not currently called by the entry screen (which defaults UOM from
  // product['base_uom_id'] directly and only overrides via a barcode
  // match) — kept correct anyway in case it's ever wired to a real
  // dropdown later. See price_master_remote_ds.dart's getProductUoms for
  // the full writeup of why the fallback below is needed: rim_product_uom
  // only holds ADDITIONAL pack sizes, never auto-populated for a
  // product's own base UOM, so a product can have zero rows here despite
  // a perfectly valid base_uom_id.
  Future<List<Map<String, dynamic>>> getProductUoms(String productId) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'product_id': 'eq.$productId',
      'select':     'uom_id,conversion_factor,is_base_uom,barcode,'
          'uom:rim_common_masters!uom_id(description)',
      'order':      'is_base_uom.desc',
    });
    final rows = List<Map<String, dynamic>>.from(res.data as List);
    if (rows.isNotEmpty) return rows;

    final productRes = await _dio.get('/rim_products', queryParameters: {
      'id':     'eq.$productId',
      'select': 'base_uom_id,uom:rim_common_masters!base_uom_id(description)',
      'limit':  '1',
    });
    final productList = productRes.data as List;
    if (productList.isEmpty) return [];
    final product = productList.first as Map<String, dynamic>;
    final baseUomId = product['base_uom_id'] as String?;
    if (baseUomId == null) return [];
    return [
      {
        'uom_id': baseUomId,
        'conversion_factor': 1,
        'is_base_uom': true,
        'barcode': null,
        'uom': product['uom'],
      },
    ];
  }

  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_groups', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'or':         '(applicable_on.eq.SALES,applicable_on.eq.BOTH)',
      'select':     'id,group_code,group_name',
      'order':      'group_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) async {
    if (groupIds.isEmpty) return {};
    final res = await _dio.get('/rim_tax_group_members', queryParameters: {
      'tax_group_id': 'in.(${groupIds.join(',')})',
      'select':       'tax_group_id,tax_id',
    });
    final result = <String, List<String>>{};
    for (final e in res.data as List) {
      final m = e as Map<String, dynamic>;
      result.putIfAbsent(m['tax_group_id'] as String, () => []).add(m['tax_id'] as String);
    }
    return result;
  }

  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) async {
    if (taxIds.isEmpty) return {};
    final res = await _dio.get('/rim_tax_rates', queryParameters: {
      'tax_id':     'in.(${taxIds.join(',')})',
      'rate_label': 'eq.STANDARD',
      'is_active':  'eq.true',
      'select':     'tax_id,rate,effective_from,effective_to',
      'order':      'effective_from.desc',
    });
    final asOf   = DateTime.tryParse(asOfDate) ?? DateTime.now();
    final result = <String, double>{};
    for (final e in res.data as List) {
      final m = e as Map<String, dynamic>;
      final taxId = m['tax_id'] as String;
      if (result.containsKey(taxId)) continue;
      final from = DateTime.tryParse(m['effective_from'] as String? ?? '');
      final to   = m['effective_to'] != null ? DateTime.tryParse(m['effective_to'] as String) : null;
      if (from != null && !asOf.isBefore(from) && (to == null || !asOf.isAfter(to))) {
        result[taxId] = (m['rate'] as num).toDouble();
      }
    }
    return result;
  }

  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) async {
    try {
      final res = await _dio.post('/rpc/fn_get_exchange_rate', data: {
        'p_company_id':    companyId,
        'p_location_id':   locationId,
        'p_from_currency': fromCurrency,
        'p_to_currency':   toCurrency,
        'p_rate_date':     rateDate,
        'p_rate_type':     'SELLING',
      });
      return (res.data as num?)?.toDouble();
    } on DioException {
      return null;
    }
  }

  // ── Save / Approve / Cancel ────────────────────────────────────────────────

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_sales_invoice', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_charges': charges,
      'p_batches': batches,
      'p_serials': serials,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_sales_invoice', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_invoice_no':  invoiceNo,
      'p_invoice_date': invoiceDate,
      'p_approved_by': approvedBy,
    });
  }

  Future<void> cancel({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String reason,
    required String userId,
  }) async {
    await _dio.post('/rpc/fn_cancel_sales_invoice', data: {
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': invoiceDate,
      'p_reason':     reason,
      'p_user_id':    userId,
    });
  }
}

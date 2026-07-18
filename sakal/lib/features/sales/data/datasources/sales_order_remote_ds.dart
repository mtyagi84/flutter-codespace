import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class SalesOrderRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name),'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'sales_person:rim_users!sales_person_id(full_name),'
      'currency:rim_currencies!order_currency_id(currency_id),'
      'payment_term:rim_payment_terms!payment_term_id(term_name,description),'
      'incoterm:rim_common_masters!incoterm_id(description)';

  Future<List<Map<String, dynamic>>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? orderMode,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'order_date.desc,order_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (orderMode != null && orderMode.isNotEmpty) params['order_mode'] = 'eq.$orderMode';
    if (search != null && search.isNotEmpty) {
      params['or'] = '(order_no.ilike.*$search*,customer_po_ref.ilike.*$search*)';
    }
    final res = await _dio.get('/rih_sales_orders', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'order_date.desc',
      'limit':      '1',
    };
    if (orderDate != null && orderDate.isNotEmpty) params['order_date'] = 'eq.$orderDate';
    final res = await _dio.get('/rih_sales_orders', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
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
          'qty_pack,qty_loose,base_qty,rate,price_source,price_override_reason,price_source_entry_no,'
          'gross_amount,discount_percent,discount_amount,'
          'tax_group_id,tax_amount,final_amount,base_amount,local_amount,charge_amount,landed_amount,'
          'delivered_qty,source_quotation_line_serial,remarks,'
          'product:rim_products!product_id(product_code,product_name,sales_tax_group_id),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getCharges({
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

  // ── Against-Quotation mode: source quotation lookup ──────────────────────

  /// Quotations eligible to be converted right now: convertible status,
  /// not expired, and (checked client-side against each line's own
  /// converted_qty) has something left to convert.
  Future<List<Map<String, dynamic>>> getConvertibleQuotations({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'status':     'in.(APPROVED,SENT,ACCEPTED,PARTIALLY_CONVERTED)',
      'select':     '*,customer:rim_accounts!customer_id(account_code,account_name)',
      'order':      'quotation_date.desc',
      'limit':      '200',
    };
    if (search != null && search.isNotEmpty) {
      params['or'] = '(quotation_no.ilike.*$search*,party_name.ilike.*$search*)';
    }
    final res = await _dio.get('/rih_sales_quotations', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Single quotation header fetch (distinct from getConvertibleQuotations'
  /// list) — used when an entry screen is opened straight to a known
  /// quotation_no/date via navigation extras, not via the picker.
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
      'select':         '*,location:ric_locations!location_id(location_name),'
          'customer:rim_accounts!customer_id(account_code,account_name),'
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
          'base_qty,converted_qty,rate,discount_percent,discount_amount,'
          'tax_group_id,tax_amount,final_amount,base_amount,local_amount,'
          'product:rim_products!product_id(product_code,product_name),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':          'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<void> convertProspectToCustomer({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required Map<String, dynamic> account,
    String? notes,
    required String userId,
  }) async {
    await _dio.post('/rpc/fn_convert_prospect_to_customer', data: {
      'p_client_id':      clientId,
      'p_company_id':     companyId,
      'p_quotation_no':   quotationNo,
      'p_quotation_date': quotationDate,
      'p_account':        account,
      'p_notes':          notes,
      'p_user_id':        userId,
    });
  }

  // ── Direct mode: price/discount governance ───────────────────────────────

  /// fn_get_active_price (086) converts internally TO [currencyCode] —
  /// never assume a Price Master batch's own currency already matches
  /// the caller's document currency. Returns both the converted
  /// selling_price (what the caller uses) and native_selling_price/
  /// price_currency_code/conversion_rate for audit/display.
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

  Future<List<Map<String, dynamic>>> getPaymentTerms({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_payment_terms', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,term_code,term_name,description',
      'order':      'term_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Incoterm reuses the generic common-masters mechanism (086) — same
  /// two-step type_key lookup as PriceMasterRemoteDs.getReasons() /
  /// Stock Adjustment's own getReasons().
  Future<List<Map<String, dynamic>>> getIncoterms({
    required String clientId,
    required String companyId,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.INCOTERM',
      'select':   'id',
      'limit':    '1',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) return [];
    final typeId = (typeList.first as Map<String, dynamic>)['id'] as String;
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'type_id':    'eq.$typeId',
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'select':     'id,description',
      'order':      'sort_order.asc,description.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// The acting user's Sales Controls (price override / discount cap /
  /// cost visibility). No row = every field defaults false/null client-
  /// side too — mirrored exactly from the server's own coalesce-based
  /// resolution in fn_save_sales_order, never assumed permissive.
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

  // ── Shared pickers (same shape as Sales Quotation) ───────────────────────

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

  /// Barcode-first / part-number-fallback product lookup for Direct-mode
  /// line entry — same shape as PriceMasterRemoteDs.getProductByCode().
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

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_sales_order', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_charges': charges,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_sales_order', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_order_no':    orderNo,
      'p_order_date':  orderDate,
      'p_approved_by': approvedBy,
    });
  }

  Future<void> cancel({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String reason,
    required String userId,
  }) async {
    await _dio.post('/rpc/fn_cancel_sales_order', data: {
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_order_no':   orderNo,
      'p_order_date': orderDate,
      'p_reason':     reason,
      'p_user_id':    userId,
    });
  }
}

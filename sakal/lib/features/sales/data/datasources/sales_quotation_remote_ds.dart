import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class SalesQuotationRemoteDs {
  final Dio _dio = DioClient.instance;

  // Real gap found live: Sales Quotation predates Price Master (migration
  // 081 vs 083) and was never wired to it -- every line's rate had to be
  // typed manually. Same fn_get_active_price call Sales Order/Invoice
  // already use (086's currency-aware version).
  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String? customerId,
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

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name),'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'sales_person:rim_users!sales_person_id(full_name),'
      'currency:rim_currencies!quotation_currency_id(currency_id)';

  Future<List<Map<String, dynamic>>> listQuotations({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'quotation_date.desc,quotation_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['quotation_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_sales_quotations', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    String? quotationDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'quotation_no':  'eq.$quotationNo',
      'is_deleted':    'eq.false',
      'select':        _headerSelect,
      'order':         'quotation_date.desc',
      'limit':         '1',
    };
    if (quotationDate != null && quotationDate.isNotEmpty) params['quotation_date'] = 'eq.$quotationDate';
    final res = await _dio.get('/rih_sales_quotations', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
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
          'qty_pack,qty_loose,base_qty,rate,gross_amount,discount_percent,discount_amount,'
          'tax_group_id,tax_amount,final_amount,base_amount,local_amount,charge_amount,landed_amount,'
          'converted_qty,remarks,'
          'product:rim_products!product_id(product_code,product_name,sales_tax_group_id),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':          'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getCharges({
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

  /// Fetched on demand when a customer is selected — deliberately NOT part
  /// of the shared accountsProvider select (that provider is reused by
  /// Finance Voucher/PO and doesn't need credit fields), so a dedicated
  /// lightweight lookup here instead of widening a shared provider.
  Future<Map<String, dynamic>?> getCustomerDetails({
    required String customerId,
  }) async {
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

  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) async {
    final res = await _dio.get('/rim_product_uom', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'barcode':    'eq.$barcode',
      'select':     'uom_id,conversion_factor,'
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,tracking_type,'
          'sales_tax_group_id,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return null;
    final row = list.first as Map<String, dynamic>;
    final product = row['product'] as Map<String, dynamic>?;
    if (product == null || product['is_deleted'] == true || product['is_active'] == false) return null;
    return {
      ...product,
      'matched_uom_id': row['uom_id'],
      'matched_uom_conversion_factor': row['conversion_factor'],
    };
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

  /// tax_id → current STANDARD rate% as of [asOfDate].
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
      if (result.containsKey(taxId)) continue; // already took the most recent effective row
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

  /// Uses the SELLING rate — converting TO the customer's quotation
  /// currency, per the Exchange Rate screen's documented rule (converting
  /// TO local/customer currency uses SELLING, converting FROM uses BUYING).
  /// Returns null (never throws) if no rate is configured — the entry
  /// screen falls back to 1 and the user can correct it manually.
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

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_sales_quotation', data: {
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
    required String quotationNo,
    required String quotationDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_sales_quotation', data: {
      'p_client_id':      clientId,
      'p_company_id':     companyId,
      'p_quotation_no':   quotationNo,
      'p_quotation_date': quotationDate,
      'p_approved_by':    approvedBy,
    });
  }

  Future<void> updateStatus({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
    required String newStatus,
    required String userId,
  }) async {
    await _dio.post('/rpc/fn_update_sales_quotation_status', data: {
      'p_client_id':      clientId,
      'p_company_id':     companyId,
      'p_quotation_no':   quotationNo,
      'p_quotation_date': quotationDate,
      'p_new_status':     newStatus,
      'p_user_id':        userId,
    });
  }
}

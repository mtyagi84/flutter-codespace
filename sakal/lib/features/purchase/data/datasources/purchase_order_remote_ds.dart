import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/po_charge_line_model.dart';
import '../models/po_payment_term_model.dart';
import '../models/purchase_order_line_model.dart';
import '../models/purchase_order_model.dart';

class PurchaseOrderRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'supplier:rim_accounts!supplier_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!po_currency_id(currency_id),'
      'buyer:rim_users!buyer_id(full_name)';

  // ── List ───────────────────────────────────────────────────────────────────

  Future<List<PurchaseOrderModel>> listOrders({
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
      'order':      'order_date.desc,order_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['order_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_purchase_orders', queryParameters: params);
    return (res.data as List)
        .map((e) => PurchaseOrderModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Header / Lines / Charges ─────────────────────────────────────────────────

  Future<PurchaseOrderModel?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate, // if known, filter precisely; otherwise latest by order_no
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
    final res = await _dio.get('/rih_purchase_orders', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? PurchaseOrderModel.fromJson(list.first as Map<String, dynamic>) : null;
  }

  Future<List<PurchaseOrderLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rid_purchase_order_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     '*,'
          'product:rim_products!product_id(product_code,product_name),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':      'serial_no.asc',
    });
    return (res.data as List)
        .map((e) => PurchaseOrderLineModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PoChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rid_po_charge_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     '*',
      'order':      'serial_no.asc',
    });
    return (res.data as List)
        .map((e) => PoChargeLineModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PoPaymentTermModel>> getPaymentTerms({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    final res = await _dio.get('/rid_po_payment_terms', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'order_no':   'eq.$orderNo',
      'order_date': 'eq.$orderDate',
      'is_deleted': 'eq.false',
      'select':     '*',
      'order':      'serial_no.asc',
    });
    return (res.data as List)
        .map((e) => PoPaymentTermModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Save / Approve ────────────────────────────────────────────────────────────

  /// Returns the assigned order_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required List<Map<String, dynamic>> paymentTerms,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_purchase_order', data: {
      'p_header':         header,
      'p_lines':          lines,
      'p_charges':        charges,
      'p_payment_terms':  paymentTerms,
      'p_user_id':        userId,
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
    await _dio.post('/rpc/fn_approve_purchase_order', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_order_no':    orderNo,
      'p_order_date':  orderDate,
      'p_approved_by': approvedBy,
    });
  }

  // ── Reference data ────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_additional_charges', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'or':         '(applicable_on.eq.PURCHASE,applicable_on.eq.BOTH)',
      'select':     '*',
      'order':      'sort_order.asc,charge_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Products for the line-item picker — includes purchase-relevant fields
  /// for auto-defaulting rate/tax/uom when a product is selected.
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
      'select':     'id,product_code,product_name,base_uom_id,'
          'last_purchase_cost,standard_cost,purchase_tax_group_id,'
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

  /// Barcode-based product+UOM lookup. Matches rim_product_uom.barcode
  /// exactly — each pack level (Piece, Carton…) has its own barcode — so a
  /// scanned/typed barcode fixes product + UOM + conversion_factor together
  /// in one step, unlike the free-text product-code search which leaves the
  /// conversion factor for the user to type.
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
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,'
          'last_purchase_cost,standard_cost,purchase_tax_group_id,is_active,is_deleted)',
      'limit':      '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return null;
    final row     = list.first as Map<String, dynamic>;
    final product = row['product'] as Map<String, dynamic>?;
    if (product == null || product['is_deleted'] == true || product['is_active'] == false) return null;
    return {
      ...product,
      'matched_uom_id': row['uom_id'],
      'matched_uom_conversion_factor': row['conversion_factor'],
    };
  }

  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.$typeKey',
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

  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_tax_groups', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'is_active':  'eq.true',
      'or':         '(applicable_on.eq.PURCHASE,applicable_on.eq.BOTH)',
      'select':     'id,group_code,group_name',
      'order':      'group_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// tax_group_id → [tax_id, ...] for every member of the given groups.
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
      'tax_id':      'in.(${taxIds.join(',')})',
      'rate_label':  'eq.STANDARD',
      'is_active':   'eq.true',
      'select':      'tax_id,rate,effective_from,effective_to',
      'order':       'effective_from.desc',
    });
    final asOf   = DateTime.tryParse(asOfDate) ?? DateTime.now();
    final result = <String, double>{};
    for (final e in res.data as List) {
      final m    = e as Map<String, dynamic>;
      final taxId = m['tax_id'] as String;
      if (result.containsKey(taxId)) continue; // already found the most recent match
      final from = DateTime.tryParse(m['effective_from'] as String? ?? '');
      final to   = m['effective_to'] != null ? DateTime.tryParse(m['effective_to'] as String) : null;
      if (from == null || from.isAfter(asOf)) continue;
      if (to != null && to.isBefore(asOf)) continue;
      result[taxId] = (m['rate'] as num).toDouble();
    }
    return result;
  }

  /// Stock snapshot for the "why was this PO raised" audit fields.
  Future<Map<String, double>> getProductStockSnapshot({
    required String productId,
    required String locationId,
  }) async {
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'product_id':  'eq.$productId',
      'location_id': 'eq.$locationId',
      'select':      'current_stock,reorder_level',
      'limit':       '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return {'current_stock': 0, 'reorder_level': 0};
    final m = list.first as Map<String, dynamic>;
    return {
      'current_stock':  (m['current_stock']  as num? ?? 0).toDouble(),
      'reorder_level':  (m['reorder_level']  as num? ?? 0).toDouble(),
    };
  }

  Future<List<Map<String, dynamic>>> getUsers({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_users', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select':     'id,full_name',
      'order':      'full_name.asc',
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
        'p_rate_type':     'MID',
      });
      return (res.data as num?)?.toDouble();
    } on DioException {
      return null;
    }
  }
}

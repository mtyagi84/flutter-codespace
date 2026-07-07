import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class StockTransferRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'from_location:ric_locations!from_location_id(location_name),'
      'to_location:ric_locations!to_location_id(location_name)';

  Future<List<Map<String, dynamic>>> listTransfers({
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
      'order':      'transfer_date.desc,transfer_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['transfer_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_stock_transfers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String transferNo,
    String? transferDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'transfer_no': 'eq.$transferNo',
      'is_deleted':  'eq.false',
      'select':      _headerSelect,
      'order':       'transfer_date.desc',
      'limit':       '1',
    };
    if (transferDate != null && transferDate.isNotEmpty) params['transfer_date'] = 'eq.$transferDate';
    final res = await _dio.get('/rih_stock_transfers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) async {
    final res = await _dio.get('/rid_stock_transfer_lines', queryParameters: {
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'transfer_no':   'eq.$transferNo',
      'transfer_date': 'eq.$transferDate',
      'is_deleted':    'eq.false',
      'select':        'serial_no,source_request_no,source_request_date,source_request_line_serial,'
          'product_id,uom_id,uom_conversion_factor,qty_pack,qty_loose,base_qty,cost_price,sales_price,charge_amount,remarks,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':         'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
  }) async {
    final res = await _dio.get('/rid_stock_transfer_charge_lines', queryParameters: {
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'transfer_no':   'eq.$transferNo',
      'transfer_date': 'eq.$transferDate',
      'is_deleted':    'eq.false',
      'select':        'serial_no,charge_id,charge_name,nature,gl_account_id,amount_or_percent,percent,amount',
      'order':         'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLocations({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/ric_locations', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active':  'eq.true',
      'is_deleted': 'eq.false',
      'select':     'id,location_name,group_id',
      'order':      'location_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Used only to pre-emptively show/hide the Sales Price field client-side
  /// (the same From-group != To-group + INTER_ENTITY test as the server) —
  /// fn_approve_stock_transfer remains the sole source of truth at Approve.
  Future<String> getInterLocationModel({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/ric_companies', queryParameters: {
      'id': 'eq.$companyId', 'select': 'inter_location_model', 'limit': '1',
    });
    final list = res.data as List;
    if (list.isEmpty) return 'SIMPLE';
    return (list.first as Map<String, dynamic>)['inter_location_model'] as String? ?? 'SIMPLE';
  }

  /// Approved or partially-transferred requests at this From location —
  /// the picker for against_request transfers.
  Future<List<Map<String, dynamic>>> getFulfillableRequests({
    required String clientId,
    required String companyId,
    required String fromLocationId,
  }) async {
    final res = await _dio.get('/rih_stock_transfer_requests', queryParameters: {
      'client_id':        'eq.$clientId',
      'company_id':       'eq.$companyId',
      'from_location_id': 'eq.$fromLocationId',
      'status':           'in.(APPROVED,PARTIALLY_TRANSFERRED)',
      'is_deleted':       'eq.false',
      'select':           '*,to_location:ric_locations!to_location_id(location_name)',
      'order':            'request_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getRequestLines({
    required String clientId,
    required String companyId,
    required String requestNo,
    required String requestDate,
  }) async {
    final res = await _dio.get('/rid_stock_transfer_request_lines', queryParameters: {
      'client_id':    'eq.$clientId',
      'company_id':   'eq.$companyId',
      'request_no':   'eq.$requestNo',
      'request_date': 'eq.$requestDate',
      'is_deleted':   'eq.false',
      'select':       'serial_no,product_id,uom_id,uom_conversion_factor,base_qty,transferred_qty,barcode,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':        'serial_no.asc',
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
      'select':     'id,product_code,product_name,base_uom_id,tracking_type,'
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

  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_additional_charges', queryParameters: {
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'is_active':     'eq.true',
      'is_deleted':    'eq.false',
      'applicable_on': 'in.(TRANSFER,BOTH)',
      'select':        'id,charge_code,charge_name,nature,default_gl_account_id,amount_or_percent,default_percent,default_amount',
      'order':         'sort_order.asc,charge_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Every batch with a positive balance for this product/location — the
  /// picker's candidate list for a batch-tracked transfer line (stock is
  /// leaving FROM's own current stock, same model as Material Issue).
  Future<List<Map<String, dynamic>>> getAvailableBatches({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/v_batch_stock_balance', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'balance': 'gt.0',
      'select': 'batch_no,expiry_date,balance',
      'order': 'batch_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Every serial currently IN_STOCK for this product/location.
  Future<List<Map<String, dynamic>>> getAvailableSerials({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) async {
    final res = await _dio.get('/v_serial_stock_status', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId',
      'status': 'eq.IN_STOCK',
      'select': 'serial_no,status',
      'order': 'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getTransferLineBatches({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_TRANSFER', 'source_doc_no': 'eq.$transferNo', 'source_doc_date': 'eq.$transferDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'batch_no,expiry_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getTransferLineSerials({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_TRANSFER', 'source_doc_no': 'eq.$transferNo', 'source_doc_date': 'eq.$transferDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'serial_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// FROM location's current moving-average cost per product — display-only
  /// reference so the user can set a sensible sales_price margin on an
  /// INTER_ENTITY line; fn_approve_stock_transfer resolves the authoritative
  /// cost_price itself at Approve time regardless of what this shows.
  Future<Map<String, num>> getCostPrices({
    required String clientId,
    required String companyId,
    required String locationId,
    required List<String> productIds,
  }) async {
    if (productIds.isEmpty) return {};
    final res = await _dio.get('/rim_product_location', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId',
      'product_id': 'in.(${productIds.join(',')})',
      'select': 'product_id,cost_price',
    });
    final list = List<Map<String, dynamic>>.from(res.data as List);
    return { for (final r in list) r['product_id'] as String: (r['cost_price'] as num? ?? 0) };
  }

  /// Batches/serials the source transfer line itself dispatched — used by
  /// Stock Receipt, not by this screen, but kept here since it reads the
  /// same rid_transaction_line_batches/serials table this module owns.
  Future<List<Map<String, dynamic>>> getDispatchedBatches({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'source_doc_type': 'eq.STOCK_TRANSFER',
      'source_doc_no':   'eq.$transferNo',
      'source_doc_date': 'eq.$transferDate',
      'line_serial':     'eq.$lineSerial',
      'select':          'batch_no,expiry_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getDispatchedSerials({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required int lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'source_doc_type': 'eq.STOCK_TRANSFER',
      'source_doc_no':   'eq.$transferNo',
      'source_doc_date': 'eq.$transferDate',
      'line_serial':     'eq.$lineSerial',
      'select':          'serial_no',
    });
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
          'product:rim_products!product_id(id,product_code,product_name,base_uom_id,tracking_type,is_active,is_deleted)',
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

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_stock_transfer', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_batches': batches,
      'p_serials': serials,
      'p_charges': charges,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String transferNo,
    required String transferDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_stock_transfer', data: {
      'p_client_id':    clientId,
      'p_company_id':   companyId,
      'p_transfer_no':  transferNo,
      'p_transfer_date': transferDate,
      'p_approved_by':  approvedBy,
    });
  }

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String transferNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.STOCK_TRANSFER',
      'source_doc_no':   'eq.$transferNo',
      'is_deleted':      'eq.false',
      'select':          'trans_no,trans_date,voucher_type_code',
      'order':           'trans_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

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
      'select':     'serial_no,account_id,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}

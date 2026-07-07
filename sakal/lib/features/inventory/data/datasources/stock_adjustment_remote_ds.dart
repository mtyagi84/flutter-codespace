import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class StockAdjustmentRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name),'
      'reason:rim_common_masters!reason_id(description)';

  Future<List<Map<String, dynamic>>> listAdjustments({
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
      'order':      'adjustment_date.desc,adjustment_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['adjustment_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_stock_adjustment_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    String? adjustmentDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':     'eq.$clientId',
      'company_id':    'eq.$companyId',
      'adjustment_no': 'eq.$adjustmentNo',
      'is_deleted':    'eq.false',
      'select':        _headerSelect,
      'order':         'adjustment_date.desc',
      'limit':         '1',
    };
    if (adjustmentDate != null && adjustmentDate.isNotEmpty) params['adjustment_date'] = 'eq.$adjustmentDate';
    final res = await _dio.get('/rih_stock_adjustment_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
  }) async {
    final res = await _dio.get('/rid_stock_adjustment_lines', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'adjustment_no':   'eq.$adjustmentNo',
      'adjustment_date': 'eq.$adjustmentDate',
      'is_deleted':      'eq.false',
      'select':          'serial_no,product_id,uom_id,uom_conversion_factor,qty_pack,qty_loose,base_qty,'
          'adjust_flag,system_qty,unit_cost,unit_cost_specific,barcode,reason_id,remarks,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'reason:rim_common_masters!reason_id(description)',
      'order':           'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLineBatches({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_ADJUSTMENT', 'source_doc_no': 'eq.$adjustmentNo', 'source_doc_date': 'eq.$adjustmentDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'batch_no,expiry_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getLineSerials({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_ADJUSTMENT', 'source_doc_no': 'eq.$adjustmentNo', 'source_doc_date': 'eq.$adjustmentDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'serial_no',
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
      'select':     'id,location_name',
      'order':      'location_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getReasons({
    required String clientId,
    required String companyId,
  }) async {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.STOCK_ADJUSTMENT_REASON',
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

  Future<num> getCurrentStock({
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
    if (list.isEmpty) return 0;
    return (list.first as Map<String, dynamic>)['current_stock'] as num? ?? 0;
  }

  /// Every batch with a positive balance for this product/location — the
  /// candidate list for a '-' (decrease) batch-tracked line.
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

  /// Every serial currently IN_STOCK for this product/location — the
  /// candidate list for a '-' (decrease) serial-tracked line.
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

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_stock_adjustment', data: {
      'p_header':  header,
      'p_lines':   lines,
      'p_batches': batches,
      'p_serials': serials,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
    required String adjustmentDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_stock_adjustment', data: {
      'p_client_id':      clientId,
      'p_company_id':     companyId,
      'p_adjustment_no':  adjustmentNo,
      'p_adjustment_date': adjustmentDate,
      'p_approved_by':    approvedBy,
    });
  }

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String adjustmentNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.STOCK_ADJUSTMENT',
      'source_doc_no':   'eq.$adjustmentNo',
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
      'select':     'serial_no,trans_no,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}

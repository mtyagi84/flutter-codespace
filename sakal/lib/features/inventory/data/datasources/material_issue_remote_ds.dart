import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class MaterialIssueRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'location:ric_locations!location_id(location_name)';

  Future<List<Map<String, dynamic>>> listIssues({
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
      'order':      'issue_date.desc,issue_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['issue_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_material_issue_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String issueNo,
    String? issueDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'issue_no':   'eq.$issueNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'issue_date.desc',
      'limit':      '1',
    };
    if (issueDate != null && issueDate.isNotEmpty) params['issue_date'] = 'eq.$issueDate';
    final res = await _dio.get('/rih_material_issue_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String issueNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.MATERIAL_ISSUE',
      'source_doc_no':   'eq.$issueNo',
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

  // ── Requisition picker ───────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getFulfillableRequisitions({
    required String clientId,
    required String companyId,
    required String locationId,
  }) async {
    final res = await _dio.get('/rih_material_requisition_headers', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId',
      'is_deleted': 'eq.false',
      'status':     'in.(APPROVED,PARTIALLY_ISSUED)',
      'select':     'requisition_no,requisition_date,requested_by,status',
      'order':      'requisition_date.asc,requisition_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getRequisitionLines({
    required String clientId,
    required String companyId,
    required String requisitionNo,
    required String requisitionDate,
  }) async {
    final res = await _dio.get('/rid_material_requisition_lines', queryParameters: {
      'client_id':        'eq.$clientId',
      'company_id':       'eq.$companyId',
      'requisition_no':   'eq.$requisitionNo',
      'requisition_date': 'eq.$requisitionDate',
      'is_deleted':       'eq.false',
      'select':           'serial_no,product_id,uom_id,uom_conversion_factor,base_qty,issued_qty,'
          'department_id,consumption_area_id,barcode,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description),'
          'department:rim_common_masters!department_id(description),'
          'area:rim_common_masters!consumption_area_id(description)',
      'order':            'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Batch/serial candidates (same generic tables Purchase Return uses) ──

  Future<num> getBatchBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String batchNo,
  }) async {
    final res = await _dio.get('/v_batch_stock_balance', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'product_id': 'eq.$productId', 'batch_no': 'eq.$batchNo',
      'select': 'balance',
    });
    final list = res.data as List;
    if (list.isEmpty) return 0;
    return (list.first as Map<String, dynamic>)['balance'] as num? ?? 0;
  }

  /// Every batch with a positive balance for this product/location — the
  /// picker's candidate list for a batch-tracked issue line (there's no
  /// "originating GRN line" the way Purchase Return has; any batch
  /// currently in stock here is a valid candidate).
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

  Future<List<Map<String, dynamic>>> getIssueLineBatches({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.MATERIAL_ISSUE', 'source_doc_no': 'eq.$issueNo', 'source_doc_date': 'eq.$issueDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'batch_no,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getIssueLineSerials({
    required String clientId,
    required String companyId,
    required String issueNo,
    required String issueDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.MATERIAL_ISSUE', 'source_doc_no': 'eq.$issueNo', 'source_doc_date': 'eq.$issueDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'serial_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Save / Approve ───────────────────────────────────────────────────────

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_material_issue', data: {
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
    required String issueNo,
    required String issueDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_material_issue', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_issue_no':    issueNo,
      'p_issue_date':  issueDate,
      'p_approved_by': approvedBy,
    });
  }
}

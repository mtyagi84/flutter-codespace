import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class StockReceiptRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'from_location:ric_locations!from_location_id(location_name),'
      'to_location:ric_locations!to_location_id(location_name)';

  Future<List<Map<String, dynamic>>> listReceipts({
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
      'order':      'receipt_date.desc,receipt_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['receipt_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_stock_receipts', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String receiptNo,
    String? receiptDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'receipt_no': 'eq.$receiptNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'receipt_date.desc',
      'limit':      '1',
    };
    if (receiptDate != null && receiptDate.isNotEmpty) params['receipt_date'] = 'eq.$receiptDate';
    final res = await _dio.get('/rih_stock_receipts', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  }) async {
    final res = await _dio.get('/rid_stock_receipt_lines', queryParameters: {
      'client_id':    'eq.$clientId',
      'company_id':   'eq.$companyId',
      'receipt_no':   'eq.$receiptNo',
      'receipt_date': 'eq.$receiptDate',
      'is_deleted':   'eq.false',
      'select':       'serial_no,source_transfer_line_serial,product_id,uom_id,uom_conversion_factor,'
          'received_qty_pack,received_qty_loose,received_base_qty,remarks,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':        'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// APPROVED transfers not yet received — the picker for a new receipt.
  /// Filtered client-side to the session's own location where useful, but
  /// the query itself only needs to_location_id to narrow the list.
  Future<List<Map<String, dynamic>>> getReceivableTransfers({
    required String clientId,
    required String companyId,
    String? toLocationId,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'status':     'eq.APPROVED',
      'is_deleted': 'eq.false',
      'select':     '*,from_location:ric_locations!from_location_id(location_name),to_location:ric_locations!to_location_id(location_name)',
      'order':      'transfer_date.asc',
    };
    if (toLocationId != null) params['to_location_id'] = 'eq.$toLocationId';
    final res = await _dio.get('/rih_stock_transfers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getTransferLines({
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
      'select':        'serial_no,product_id,uom_id,uom_conversion_factor,base_qty,barcode,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':         'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getDispatchedBatches({
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
      'select': 'batch_no,expiry_date,manufacturing_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getDispatchedSerials({
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

  Future<List<Map<String, dynamic>>> getReceiptLineBatches({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_RECEIPT', 'source_doc_no': 'eq.$receiptNo', 'source_doc_date': 'eq.$receiptDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'batch_no,expiry_date,manufacturing_date,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getReceiptLineSerials({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.STOCK_RECEIPT', 'source_doc_no': 'eq.$receiptNo', 'source_doc_date': 'eq.$receiptDate',
      'line_serial': 'eq.$lineSerial',
      'select': 'serial_no',
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
    final res = await _dio.post('/rpc/fn_save_stock_receipt', data: {
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
    required String receiptNo,
    required String receiptDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_stock_receipt', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_receipt_no':  receiptNo,
      'p_receipt_date': receiptDate,
      'p_approved_by': approvedBy,
    });
  }

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String receiptNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':       'eq.$clientId',
      'company_id':      'eq.$companyId',
      'source_doc_type': 'eq.STOCK_RECEIPT',
      'source_doc_no':   'eq.$receiptNo',
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

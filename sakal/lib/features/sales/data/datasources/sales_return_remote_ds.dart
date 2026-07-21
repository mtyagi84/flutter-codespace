import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class SalesReturnRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'customer:rim_accounts!customer_id(account_code,account_name)';

  Future<List<Map<String, dynamic>>> listReturns({
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
      'order':      'return_date.desc,return_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['or'] = '(return_no.ilike.*$search*,invoice_no.ilike.*$search*)';
    final res = await _dio.get('/rih_sales_return_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String returnNo,
    String? returnDate,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'return_no':  'eq.$returnNo',
      'is_deleted': 'eq.false',
      'select':     _headerSelect,
      'order':      'return_date.desc',
      'limit':      '1',
    };
    if (returnDate != null && returnDate.isNotEmpty) params['return_date'] = 'eq.$returnDate';
    final res = await _dio.get('/rih_sales_return_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final res = await _dio.get('/rid_sales_return_lines', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'return_no':  'eq.$returnNo', 'return_date': 'eq.$returnDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,invoice_line_serial,product_id,barcode,uom_id,uom_conversion_factor,'
          'qty_pack,qty_loose,base_qty,rate,tax_group_id,gross_amount,tax_amount,final_amount,'
          'charge_amount,landed_amount,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
  }) async {
    final res = await _dio.get('/rid_sales_return_charges', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'return_no':  'eq.$returnNo', 'return_date': 'eq.$returnDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,invoice_charge_serial,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,amount,tax_amount',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// APPROVED invoices this Sales Return picker can offer — a plain
  /// status-filtered fetch, client-side subtraction of anything fully
  /// returned (same "picker is UX only" convention as every prior
  /// picker in this app; the row-locked cap check in fn_approve is
  /// authoritative regardless).
  Future<List<Map<String, dynamic>>> getApprovedInvoices({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'status':     'eq.APPROVED', 'is_deleted': 'eq.false',
      'select':     'invoice_no,invoice_date,customer_id,sale_type,grand_total,stock_dispatch_mode,'
          'cash_collection_mode,collected_amount_local,collected_amount_base,'
          'customer:rim_accounts!customer_id(account_code,account_name)',
      'order':      'invoice_date.desc',
      'limit':      '50',
    };
    if (search != null && search.isNotEmpty) params['invoice_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_sales_invoices', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getInvoiceLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_sales_invoice_lines', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'invoice_no': 'eq.$invoiceNo', 'invoice_date': 'eq.$invoiceDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,barcode,uom_id,uom_conversion_factor,base_qty,rate,'
          'tax_group_id,gross_amount,tax_amount,final_amount,charge_amount,landed_amount,'
          'product:rim_products!product_id(product_code,product_name,tracking_type),'
          'uom:rim_common_masters!uom_id(description)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getInvoiceCharges({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rid_sales_invoice_charges', queryParameters: {
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'invoice_no': 'eq.$invoiceNo', 'invoice_date': 'eq.$invoiceDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,amount,tax_amount',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Already-returned qty per invoice line across every prior APPROVED
  /// Sales Return against this invoice — summed client-side (few rows
  /// expected). Used to compute each line's remaining-returnable qty.
  /// Two-step lookup (never PostgREST embedded-resource filtering, which
  /// has no precedent anywhere else in this app): APPROVED return_nos for
  /// this invoice first, then their lines.
  Future<List<String>> _approvedReturnNosForInvoice({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final res = await _dio.get('/rih_sales_return_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'invoice_no': 'eq.$invoiceNo', 'invoice_date': 'eq.$invoiceDate',
      'status': 'eq.APPROVED', 'is_deleted': 'eq.false',
      'select': 'return_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List).map((r) => r['return_no'] as String).toList();
  }

  Future<List<Map<String, dynamic>>> getAlreadyReturnedByLine({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final returnNos = await _approvedReturnNosForInvoice(
      clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate,
    );
    if (returnNos.isEmpty) return [];
    final res = await _dio.get('/rid_sales_return_lines', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'return_no': 'in.(${returnNos.join(',')})', 'is_deleted': 'eq.false',
      'select': 'invoice_line_serial,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// What a specific invoice line actually sold, batch-wise.
  Future<List<Map<String, dynamic>>> getInvoiceLineBatches({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_INVOICE', 'source_doc_no': 'eq.$invoiceNo',
      'source_doc_date': 'eq.$invoiceDate', 'line_serial': 'eq.$lineSerial',
      'select': 'batch_no,expiry_date,base_qty',
      'order': 'expiry_date.asc.nullslast',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getInvoiceLineSerials({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required int    lineSerial,
  }) async {
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_INVOICE', 'source_doc_no': 'eq.$invoiceNo',
      'source_doc_date': 'eq.$invoiceDate', 'line_serial': 'eq.$lineSerial',
      'select': 'serial_no',
      'order': 'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Batch/serial already consumed by a prior APPROVED Sales Return against
  /// this same invoice line — subtracted client-side from the candidates
  /// above so a repeat return doesn't re-offer an already-returned unit.
  Future<List<Map<String, dynamic>>> getAlreadyReturnedBatches({
    required String clientId,
    required String companyId,
    required List<String> returnNos,
  }) async {
    if (returnNos.isEmpty) return [];
    final res = await _dio.get('/rid_transaction_line_batches', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_RETURN',
      'source_doc_no': 'in.(${returnNos.join(',')})',
      'select': 'source_doc_no,line_serial,batch_no,base_qty',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getAlreadyReturnedSerials({
    required String clientId,
    required String companyId,
    required List<String> returnNos,
  }) async {
    if (returnNos.isEmpty) return [];
    final res = await _dio.get('/rid_transaction_line_serials', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_RETURN',
      'source_doc_no': 'in.(${returnNos.join(',')})',
      'select': 'source_doc_no,line_serial,serial_no',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Return_no + which invoice_line_serial each covered, for every prior
  /// APPROVED Sales Return against this invoice — used to resolve the
  /// batch/serial "already returned" queries above (which key off the
  /// RETURN's own line_serial, not the invoice's).
  Future<List<Map<String, dynamic>>> getPriorReturnLineKeys({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    final returnNos = await _approvedReturnNosForInvoice(
      clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate,
    );
    if (returnNos.isEmpty) return [];
    final res = await _dio.get('/rid_sales_return_lines', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'return_no': 'in.(${returnNos.join(',')})', 'is_deleted': 'eq.false',
      'select': 'return_no,serial_no,invoice_line_serial',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Online-only — Pending Approvals review queries a plain status='DRAFT'
  /// filter scoped to one location, same shape as Sales Invoice's own
  /// listDraftInvoicesForReview.
  Future<List<Map<String, dynamic>>> listDraftReturnsForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) async {
    final res = await _dio.get('/rih_sales_return_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'status': 'eq.DRAFT', 'is_deleted': 'eq.false',
      'select': _headerSelect,
      'order': 'return_date.asc,return_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_sales_return', data: {
      'p_header':   header,
      'p_lines':    lines,
      'p_batches':  batches,
      'p_serials':  serials,
      'p_charges':  charges,
      'p_user_id':  userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String returnNo,
    required String returnDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_sales_return', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_return_no':   returnNo,
      'p_return_date': returnDate,
      'p_approved_by': approvedBy,
    });
  }

  /// Which vouchers this return posted — source_doc_type/no/date live on
  /// rih_finance_headers, NOT rid_finance_lines (which only carries
  /// trans_no/trans_date), so this is always a two-step lookup: headers
  /// first, then each voucher's own lines by trans_no/trans_date.
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':       'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.SALES_RETURN', 'source_doc_no': 'eq.$returnNo',
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
      'client_id':  'eq.$clientId', 'company_id': 'eq.$companyId',
      'trans_no':   'eq.$voucherNo', 'trans_date': 'eq.$voucherDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,trans_no,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}

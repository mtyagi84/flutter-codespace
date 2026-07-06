import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/purchase_return_model.dart';

class PurchaseReturnRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'supplier:rim_accounts!supplier_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!return_currency_id(currency_id)';

  // ── List / Header ────────────────────────────────────────────────────────────

  Future<List<PurchaseReturnModel>> listPurchaseReturns({
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
    if (search != null && search.isNotEmpty) params['return_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_purchase_return_headers', queryParameters: params);
    return (res.data as List).map((e) => PurchaseReturnModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PurchaseReturnModel?> getHeader({
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
    final res = await _dio.get('/rih_purchase_return_headers', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? PurchaseReturnModel.fromJson(list.first as Map<String, dynamic>) : null;
  }

  /// Every voucher this return posted (up to two — a JV for the unbilled
  /// portion, an SDN for the billed portion) — found by source doc, same
  /// pattern as Purchase Bill's PUR+EXC pair.
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String returnNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id':      'eq.$clientId',
      'company_id':     'eq.$companyId',
      'source_doc_type': 'eq.PURCHASE_RETURN',
      'source_doc_no':   'eq.$returnNo',
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

  // ── Supplier -> GRN picker ────────────────────────────────────────────────

  /// Distinct suppliers with at least one APPROVED GRN — returns can
  /// reference billed or unbilled GRNs alike (unlike Purchase Bill), so
  /// there's no "not yet billed" filter here.
  Future<List<Map<String, dynamic>>> getSuppliersWithApprovedGrns({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'status':     'eq.APPROVED',
      'select':     'supplier:rim_accounts!supplier_id(id,account_code,account_name)',
    });
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final e in res.data as List) {
      final supplier = (e as Map<String, dynamic>)['supplier'] as Map<String, dynamic>?;
      if (supplier == null) continue;
      if (seen.add(supplier['id'] as String)) result.add(supplier);
    }
    result.sort((a, b) => (a['account_code'] as String? ?? '').compareTo(b['account_code'] as String? ?? ''));
    return result;
  }

  /// This supplier's APPROVED GRNs, billed or not — billed_invoice_no tells
  /// the entry screen which financial path (JV vs SDN) a line will take.
  Future<List<Map<String, dynamic>>> getGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
  }) async {
    final res = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'supplier_id': 'eq.$supplierId',
      'is_deleted':  'eq.false',
      'status':      'eq.APPROVED',
      'select':      'grn_no,grn_date,grn_currency_id,billed_invoice_no,'
          'currency:rim_currencies!grn_currency_id(currency_id)',
      'order':       'grn_date.asc,grn_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// A GRN's own lines — GRN qty pre-fills as the suggested (editable)
  /// return qty on the entry screen.
  Future<List<Map<String, dynamic>>> getGrnLines({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final res = await _dio.get('/rid_grn_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'eq.$grnNo',
      'grn_date':   'eq.$grnDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,product_id,uom_id,uom_conversion_factor,base_qty,rate,'
          'tax_group_id,gross_amount,tax_amount,final_amount,source_po_order_no,'
          'product:rim_products!product_id(product_code,product_name),'
          'uom:rim_common_masters!uom_id(description),'
          'tax_group:rim_tax_groups!tax_group_id(group_name)',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// A GRN's own additional charges — populate as editable defaults.
  Future<List<Map<String, dynamic>>> getGrnCharges({
    required String clientId,
    required String companyId,
    required String grnNo,
    required String grnDate,
  }) async {
    final res = await _dio.get('/rid_grn_charge_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'grn_no':     'eq.$grnNo',
      'grn_date':   'eq.$grnDate',
      'is_deleted': 'eq.false',
      'select':     'serial_no,charge_id,charge_name,is_taxable,tax_id,nature,gl_account_id,amount,tax_amount',
      'order':      'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  // ── Save / Approve ────────────────────────────────────────────────────────────

  /// Returns the assigned return_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_purchase_return', data: {
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
    required String returnNo,
    required String returnDate,
    required bool   reopenPo,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_purchase_return', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_return_no':   returnNo,
      'p_return_date': returnDate,
      'p_reopen_po':   reopenPo,
      'p_approved_by': approvedBy,
    });
  }
}

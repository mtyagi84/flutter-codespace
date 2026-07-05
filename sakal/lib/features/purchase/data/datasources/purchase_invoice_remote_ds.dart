import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/purchase_invoice_model.dart';

class PurchaseInvoiceRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'supplier:rim_accounts!supplier_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name),'
      'currency:rim_currencies!invoice_currency_id(currency_id)';

  // ── List / Header ────────────────────────────────────────────────────────────

  Future<List<PurchaseInvoiceModel>> listPurchaseInvoices({
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
      'order':      'invoice_date.desc,invoice_no.desc',
      'limit':      '$limit',
      'offset':     '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['invoice_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_purchase_invoices', queryParameters: params);
    return (res.data as List).map((e) => PurchaseInvoiceModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PurchaseInvoiceModel?> getHeader({
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
    final res = await _dio.get('/rih_purchase_invoices', queryParameters: params);
    final list = res.data as List;
    return list.isNotEmpty ? PurchaseInvoiceModel.fromJson(list.first as Map<String, dynamic>) : null;
  }

  /// The GL lines fn_post_voucher created when this bill was approved — same
  /// pattern as GRN's own "Posted Journal Entries" section.
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

  // ── Supplier -> pending GRN picker ────────────────────────────────────────────

  /// Distinct suppliers with at least one APPROVED, not-yet-billed GRN — the
  /// candidate list for the entry screen's supplier picker.
  Future<List<Map<String, dynamic>>> getSuppliersWithPendingGrns({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':        'eq.$clientId',
      'company_id':       'eq.$companyId',
      'is_deleted':       'eq.false',
      'status':           'eq.APPROVED',
      'billed_invoice_no': 'is.null',
      'select':           'supplier:rim_accounts!supplier_id(id,account_code,account_name)',
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

  /// This supplier's billable GRNs — APPROVED and either unbilled, or
  /// already reserved by the draft bill currently being edited
  /// (excludeInvoiceNo), so re-opening a draft still shows its own GRNs
  /// as candidates.
  Future<List<Map<String, dynamic>>> getPendingGrnsForSupplier({
    required String clientId,
    required String companyId,
    required String supplierId,
    String? excludeInvoiceNo,
  }) async {
    final res = await _dio.get('/rih_grn_headers', queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'supplier_id': 'eq.$supplierId',
      'is_deleted':  'eq.false',
      'status':      'eq.APPROVED',
      'or':          excludeInvoiceNo == null || excludeInvoiceNo.isEmpty
          ? '(billed_invoice_no.is.null)'
          : '(billed_invoice_no.is.null,billed_invoice_no.eq.$excludeInvoiceNo)',
      'select':      'grn_no,grn_date,grn_currency_id,rate_to_base,rate_to_local,billed_invoice_no,'
          'currency:rim_currencies!grn_currency_id(currency_id)',
      'order':       'grn_date.asc,grn_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Suggested taxable_amount/tax_amount for the currently-checked GRNs —
  /// reads the exact same sums fn_approve_purchase_invoice itself uses, so
  /// the preview never drifts from what will actually post. The user
  /// validates this against the supplier's paper invoice and only edits on
  /// a genuine mismatch.
  Future<Map<String, double>> getGrnBillingDefaults({
    required String clientId,
    required String companyId,
    required List<Map<String, String>> grnRefs,
  }) async {
    final res = await _dio.post('/rpc/fn_get_grn_billing_defaults', data: {
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_grn_refs':   grnRefs,
    });
    final list = res.data as List;
    if (list.isEmpty) return {'taxable_amount': 0, 'tax_amount': 0};
    final row = list.first as Map<String, dynamic>;
    return {
      'taxable_amount': (row['taxable_amount'] as num? ?? 0).toDouble(),
      'tax_amount':     (row['tax_amount'] as num? ?? 0).toDouble(),
    };
  }

  // ── Save / Approve ────────────────────────────────────────────────────────────

  /// Returns the assigned invoice_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, String>> grnRefs,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_purchase_invoice', data: {
      'p_header':   header,
      'p_grn_refs': grnRefs,
      'p_user_id':  userId,
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
    await _dio.post('/rpc/fn_approve_purchase_invoice', data: {
      'p_client_id':    clientId,
      'p_company_id':   companyId,
      'p_invoice_no':   invoiceNo,
      'p_invoice_date': invoiceDate,
      'p_approved_by':  approvedBy,
    });
  }
}

import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class CashReceiptRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'customer:rim_accounts!customer_id(account_code,account_name),'
      'location:ric_locations!location_id(location_name)';

  Future<List<Map<String, dynamic>>> listReceipts({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final params = <String, dynamic>{
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_deleted': 'eq.false',
      'select': _headerSelect,
      'order': 'receipt_date.desc,receipt_no.desc',
      'limit': '$limit',
      'offset': '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['receipt_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_cash_receipt_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String receiptNo,
  }) async {
    final res = await _dio.get('/rih_cash_receipt_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'receipt_no': 'eq.$receiptNo', 'is_deleted': 'eq.false',
      'select': _headerSelect,
      'order': 'receipt_date.desc',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String receiptNo,
    required String receiptDate,
  }) async {
    final res = await _dio.get('/rid_cash_receipt_lines', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'receipt_no': 'eq.$receiptNo', 'receipt_date': 'eq.$receiptDate',
      'is_deleted': 'eq.false',
      'select': 'serial_no,inv_bill_no,inv_bill_date,bill_currency,applied_amount_local',
      'order': 'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Read-only prefill source (location, local/base cash accounts) —
  /// this screen never writes to ric_user_quick_invoice_setup, only
  /// reads it, same convention as Sales Invoice's own cash-collection
  /// prefill.
  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    final res = await _dio.get('/ric_user_quick_invoice_setup', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'user_id': 'eq.$userId', 'is_deleted': 'eq.false',
      'select': 'location_id,local_cash_account_id,base_cash_account_id,'
          'location:ric_locations!location_id(location_name),'
          'local_cash_account:rim_accounts!local_cash_account_id(account_code,account_name),'
          'base_cash_account:rim_accounts!base_cash_account_id(account_code,account_name)',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  /// Only customers with a pending bill at this location appear — fills
  /// the gap v_pending_bills' own consumers never needed before (every
  /// prior screen picks the party FIRST, then loads bills).
  Future<List<Map<String, dynamic>>> getCustomersWithPendingBills({
    required String clientId,
    required String companyId,
    required String locationId,
    String? search,
  }) async {
    final res = await _dio.get('/v_customers_with_pending_bills', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId', 'location_id': 'eq.$locationId',
      'select': 'account_id,account:rim_accounts!account_id(account_code,account_name)',
    });
    final rows = List<Map<String, dynamic>>.from(res.data as List);
    if (search == null || search.isEmpty) return rows;
    final needle = search.toLowerCase();
    return rows.where((r) {
      final acc = r['account'] as Map<String, dynamic>?;
      final code = (acc?['account_code'] as String? ?? '').toLowerCase();
      final name = (acc?['account_name'] as String? ?? '').toLowerCase();
      return code.contains(needle) || name.contains(needle);
    }).toList();
  }

  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  }) async {
    final res = await _dio.get('/v_pending_bills', queryParameters: {
      'company_id': 'eq.$companyId', 'location_id': 'eq.$locationId', 'account_id': 'eq.$accountId',
      'select': 'trans_no,trans_date,inv_bill_no,inv_bill_date,bill_amount,settled_amount,balance_amount,party_currency',
      'order': 'trans_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>> getCompanyCurrencies({required String companyId}) async {
    final res = await _dio.get('/ric_companies', queryParameters: {
      'id': 'eq.$companyId', 'select': 'base_currency,local_currency', 'limit': '1',
    });
    final list = List<Map<String, dynamic>>.from(res.data as List);
    return list.isNotEmpty ? list.first : {};
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
        'p_company_id': companyId,
        'p_location_id': locationId,
        'p_from_currency': fromCurrency,
        'p_to_currency': toCurrency,
        'p_rate_date': rateDate,
        'p_rate_type': 'MID',
      });
      return (res.data as num?)?.toDouble();
    } on DioException {
      return null;
    }
  }

  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final res = await _dio.post('/rpc/fn_save_cash_receipt', data: {
      'p_header': header,
      'p_lines': lines,
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
    await _dio.post('/rpc/fn_approve_cash_receipt', data: {
      'p_client_id': clientId,
      'p_company_id': companyId,
      'p_receipt_no': receiptNo,
      'p_receipt_date': receiptDate,
      'p_approved_by': approvedBy,
    });
  }

  /// Online-only — Pending Approvals queries a plain status='DRAFT'
  /// filter, same shape as the other three document types it lists.
  Future<List<Map<String, dynamic>>> listDraftReceiptsForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) async {
    final res = await _dio.get('/rih_cash_receipt_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'location_id': 'eq.$locationId', 'status': 'eq.DRAFT', 'is_deleted': 'eq.false',
      'select': _headerSelect,
      'order': 'receipt_date.asc,receipt_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  /// Which vouchers this receipt posted (CRV-LOCAL/CRV-BASE/EXC) —
  /// source_doc_type/no live on rih_finance_headers, always a two-step
  /// lookup, same pattern as Sales Delivery/Return's own getPostedVouchers.
  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String receiptNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.CASH_RECEIPT', 'source_doc_no': 'eq.$receiptNo',
      'is_deleted': 'eq.false',
      'select': 'trans_no,trans_date,voucher_type_code',
      'order': 'trans_date.asc',
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
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'trans_no': 'eq.$voucherNo', 'trans_date': 'eq.$voucherDate',
      'is_deleted': 'eq.false',
      'select': 'serial_no,trans_no,trans_nature,trans_amount,'
          'account:rim_accounts!account_id(account_code,account_name)',
      'order': 'serial_no.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) async {
    final res = await _dio.get('/rim_users', queryParameters: {
      'client_id': 'eq.$clientId',
      'company_id': 'eq.$companyId',
      'is_active': 'eq.true',
      'is_deleted': 'eq.false',
      'select': 'id,full_name',
      'order': 'full_name.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}

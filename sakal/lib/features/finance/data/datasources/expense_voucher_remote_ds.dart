import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';

class ExpenseVoucherRemoteDs {
  final Dio _dio = DioClient.instance;

  static const _headerSelect = '*,'
      'supplier:rim_accounts!supplier_id(account_code,account_name),'
      'currency:rim_currencies!currency_id(currency_id),'
      'location:ric_locations!location_id(location_name),'
      'created_by_user:rim_users!created_by(full_name),'
      'approved_by_user:rim_users!approved_by(full_name)';

  Future<List<Map<String, dynamic>>> listVouchers({
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
      'order': 'trans_date.desc,trans_no.desc',
      'limit': '$limit',
      'offset': '$offset',
    };
    if (status != null && status.isNotEmpty) params['status'] = 'eq.$status';
    if (search != null && search.isNotEmpty) params['trans_no'] = 'ilike.*$search*';
    final res = await _dio.get('/rih_expense_voucher_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
  }) async {
    final res = await _dio.get('/rih_expense_voucher_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'trans_no': 'eq.$transNo', 'is_deleted': 'eq.false',
      'select': _headerSelect,
      'order': 'trans_date.desc',
      'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? list.first as Map<String, dynamic> : null;
  }

  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
  }) async {
    final res = await _dio.get('/rid_expense_voucher_lines', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'trans_no': 'eq.$transNo', 'trans_date': 'eq.$transDate',
      'is_deleted': 'eq.false',
      'select': 'serial_no,account_id,amount,tax_group_id,line_remarks,'
          'account:rim_accounts!account_id(account_code,account_name),'
          'tax_group:rim_tax_groups!tax_group_id(group_code,group_name)',
      'order': 'serial_no.asc',
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
    final res = await _dio.post('/rpc/fn_save_expense_voucher', data: {
      'p_header': header,
      'p_lines': lines,
      'p_user_id': userId,
    });
    return res.data as String;
  }

  Future<void> approve({
    required String clientId,
    required String companyId,
    required String locationId,
    required String transNo,
    required String transDate,
    required String approvedBy,
  }) async {
    await _dio.post('/rpc/fn_approve_expense_voucher', data: {
      'p_client_id': clientId,
      'p_company_id': companyId,
      'p_location_id': locationId,
      'p_trans_no': transNo,
      'p_trans_date': transDate,
      'p_approved_by': approvedBy,
    });
  }

  // ── Client-side tax PREVIEW only — mirrors Purchase Order's own
  // getTaxGroupMemberTaxIds/getTaxRatesByIds pattern exactly
  // (purchase_order_remote_ds.dart), extended with the is_withholding
  // split fn_approve_expense_voucher itself uses server-side. The
  // backend remains the sole authoritative computation at Approve time
  // — this is purely so the entry screen can show a live "expected net"
  // before saving, for fast/convenient data entry.

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
      'tax_id':     'in.(${taxIds.join(',')})',
      'rate_label': 'eq.STANDARD',
      'is_active':  'eq.true',
      'select':     'tax_id,rate,effective_from,effective_to',
      'order':      'effective_from.desc',
    });
    final asOf   = DateTime.tryParse(asOfDate) ?? DateTime.now();
    final result = <String, double>{};
    for (final e in res.data as List) {
      final m     = e as Map<String, dynamic>;
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

  /// tax_id → is_withholding, via rim_taxes.tax_type_code -> rim_tax_types.
  /// First Flutter-side consumer of is_withholding — the backend
  /// (fn_approve_expense_voucher) is its first consumer anywhere.
  Future<Map<String, bool>> getTaxWithholdingFlags(List<String> taxIds) async {
    if (taxIds.isEmpty) return {};
    final res = await _dio.get('/rim_taxes', queryParameters: {
      'id':     'in.(${taxIds.join(',')})',
      'select': 'id,tax_type:rim_tax_types!tax_type_code(is_withholding)',
    });
    final result = <String, bool>{};
    for (final e in res.data as List) {
      final m = e as Map<String, dynamic>;
      final taxType = m['tax_type'] as Map<String, dynamic>?;
      result[m['id'] as String] = taxType?['is_withholding'] as bool? ?? false;
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> getPostedVouchers({
    required String clientId,
    required String companyId,
    required String transNo,
  }) async {
    final res = await _dio.get('/rih_finance_headers', queryParameters: {
      'client_id': 'eq.$clientId', 'company_id': 'eq.$companyId',
      'source_doc_type': 'eq.EXPENSE_VOUCHER', 'source_doc_no': 'eq.$transNo',
      'is_deleted': 'eq.false',
      'select': 'trans_no,trans_date,voucher_type_code',
      'order': 'trans_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}

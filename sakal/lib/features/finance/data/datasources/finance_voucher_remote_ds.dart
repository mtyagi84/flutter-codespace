import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/finance_voucher_model.dart';

class FinanceVoucherRemoteDs {
  Future<List<Map<String, dynamic>>> listHeaders({
    required String clientId,
    required String companyId,
    required String locationId,
    required String fromDate,
    required String toDate,
    String? voucherTypeCode,
    bool? isPosted,
  }) async {
    final params = <String, dynamic>{
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'is_deleted':  'eq.false',
      // This screen is for manually-entered Payment/Receipt vouchers only —
      // system-generated journal entries (posting_source='AUTO', e.g. the
      // JV a GRN approval creates via fn_post_voucher) belong to their
      // source document's own screen, not here.
      'posting_source': 'eq.MANUAL',
      'trans_date':  ['gte.$fromDate', 'lte.$toDate'],
      'select':      'trans_no,trans_date,voucher_type_code,payment_mode_code,is_on_account,is_posted,remarks',
      'order':       'trans_date.desc,trans_no.desc',
      'limit':       '500',
    };
    if (voucherTypeCode != null) params['voucher_type_code'] = 'eq.$voucherTypeCode';
    if (isPosted != null) params['is_posted'] = 'eq.$isPosted';
    final res = await DioClient.instance.get('/rih_finance_headers', queryParameters: params);
    return List<Map<String, dynamic>>.from(res.data as List);
  }

  Future<FinanceVoucherHeader?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
    String? transDate,            // if known, filter precisely; otherwise latest by trans_no
  }) async {
    final params = <String, dynamic>{
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'trans_no':   'eq.$transNo',
      'is_deleted': 'eq.false',
      'select':     '*,'
                    'created_by_user:rim_users!created_by(full_name),'
                    'posted_by_user:rim_users!posted_by(full_name)',
      'order':      'trans_date.desc',
      'limit':      '1',
    };
    if (transDate != null && transDate.isNotEmpty) {
      params['trans_date'] = 'eq.$transDate';
    }
    final res = await DioClient.instance.get('/rih_finance_headers', queryParameters: params);
    final list = List<Map<String, dynamic>>.from(res.data as List);
    return list.isNotEmpty ? FinanceVoucherHeader.fromJson(list.first) : null;
  }

  Future<List<FinanceVoucherLine>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,    // always required — composite key (trans_no, trans_date)
  }) async {
    final res = await DioClient.instance.get('/rid_finance_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'trans_no':   'eq.$transNo',
      'trans_date': 'eq.$transDate',
      'is_deleted': 'eq.false',
      'select':     '*',
      'order':      'serial_no.asc',
    });
    return (res.data as List)
        .map((j) => FinanceVoucherLine.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  // Returns the assigned trans_no.
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required String userId,
  }) async {
    final res = await DioClient.instance.post(
      '/rpc/fn_save_finance_voucher',
      data: {'p_header': header, 'p_lines': lines, 'p_user_id': userId},
    );
    return res.data as String;
  }

  Future<void> post({
    required String clientId,
    required String companyId,
    required String locationId,
    required String transNo,
    required String transDate,
    required String postedBy,
  }) async {
    await DioClient.instance.post('/rpc/fn_post_finance_voucher', data: {
      'p_client_id':   clientId,
      'p_company_id':  companyId,
      'p_location_id': locationId,
      'p_trans_no':    transNo,
      'p_trans_date':  transDate,
      'p_posted_by':   postedBy,
    });
  }

  // Returns the new reversal voucher's trans_no. Shared by every manually
  // posted voucher type (Journal Voucher, Contra Voucher, ...) — the
  // underlying fn_reverse_voucher is fully generic over voucher_type_code.
  Future<String> reverseVoucher({
    required String clientId,
    required String companyId,
    required String transNo,
    required String transDate,
    required String userId,
  }) async {
    final res = await DioClient.instance.post('/rpc/fn_reverse_voucher', data: {
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_trans_no':   transNo,
      'p_trans_date': transDate,
      'p_user_id':    userId,
    });
    return res.data as String;
  }

  // Company-granularity account-link lookup for a link type with no
  // natural product/category anchor (e.g. EXCHANGE_GAIN_LOSS_ACCOUNT on
  // a Contra Voucher's transfer-charge line). Returns null if not
  // configured — callers must not silently proceed as if a value existed.
  Future<String?> resolveCompanyAccountLink({
    required String clientId,
    required String companyId,
    required String linkKey,
  }) async {
    final res = await DioClient.instance.post('/rpc/fn_resolve_company_account_link', data: {
      'p_client_id':  clientId,
      'p_company_id': companyId,
      'p_link_key':   linkKey,
    });
    return res.data as String?;
  }

  Future<Map<String, dynamic>> getCompanyCurrencies({
    required String companyId,
  }) async {
    final res = await DioClient.instance.get('/ric_companies', queryParameters: {
      'id':     'eq.$companyId',
      'select': 'base_currency,local_currency',
      'limit':  '1',
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
      final res = await DioClient.instance.post('/rpc/fn_get_exchange_rate', data: {
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

  Future<List<Map<String, dynamic>>> getPendingBills({
    required String companyId,
    required String locationId,
    required String accountId,
  }) async {
    final res = await DioClient.instance.get('/v_pending_bills', queryParameters: {
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'account_id':  'eq.$accountId',
      'select':      'trans_no,trans_date,inv_bill_no,inv_bill_date,'
                     'bill_amount,settled_amount,balance_amount,party_currency',
      'order':       'trans_date.asc',
    });
    return List<Map<String, dynamic>>.from(res.data as List);
  }
}

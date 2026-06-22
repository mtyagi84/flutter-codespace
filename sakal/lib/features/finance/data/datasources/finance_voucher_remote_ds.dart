import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/finance_voucher_model.dart';

class FinanceVoucherRemoteDs {
  Future<FinanceVoucherHeader?> getHeader({
    required String clientId,
    required String companyId,
    required String transNo,
  }) async {
    final res = await DioClient.instance.get('/rih_finance_headers', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'trans_no':   'eq.$transNo',
      'is_deleted': 'eq.false',
      'select':     '*',
      'limit':      '1',
    });
    final list = List<Map<String, dynamic>>.from(res.data as List);
    return list.isNotEmpty ? FinanceVoucherHeader.fromJson(list.first) : null;
  }

  Future<List<FinanceVoucherLine>> getLines({
    required String clientId,
    required String companyId,
    required String transNo,
  }) async {
    final res = await DioClient.instance.get('/rid_finance_lines', queryParameters: {
      'client_id':  'eq.$clientId',
      'company_id': 'eq.$companyId',
      'trans_no':   'eq.$transNo',
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

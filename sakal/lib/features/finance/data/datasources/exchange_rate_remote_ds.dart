import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../models/exchange_rate_model.dart';

class ExchangeRateRemoteDs {
  static const _table = '/rim_exchange_rates';
  static const _select =
      'id,client_id,company_id,location_id,rate_date,'
      'from_currency,to_currency,buying_rate,selling_rate,mid_rate,source,is_deleted';

  Future<List<ExchangeRateModel>> getRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String rateDate,
  }) async {
    final res = await DioClient.instance.get(_table, queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'rate_date':   'eq.$rateDate',
      'is_deleted':  'eq.false',
      'select':      _select,
    });
    return (res.data as List)
        .map((e) => ExchangeRateModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // Returns all rates before beforeDate, ordered newest first.
  // Caller picks the most recent per currency.
  Future<List<ExchangeRateModel>> getPreviousRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String beforeDate,
  }) async {
    final res = await DioClient.instance.get(_table, queryParameters: {
      'client_id':   'eq.$clientId',
      'company_id':  'eq.$companyId',
      'location_id': 'eq.$locationId',
      'rate_date':   'lt.$beforeDate',
      'is_deleted':  'eq.false',
      'select':      _select,
      'order':       'rate_date.desc',
      'limit':       '200',
    });
    return (res.data as List)
        .map((e) => ExchangeRateModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveRates(List<Map<String, dynamic>> payload) async {
    await DioClient.instance.post(
      _table,
      data: payload,
      queryParameters: {
        'on_conflict': 'client_id,company_id,location_id,rate_date,from_currency,to_currency',
      },
      options: Options(headers: {'Prefer': 'resolution=merge-duplicates'}),
    );
  }

  Future<int> replicateToAllLocations({
    required String clientId,
    required String companyId,
    required String fromLocationId,
    required String rateDate,
    required String userId,
  }) async {
    final res = await DioClient.instance.post(
      '/rpc/fn_replicate_exchange_rates',
      data: {
        'p_client_id':     clientId,
        'p_company_id':    companyId,
        'p_from_location': fromLocationId,
        'p_rate_date':     rateDate,
        'p_replicated_by': userId,
      },
    );
    return res.data as int? ?? 0;
  }
}

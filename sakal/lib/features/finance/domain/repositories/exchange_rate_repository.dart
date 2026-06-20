import '../../data/models/exchange_rate_model.dart';

abstract class ExchangeRateRepository {
  Future<List<ExchangeRateModel>> getRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String rateDate,
  });

  Future<List<ExchangeRateModel>> getPreviousRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String beforeDate,
  });

  Future<void> saveRates(List<Map<String, dynamic>> payload);

  Future<int> replicateToAllLocations({
    required String clientId,
    required String companyId,
    required String fromLocationId,
    required String rateDate,
    required String userId,
  });
}

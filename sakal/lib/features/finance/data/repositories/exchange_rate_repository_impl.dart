import '../../domain/repositories/exchange_rate_repository.dart';
import '../datasources/exchange_rate_local_ds.dart';
import '../datasources/exchange_rate_remote_ds.dart';
import '../models/exchange_rate_model.dart';

class ExchangeRateRepositoryImpl implements ExchangeRateRepository {
  final ExchangeRateRemoteDs _remote;
  final ExchangeRateLocalDs  _local;
  final bool                 _offlineMode;

  ExchangeRateRepositoryImpl({
    required ExchangeRateRemoteDs remote,
    required ExchangeRateLocalDs  local,
    required bool                 offlineMode,
  })  : _remote      = remote,
        _local       = local,
        _offlineMode = offlineMode;

  @override
  Future<List<ExchangeRateModel>> getRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String rateDate,
  }) async {
    if (_offlineMode) {
      return _local.getRates(
        clientId:   clientId,
        companyId:  companyId,
        locationId: locationId,
        rateDate:   rateDate,
      );
    }
    final rates = await _remote.getRates(
      clientId:   clientId,
      companyId:  companyId,
      locationId: locationId,
      rateDate:   rateDate,
    );
    await _local.upsertRates(rates); // cache for next offline session
    return rates;
  }

  // Always remote — button is hidden when offline
  @override
  Future<List<ExchangeRateModel>> getPreviousRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String beforeDate,
  }) =>
      _remote.getPreviousRates(
        clientId:   clientId,
        companyId:  companyId,
        locationId: locationId,
        beforeDate: beforeDate,
      );

  // Always remote — button is hidden when offline
  @override
  Future<void> saveRates(List<Map<String, dynamic>> payload) =>
      _remote.saveRates(payload);

  // Always remote — button is hidden when offline
  @override
  Future<int> replicateToAllLocations({
    required String clientId,
    required String companyId,
    required String fromLocationId,
    required String rateDate,
    required String userId,
  }) =>
      _remote.replicateToAllLocations(
        clientId:       clientId,
        companyId:      companyId,
        fromLocationId: fromLocationId,
        rateDate:       rateDate,
        userId:         userId,
      );
}

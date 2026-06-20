import 'package:drift/drift.dart';
import '../../../../core/database/app_database.dart';
import '../models/exchange_rate_model.dart';

class ExchangeRateLocalDs {
  final AppDatabase _db;
  ExchangeRateLocalDs(this._db);

  Future<List<ExchangeRateModel>> getRates({
    required String clientId,
    required String companyId,
    required String locationId,
    required String rateDate,
  }) async {
    final rows = await (_db.select(_db.exchangeRateCache)
          ..where((t) =>
              t.clientId.equals(clientId) &
              t.companyId.equals(companyId) &
              t.locationId.equals(locationId) &
              t.rateDate.equals(rateDate) &
              t.isDeleted.equals(false)))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<void> upsertRates(List<ExchangeRateModel> rates) async {
    await _db.batch((batch) {
      for (final r in rates) {
        batch.insertOnConflictUpdate(
          _db.exchangeRateCache,
          ExchangeRateCacheEntry(
            id:           r.id,
            clientId:     r.clientId,
            companyId:    r.companyId,
            locationId:   r.locationId,
            rateDate:     r.rateDate,
            fromCurrency: r.fromCurrency,
            toCurrency:   r.toCurrency,
            buyingRate:   r.buyingRate,
            sellingRate:  r.sellingRate,
            source:       r.source,
            isDeleted:    r.isDeleted,
            syncedAt:     DateTime.now(),
          ),
        );
      }
    });
  }

  ExchangeRateModel _toModel(ExchangeRateCacheEntry e) => ExchangeRateModel(
        id:           e.id,
        clientId:     e.clientId,
        companyId:    e.companyId,
        locationId:   e.locationId,
        rateDate:     e.rateDate,
        fromCurrency: e.fromCurrency,
        toCurrency:   e.toCurrency,
        buyingRate:   e.buyingRate,
        sellingRate:  e.sellingRate,
        source:       e.source,
        isDeleted:    e.isDeleted,
      );
}

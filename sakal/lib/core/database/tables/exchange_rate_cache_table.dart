import 'package:drift/drift.dart';

@DataClassName('ExchangeRateCacheEntry')
class ExchangeRateCache extends Table {
  TextColumn     get id           => text()();
  TextColumn     get clientId     => text()();
  TextColumn     get companyId    => text()();
  TextColumn     get locationId   => text()();
  TextColumn     get rateDate     => text()(); // 'YYYY-MM-DD'
  TextColumn     get fromCurrency => text()();
  TextColumn     get toCurrency   => text()();
  RealColumn     get buyingRate   => real()();
  RealColumn     get sellingRate  => real()();
  // Independently user-entered (migration 179) — no longer (buying+
  // selling)/2. Defaulted for existing local DBs upgrading across the
  // schema bump; this is a pure server-synced cache, so a stale 0 here
  // only lasts until the next sync overwrites it.
  RealColumn     get exchangeRate => real().withDefault(const Constant(0))();
  TextColumn     get source       => text().withDefault(const Constant('MANUAL'))();
  BoolColumn     get isDeleted    => boolean().withDefault(const Constant(false))();
  DateTimeColumn get syncedAt     => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

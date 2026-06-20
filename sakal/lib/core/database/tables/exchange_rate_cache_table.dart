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
  TextColumn     get source       => text().withDefault(const Constant('MANUAL'))();
  BoolColumn     get isDeleted    => boolean().withDefault(const Constant(false))();
  DateTimeColumn get syncedAt     => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

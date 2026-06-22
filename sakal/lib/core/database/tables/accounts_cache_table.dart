import 'package:drift/drift.dart';

@DataClassName('AccountsCacheEntry')
class AccountsCache extends Table {
  TextColumn get id             => text()();
  TextColumn get clientId       => text()();
  TextColumn get companyId      => text()();
  TextColumn get accountCode    => text()();
  TextColumn get accountName    => text()();
  TextColumn get accountNature  => text()();
  TextColumn get parentName     => text().withDefault(const Constant(''))();
  TextColumn get accountCurrency => text().withDefault(const Constant(''))();
  BoolColumn get isActive       => boolean().withDefault(const Constant(true))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

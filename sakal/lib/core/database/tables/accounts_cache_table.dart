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

  // Added for offline Customer detail prefill (Sales Invoice's
  // getCustomerDetails) — nullable, populated only when the account was
  // cached via a fetch that requested these fields.
  RealColumn get creditLimit      => real().nullable()();
  IntColumn  get creditDays       => integer().nullable()();
  BoolColumn get isCreditBlocked  => boolean().nullable()();
  TextColumn get phone            => text().nullable()();
  TextColumn get email            => text().nullable()();
  TextColumn get addressLine1     => text().nullable()();
  TextColumn get addressLine2     => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

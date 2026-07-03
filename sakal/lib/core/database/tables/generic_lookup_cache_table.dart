import 'package:drift/drift.dart';

/// One shared cache table for simple reference-data lookups that don't need
/// dedicated typed columns — a picker list is read as-is (a Map), never
/// computed against at the SQL level. [cacheKey] discriminates which lookup
/// a row belongs to (e.g. 'CURRENCIES', 'PO_TAX_GROUPS', 'COUNTRIES').
/// [dataJson] holds the full raw row exactly as PostgREST returned it, so
/// callers get back the same shape they'd get online.
@DataClassName('LookupCacheEntry')
class GenericLookupCache extends Table {
  TextColumn get cacheKey    => text()();
  TextColumn get id          => text()();
  TextColumn get clientId    => text().withDefault(const Constant(''))();
  TextColumn get companyId   => text().withDefault(const Constant(''))();
  TextColumn get label       => text().withDefault(const Constant(''))(); // for ordering without decoding JSON
  TextColumn get parentId    => text().withDefault(const Constant(''))(); // e.g. city -> division -> country chain
  IntColumn  get sortOrder   => integer().withDefault(const Constant(0))();
  TextColumn get dataJson    => text().withDefault(const Constant('{}'))();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {cacheKey, id};
}

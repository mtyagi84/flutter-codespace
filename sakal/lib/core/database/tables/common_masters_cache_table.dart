import 'package:drift/drift.dart';

@DataClassName('CommonMasterTypeCacheEntry')
class CommonMasterTypesCache extends Table {
  TextColumn get id       => text()();
  TextColumn get typeKey  => text()();
  TextColumn get typeName => text()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CommonMasterCacheEntry')
class CommonMastersCache extends Table {
  TextColumn  get id          => text()();
  TextColumn  get clientId    => text()();
  TextColumn  get companyId   => text()();
  TextColumn  get typeId      => text()();
  TextColumn  get description => text()();
  TextColumn  get shortName   => text().nullable()();
  IntColumn   get sortOrder   => integer().withDefault(const Constant(0))();
  BoolColumn  get isActive    => boolean().withDefault(const Constant(true))();
  BoolColumn  get isDeleted   => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

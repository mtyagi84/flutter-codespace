import 'package:drift/drift.dart';

/// tax_group_id -> [tax_id] membership (rim_tax_group_members). Relational
/// bulk lookup — a blob cache can't answer "which taxes belong to this
/// group" without decoding every row, so this gets its own small table.
@DataClassName('TaxGroupMemberCacheEntry')
class TaxGroupMembersCache extends Table {
  TextColumn get taxGroupId => text()();
  TextColumn get taxId      => text()();
  DateTimeColumn get cachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {taxGroupId, taxId};
}

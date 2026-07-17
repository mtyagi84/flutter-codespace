import 'package:drift/drift.dart';

/// One row per user-facing master-data sync module (see
/// core/sync/master_data_modules.dart) — backs the Offline Settings
/// screen's "enabled" checkbox and "Last synced" / row-count display.
/// Per-device, not synced to the server (this table itself is never
/// pushed/pulled — it's local UI state about the local cache).
@DataClassName('ModuleSyncStatusEntry')
class ModuleSyncStatusCache extends Table {
  TextColumn get moduleKey     => text()();
  BoolColumn get enabled       => boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  IntColumn  get rowCount      => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {moduleKey};
}

import 'package:drift/drift.dart';
import '../app_database.dart';

/// Local datasource for [ModuleSyncStatusCache] — backs the Offline
/// Settings screen's per-module "enabled" checkbox and "Last synced" /
/// row-count display.
///
/// setEnabled/recordSync each touch only ONE column — deliberately NOT
/// implemented via insertOnConflictUpdate (which would replace the whole
/// row with the companion's values, silently resetting whichever field
/// wasn't being touched, e.g. wiping lastSyncedAt back to null on a plain
/// enable/disable toggle). Check-then-insert-or-partial-update instead.
class ModuleSyncStatusLocalDs {
  final AppDatabase _db;
  ModuleSyncStatusLocalDs(this._db);

  Stream<List<ModuleSyncStatusEntry>> watchAll() {
    return _db.select(_db.moduleSyncStatusCache).watch();
  }

  Future<ModuleSyncStatusEntry?> get(String moduleKey) {
    return (_db.select(_db.moduleSyncStatusCache)..where((t) => t.moduleKey.equals(moduleKey))).getSingleOrNull();
  }

  Future<void> setEnabled(String moduleKey, bool enabled) async {
    final existing = await get(moduleKey);
    if (existing == null) {
      await _db.into(_db.moduleSyncStatusCache).insert(
            ModuleSyncStatusCacheCompanion.insert(moduleKey: moduleKey, enabled: Value(enabled)),
          );
    } else {
      await (_db.update(_db.moduleSyncStatusCache)..where((t) => t.moduleKey.equals(moduleKey)))
          .write(ModuleSyncStatusCacheCompanion(enabled: Value(enabled)));
    }
  }

  Future<void> recordSync(String moduleKey, int rowCount) async {
    final existing = await get(moduleKey);
    final now = DateTime.now();
    if (existing == null) {
      await _db.into(_db.moduleSyncStatusCache).insert(
            ModuleSyncStatusCacheCompanion.insert(moduleKey: moduleKey, lastSyncedAt: Value(now), rowCount: Value(rowCount)),
          );
    } else {
      await (_db.update(_db.moduleSyncStatusCache)..where((t) => t.moduleKey.equals(moduleKey)))
          .write(ModuleSyncStatusCacheCompanion(lastSyncedAt: Value(now), rowCount: Value(rowCount)));
    }
  }
}

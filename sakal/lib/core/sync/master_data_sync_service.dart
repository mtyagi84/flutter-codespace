import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../database/datasources/module_sync_status_local_ds.dart';
import '../providers/session_provider.dart';
import 'master_data_modules.dart';

/// Download-side of the Master-Data Sync facility — deliberately a
/// SIBLING to SyncEngine (lib/core/sync/sync_engine.dart), not a change to
/// it. SyncEngine/PendingSyncQueue is a write-queue for outbound documents
/// (one row per pending document, retried on failure); this is a
/// read-cache warm-up with no queue and no retry-count. Mixing the two
/// would force document-shaped columns onto a concept that has none.
///
/// No periodic background timer — per the binding offline-design memory's
/// own reasoning for outbound sync (unstable rural connections make a
/// silent timer produce repeated failures with no clear freshness signal),
/// sync happens once at online login (background, non-blocking) or on
/// explicit "Refresh"/"Refresh All" from the Offline Settings screen.
class MasterDataSyncService {
  final AppDatabase? _db; // null on web, same convention as SyncEngine
  MasterDataSyncService(this._db);

  // Deliberately takes no Ref/WidgetRef — a service class's dependencies
  // are injected once, at construction (via masterDataSyncServiceProvider
  // below), never threaded through its public methods. WidgetRef (from a
  // widget's State) and Ref (a provider callback's own ref) are distinct,
  // unrelated types in Riverpod — a method taking one could never be
  // called correctly from the other, which is exactly why SyncEngine
  // (lib/core/sync/sync_engine.dart) never accepts either.
  Future<int> syncModule(MasterDataModule module, UserSession session) async {
    if (kIsWeb || _db == null) return 0;
    final count = await module.sync(_db, session);
    await ModuleSyncStatusLocalDs(_db).recordSync(module.key, count);
    return count;
  }

  /// Syncs every module whose ModuleSyncStatusCache row is enabled (or has
  /// never been synced yet, i.e. no row at all — enabled defaults true).
  /// Per-module failures are swallowed so one module's connectivity hiccup
  /// never blocks the others or surfaces as a blocking error to the caller
  /// — the module's lastSyncedAt simply stays at its previous value.
  Future<void> syncEnabledModules(
    UserSession session, {
    void Function(String moduleKey, int index, int total)? onProgress,
  }) async {
    if (kIsWeb || _db == null) return;
    final statusDs = ModuleSyncStatusLocalDs(_db);
    for (var i = 0; i < masterDataModules.length; i++) {
      final module = masterDataModules[i];
      final status = await statusDs.get(module.key);
      final enabled = status?.enabled ?? true;
      if (!enabled) continue;
      onProgress?.call(module.key, i, masterDataModules.length);
      try {
        await syncModule(module, session);
      } catch (_) {
        // Swallowed by design — see class doc. The module's own
        // lastSyncedAt is simply left unchanged by recordSync not running.
      }
    }
  }
}

final masterDataSyncServiceProvider = Provider<MasterDataSyncService>(
  (ref) => MasterDataSyncService(kIsWeb ? null : ref.watch(appDatabaseProvider)),
);

/// Watched by MasterDataSyncIndicator (core/widgets/) to show a small
/// non-blocking "Refreshing offline data…" badge while the background
/// post-login sync (triggered from login_screen.dart) is in flight.
final masterDataSyncInProgressProvider = StateProvider<bool>((ref) => false);

/// Runs [MasterDataSyncService.syncEnabledModules] with
/// [masterDataSyncInProgressProvider] bracketing it, so the indicator
/// reflects real progress regardless of which caller triggered the sync.
/// Takes a [WidgetRef] — both current callers (login_screen.dart,
/// offline_settings_screen.dart) are widgets, never a bare provider Ref.
Future<void> runBackgroundMasterDataSync(WidgetRef ref, UserSession session) async {
  ref.read(masterDataSyncInProgressProvider.notifier).state = true;
  try {
    await ref.read(masterDataSyncServiceProvider).syncEnabledModules(session);
  } finally {
    ref.read(masterDataSyncInProgressProvider.notifier).state = false;
  }
}

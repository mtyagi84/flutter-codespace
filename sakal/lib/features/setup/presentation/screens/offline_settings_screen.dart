import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/module_sync_status_local_ds.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/sync/master_data_modules.dart';
import '../../../../core/sync/master_data_sync_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';

/// Offline Settings — the "Selective Sync — Module-Level" screen speced
/// in the binding offline-design memory (agreed 2026-06-18) but never
/// built until now. Device-local config, not tenant data — no
/// ScreenPermissionMixin, no sidebar menu entry, same precedent as
/// change_password_screen.dart (reached only from the top-bar avatar
/// menu). Lets a user enable offline mode for this device and sync/refresh
/// each master-data module before disconnecting.
class OfflineSettingsScreen extends ConsumerStatefulWidget {
  const OfflineSettingsScreen({super.key});

  @override
  ConsumerState<OfflineSettingsScreen> createState() => _OfflineSettingsScreenState();
}

class _OfflineSettingsScreenState extends ConsumerState<OfflineSettingsScreen> {
  bool _deviceOfflineEnabled = LocalStorage.deviceOfflineEnabled;
  final Set<String> _syncingKeys = {};
  bool _syncingAll = false;
  String? _error;

  Future<void> _toggleDeviceOffline(bool value) async {
    setState(() => _deviceOfflineEnabled = value);
    await LocalStorage.setDeviceOfflineEnabled(value);
  }

  Future<void> _refreshModule(MasterDataModule module) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    setState(() { _syncingKeys.add(module.key); _error = null; });
    try {
      await ref.read(masterDataSyncServiceProvider).syncModule(module, session);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not sync ${module.label}: $e');
    } finally {
      if (mounted) setState(() => _syncingKeys.remove(module.key));
    }
  }

  Future<void> _refreshAll() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    setState(() { _syncingAll = true; _error = null; });
    try {
      await ref.read(masterDataSyncServiceProvider).syncEnabledModules(session);
    } catch (e) {
      if (mounted) setState(() => _error = 'Sync failed: $e');
    } finally {
      if (mounted) setState(() => _syncingAll = false);
    }
  }

  String _relativeTime(DateTime? t) {
    if (t == null) return 'Never synced';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'Last synced: just now';
    if (diff.inMinutes < 60) return 'Last synced: ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last synced: ${diff.inHours}h ago';
    return 'Last synced: ${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    const title = Text('Offline Settings',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary));
    final refreshAllButton = FilledButton.icon(
      onPressed: _syncingAll ? null : _refreshAll,
      icon: _syncingAll
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.sync, size: 18),
      label: const Text('Refresh All'),
    );

    if (kIsWeb) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Offline mode is not available on Web.', style: TextStyle(color: AppColors.textSecondary)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  title,
                  const SizedBox(height: 10),
                  Row(children: [refreshAllButton]),
                ])
              : Row(children: [Expanded(child: title), refreshAllButton]),
        ),
        const Divider(height: 20),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: AppColors.negative)),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable offline mode for this device'),
                    subtitle: const Text('Lets this device work without connectivity, using the master data synced below.'),
                    value: _deviceOfflineEnabled,
                    onChanged: _toggleDeviceOffline,
                  ),
                  const SizedBox(height: 12),
                  const Text('Master Data', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...masterDataModules.map(_buildModuleRow),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModuleRow(MasterDataModule module) {
    final db = ref.watch(appDatabaseProvider);
    final syncing = _syncingKeys.contains(module.key);
    return StreamBuilder(
      stream: ModuleSyncStatusLocalDs(db).watchAll(),
      builder: (context, snapshot) {
        final matches = snapshot.data?.where((s) => s.moduleKey == module.key) ?? const [];
        final status = matches.isNotEmpty ? matches.first : null;
        final enabled = status?.enabled ?? true;
        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
          child: ListTile(
            leading: Checkbox(
              value: enabled,
              onChanged: (v) => ModuleSyncStatusLocalDs(db).setEnabled(module.key, v ?? true),
            ),
            title: Row(children: [
              Icon(module.icon, size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(module.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            subtitle: Text(
              '${_relativeTime(status?.lastSyncedAt)} · ${status?.rowCount ?? 0} records',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            trailing: IconButton(
              tooltip: 'Refresh ${module.label}',
              icon: syncing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 20),
              onPressed: syncing ? null : () => _refreshModule(module),
            ),
          ),
        );
      },
    );
  }
}

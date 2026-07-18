import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../sync/master_data_sync_service.dart';

/// Small non-blocking badge shown while the background post-login
/// master-data sync (see login_screen.dart / master_data_sync_service.dart)
/// is in flight. No modal, no snackbar — silently disappears on
/// completion, same silent/badge-only style as SyncStatusIndicator.
class MasterDataSyncIndicator extends ConsumerWidget {
  const MasterDataSyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final syncing = ref.watch(masterDataSyncInProgressProvider);
    if (!syncing) return const SizedBox.shrink();

    return Tooltip(
      message: 'Refreshing offline data…',
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          // Was a navy-on-near-white tint, correct only when this badge
          // sat on a plain white TopBar. Switched to white-on-translucent
          // so it stays legible now that TopBar is themed dark — this
          // badge lives ONLY in TopBar's actions, so it never needs to
          // adapt to a light background at all.
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            SizedBox(width: 6),
            Text('Refreshing offline data…', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

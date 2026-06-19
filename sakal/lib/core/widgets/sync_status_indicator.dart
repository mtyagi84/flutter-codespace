import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../sync/sync_engine.dart';

class SyncStatusIndicator extends ConsumerWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // SQLite WASM not loaded on Flutter Web — skip entirely
    if (kIsWeb) return const SizedBox.shrink();

    return ref.watch(pendingSyncCountProvider).when(
      data: (count) {
        if (count == 0) return const SizedBox.shrink();
        return Tooltip(
          message: '$count document${count == 1 ? '' : 's'} pending sync',
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFE65100).withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: const Color(0xFFE65100).withOpacity(0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sync_problem_outlined,
                    size: 13, color: Color(0xFFE65100)),
                const SizedBox(width: 4),
                Text(
                  '$count pending',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFE65100),
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

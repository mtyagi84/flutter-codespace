import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../sync/sync_engine.dart';

/// Small chip shown on a document that's queued for sync but hasn't reached
/// the server yet. Same visual language as [OfflineBanner].
///
/// Two ways to use it:
///  - `PendingSyncBadge(documentType: ..., documentId: ...)` — reactive, one
///    Drift stream, for a single entry screen's header.
///  - `PendingSyncBadge.static(isPending: ...)` — plain flag, for list rows,
///    where the parent screen already resolved every row's pending state in
///    one bulk query (`SyncEngine.pendingDocumentIds`). Reusing the reactive
///    form per row would open one Drift stream subscription per row.
class PendingSyncBadge extends ConsumerWidget {
  // Unused (empty string) when constructed via .static — only the reactive
  // constructor's watchIsPending() call in build() reads these.
  final String documentType;
  final String documentId;
  final bool? _staticIsPending;

  const PendingSyncBadge({super.key, required this.documentType, required this.documentId})
      : _staticIsPending = null;

  const PendingSyncBadge.static({super.key, required bool isPending})
      : documentType = '',
        documentId = '',
        _staticIsPending = isPending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_staticIsPending != null) return _chip(_staticIsPending);
    return StreamBuilder<bool>(
      stream: ref.watch(syncEngineProvider).watchIsPending(documentType, documentId),
      builder: (context, snapshot) => _chip(snapshot.data ?? false),
    );
  }

  Widget _chip(bool isPending) {
    if (!isPending) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFE65100).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.sync_problem_rounded, size: 12, color: Color(0xFFE65100)),
        SizedBox(width: 4),
        Text('Pending sync',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFE65100))),
      ]),
    );
  }
}

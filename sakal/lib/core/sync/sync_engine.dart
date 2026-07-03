import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../network/dio_client.dart';

class SyncResult {
  final int total;
  final int synced;
  final List<String> errors;

  const SyncResult({
    required this.total,
    required this.synced,
    required this.errors,
  });

  bool get allSynced => errors.isEmpty;
}

class SyncEngine {
  final AppDatabase _db;
  SyncEngine(this._db);

  Future<int> pendingCount() async {
    final rows = await (_db.select(_db.pendingSyncQueue)
          ..where((t) => t.synced.equals(false)))
        .get();
    return rows.length;
  }

  /// Bulk lookup for list screens — one query to annotate every visible row,
  /// instead of one query per row.
  Future<Set<String>> pendingDocumentIds(String documentType) async {
    final rows = await (_db.select(_db.pendingSyncQueue)
          ..where((t) => t.documentType.equals(documentType) & t.synced.equals(false)))
        .get();
    return rows.map((r) => r.documentId).toSet();
  }

  /// Reactive lookup for a single document — used by entry screens so the
  /// pending badge disappears the moment SyncScreen syncs it, without a
  /// manual refresh.
  Stream<bool> watchIsPending(String documentType, String documentId) {
    return (_db.select(_db.pendingSyncQueue)
          ..where((t) =>
              t.documentType.equals(documentType) &
              t.documentId.equals(documentId) &
              t.synced.equals(false)))
        .watch()
        .map((rows) => rows.isNotEmpty);
  }

  /// Syncs all pending documents in chronological order.
  /// Documents that fail stay PENDING with incremented retry_count.
  Future<SyncResult> syncAll({
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = await (_db.select(_db.pendingSyncQueue)
          ..where((t) => t.synced.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    int synced = 0;
    final errors = <String>[];

    for (int i = 0; i < pending.length; i++) {
      final doc = pending[i];
      try {
        await DioClient.instance.post(
          doc.endpoint,
          data: jsonDecode(doc.payload) as Map<String, dynamic>,
        );
        await (_db.update(_db.pendingSyncQueue)
              ..where((t) => t.id.equals(doc.id)))
            .write(const PendingSyncQueueCompanion(synced: Value(true)));
        synced++;
      } catch (_) {
        await (_db.update(_db.pendingSyncQueue)
              ..where((t) => t.id.equals(doc.id)))
            .write(PendingSyncQueueCompanion(
                retryCount: Value(doc.retryCount + 1)));
        errors.add('${doc.documentType} ${doc.documentId}');
      }
      onProgress?.call(i + 1, pending.length);
    }

    return SyncResult(total: pending.length, synced: synced, errors: errors);
  }

  /// Enqueues a new document for offline sync.
  Future<void> enqueue({
    required String documentType,
    required String documentId,
    required String endpoint,
    required Map<String, dynamic> payload,
  }) async {
    await _db.into(_db.pendingSyncQueue).insert(PendingSyncQueueCompanion.insert(
      documentType: documentType,
      documentId:   documentId,
      endpoint:     endpoint,
      payload:      jsonEncode(payload),
    ));
  }
}

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => SyncEngine(ref.watch(appDatabaseProvider)),
);

final pendingSyncCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.read(syncEngineProvider).pendingCount(),
);

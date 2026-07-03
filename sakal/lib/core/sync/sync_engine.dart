import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

// Drift is not available on Flutter Web (requires web-worker setup) — [_db] is
// null there. Web sessions are always online, so every read-only method below
// degrades to an empty/false result instead of touching Drift; the write
// methods (enqueue/syncAll) are unreachable on web since offline mode is never
// offered there, and assert that assumption rather than fail silently.
class SyncEngine {
  final AppDatabase? _db;
  SyncEngine(this._db);

  Future<int> pendingCount() async {
    final db = _db;
    if (db == null) return 0;
    final rows = await (db.select(db.pendingSyncQueue)
          ..where((t) => t.synced.equals(false)))
        .get();
    return rows.length;
  }

  /// Bulk lookup for list screens — one query to annotate every visible row,
  /// instead of one query per row.
  Future<Set<String>> pendingDocumentIds(String documentType) async {
    final db = _db;
    if (db == null) return {};
    final rows = await (db.select(db.pendingSyncQueue)
          ..where((t) => t.documentType.equals(documentType) & t.synced.equals(false)))
        .get();
    return rows.map((r) => r.documentId).toSet();
  }

  /// Reactive lookup for a single document — used by entry screens so the
  /// pending badge disappears the moment SyncScreen syncs it, without a
  /// manual refresh.
  Stream<bool> watchIsPending(String documentType, String documentId) {
    final db = _db;
    if (db == null) return Stream.value(false);
    return (db.select(db.pendingSyncQueue)
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
    final db = _db;
    if (db == null) return const SyncResult(total: 0, synced: 0, errors: []);
    final pending = await (db.select(db.pendingSyncQueue)
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
        await (db.update(db.pendingSyncQueue)
              ..where((t) => t.id.equals(doc.id)))
            .write(const PendingSyncQueueCompanion(synced: Value(true)));
        synced++;
      } catch (_) {
        await (db.update(db.pendingSyncQueue)
              ..where((t) => t.id.equals(doc.id)))
            .write(PendingSyncQueueCompanion(
                retryCount: Value(doc.retryCount + 1)));
        errors.add('${doc.documentType} ${doc.documentId}');
      }
      onProgress?.call(i + 1, pending.length);
    }

    return SyncResult(total: pending.length, synced: synced, errors: errors);
  }

  /// Enqueues a new document for offline sync. Never called on web — offline
  /// mode isn't offered there, so a null [_db] here means a real bug upstream.
  Future<void> enqueue({
    required String documentType,
    required String documentId,
    required String endpoint,
    required Map<String, dynamic> payload,
  }) async {
    final db = _db;
    if (db == null) {
      throw StateError('SyncEngine.enqueue called with no local database (web platform).');
    }
    await db.into(db.pendingSyncQueue).insert(PendingSyncQueueCompanion.insert(
      documentType: documentType,
      documentId:   documentId,
      endpoint:     endpoint,
      payload:      jsonEncode(payload),
    ));
  }
}

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => SyncEngine(kIsWeb ? null : ref.watch(appDatabaseProvider)),
);

final pendingSyncCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.read(syncEngineProvider).pendingCount(),
);

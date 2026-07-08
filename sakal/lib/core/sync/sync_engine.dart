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
        final payloadMap = jsonDecode(doc.payload) as Map<String, dynamic>;
        final res = await DioClient.instance.post(doc.endpoint, data: payloadMap);

        // Every fn_save_* RPC returns the real assigned document number as a
        // plain string — re-key the local cache row from the temporary
        // LOCAL-... id to that real number so the cache doesn't keep living
        // under a placeholder forever, disconnected from the real record.
        final newId = res.data is String ? res.data as String : null;
        if (newId != null && newId != doc.documentId) {
          final header = payloadMap['p_header'] as Map<String, dynamic>? ?? const {};
          await _renameLocalDocument(
            doc.documentType, doc.documentId, newId,
            header['client_id'] as String? ?? '',
            header['company_id'] as String? ?? '',
          );
        }

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

  /// Re-keys every cache row for a just-synced document from its temporary
  /// [oldId] (a `generateLocalId()` placeholder) to the [newId] the server
  /// just assigned — header + lines + every child table in one go per table
  /// (a bulk rename, not per-row). Without this, a document saved offline
  /// stays cached under its placeholder id forever, even after a successful
  /// sync, disconnected from the real record the server now holds.
  Future<void> _renameLocalDocument(
    String documentType, String oldId, String newId, String clientId, String companyId,
  ) async {
    final db = _db;
    if (db == null) return;

    switch (documentType) {
      case 'GRN':
        await (db.update(db.grnHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.grnNo.equals(oldId)))
            .write(GrnHeadersCacheCompanion(grnNo: Value(newId)));
        await (db.update(db.grnLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.grnNo.equals(oldId)))
            .write(GrnLinesCacheCompanion(grnNo: Value(newId)));
        await (db.update(db.grnChargeLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.grnNo.equals(oldId)))
            .write(GrnChargeLinesCacheCompanion(grnNo: Value(newId)));
        break;

      case 'PURCHASE_ORDER':
        await (db.update(db.purchaseOrdersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.orderNo.equals(oldId)))
            .write(PurchaseOrdersCacheCompanion(orderNo: Value(newId)));
        await (db.update(db.purchaseOrderLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.orderNo.equals(oldId)))
            .write(PurchaseOrderLinesCacheCompanion(orderNo: Value(newId)));
        await (db.update(db.poChargeLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.orderNo.equals(oldId)))
            .write(PoChargeLinesCacheCompanion(orderNo: Value(newId)));
        await (db.update(db.poPaymentTermsCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.orderNo.equals(oldId)))
            .write(PoPaymentTermsCacheCompanion(orderNo: Value(newId)));
        break;

      case 'FINANCE_VOUCHER':
        await (db.update(db.financeVoucherHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.transNo.equals(oldId)))
            .write(FinanceVoucherHeadersCacheCompanion(transNo: Value(newId)));
        await (db.update(db.financeVoucherLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.transNo.equals(oldId)))
            .write(FinanceVoucherLinesCacheCompanion(transNo: Value(newId)));
        break;

      case 'MATERIAL_REQUISITION':
        await (db.update(db.materialRequisitionHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.requisitionNo.equals(oldId)))
            .write(MaterialRequisitionHeadersCacheCompanion(requisitionNo: Value(newId)));
        await (db.update(db.materialRequisitionLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.requisitionNo.equals(oldId)))
            .write(MaterialRequisitionLinesCacheCompanion(requisitionNo: Value(newId)));
        break;

      case 'MATERIAL_ISSUE':
        await (db.update(db.materialIssueHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.issueNo.equals(oldId)))
            .write(MaterialIssueHeadersCacheCompanion(issueNo: Value(newId)));
        await (db.update(db.materialIssueLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.issueNo.equals(oldId)))
            .write(MaterialIssueLinesCacheCompanion(issueNo: Value(newId)));
        break;

      case 'PURCHASE_RETURN':
        await (db.update(db.purchaseReturnHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.returnNo.equals(oldId)))
            .write(PurchaseReturnHeadersCacheCompanion(returnNo: Value(newId)));
        await (db.update(db.purchaseReturnLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.returnNo.equals(oldId)))
            .write(PurchaseReturnLinesCacheCompanion(returnNo: Value(newId)));
        await (db.update(db.purchaseReturnChargeLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.returnNo.equals(oldId)))
            .write(PurchaseReturnChargeLinesCacheCompanion(returnNo: Value(newId)));
        break;

      case 'STOCK_TRANSFER_REQUEST':
        await (db.update(db.stockTransferRequestHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.requestNo.equals(oldId)))
            .write(StockTransferRequestHeadersCacheCompanion(requestNo: Value(newId)));
        await (db.update(db.stockTransferRequestLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.requestNo.equals(oldId)))
            .write(StockTransferRequestLinesCacheCompanion(requestNo: Value(newId)));
        break;

      case 'STOCK_TRANSFER':
        await (db.update(db.stockTransferHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.transferNo.equals(oldId)))
            .write(StockTransferHeadersCacheCompanion(transferNo: Value(newId)));
        await (db.update(db.stockTransferLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.transferNo.equals(oldId)))
            .write(StockTransferLinesCacheCompanion(transferNo: Value(newId)));
        await (db.update(db.stockTransferChargeLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.transferNo.equals(oldId)))
            .write(StockTransferChargeLinesCacheCompanion(transferNo: Value(newId)));
        break;

      case 'STOCK_RECEIPT':
        await (db.update(db.stockReceiptHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.receiptNo.equals(oldId)))
            .write(StockReceiptHeadersCacheCompanion(receiptNo: Value(newId)));
        await (db.update(db.stockReceiptLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.receiptNo.equals(oldId)))
            .write(StockReceiptLinesCacheCompanion(receiptNo: Value(newId)));
        break;

      case 'STOCK_ADJUSTMENT':
        await (db.update(db.stockAdjustmentHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.adjustmentNo.equals(oldId)))
            .write(StockAdjustmentHeadersCacheCompanion(adjustmentNo: Value(newId)));
        await (db.update(db.stockAdjustmentLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.adjustmentNo.equals(oldId)))
            .write(StockAdjustmentLinesCacheCompanion(adjustmentNo: Value(newId)));
        break;

      case 'OPENING_STOCK':
        await (db.update(db.openingStockHeadersCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.openingNo.equals(oldId)))
            .write(OpeningStockHeadersCacheCompanion(openingNo: Value(newId)));
        await (db.update(db.openingStockLinesCache)
              ..where((t) => t.clientId.equals(clientId) & t.companyId.equals(companyId) & t.openingNo.equals(oldId)))
            .write(OpeningStockLinesCacheCompanion(openingNo: Value(newId)));
        break;
    }
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

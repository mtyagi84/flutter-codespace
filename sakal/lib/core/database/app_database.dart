import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tables/pending_sync_queue.dart';
import 'tables/exchange_rate_cache_table.dart';
import 'tables/accounts_cache_table.dart';
import 'tables/finance_voucher_cache_tables.dart';
import 'tables/common_masters_cache_table.dart';
import 'tables/products_cache_table.dart';
import 'tables/purchase_order_cache_tables.dart';
import 'tables/generic_lookup_cache_table.dart';
import 'tables/grn_cache_tables.dart';
import 'tables/material_requisition_cache_tables.dart';
import 'tables/material_issue_cache_tables.dart';
import 'tables/purchase_return_cache_tables.dart';
import 'tables/stock_transfer_request_cache_tables.dart';
import 'tables/stock_transfer_cache_tables.dart';
import 'tables/stock_receipt_cache_tables.dart';
import 'tables/stock_adjustment_cache_tables.dart';
import 'tables/opening_stock_cache_tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  PendingSyncQueue,
  ExchangeRateCache,
  AccountsCache,
  FinanceVoucherHeadersCache,
  FinanceVoucherLinesCache,
  CommonMasterTypesCache,
  CommonMastersCache,
  ProductsCache,
  PurchaseOrdersCache,
  PurchaseOrderLinesCache,
  PoChargeLinesCache,
  PoPaymentTermsCache,
  GenericLookupCache,
  GrnHeadersCache,
  GrnLinesCache,
  GrnChargeLinesCache,
  MaterialRequisitionHeadersCache,
  MaterialRequisitionLinesCache,
  MaterialIssueHeadersCache,
  MaterialIssueLinesCache,
  PurchaseReturnHeadersCache,
  PurchaseReturnLinesCache,
  PurchaseReturnChargeLinesCache,
  StockTransferRequestHeadersCache,
  StockTransferRequestLinesCache,
  StockTransferHeadersCache,
  StockTransferLinesCache,
  StockTransferChargeLinesCache,
  StockReceiptHeadersCache,
  StockReceiptLinesCache,
  StockAdjustmentHeadersCache,
  StockAdjustmentLinesCache,
  OpeningStockHeadersCache,
  OpeningStockLinesCache,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sakal_local'));

  @override
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(exchangeRateCache);
          if (from < 3) await m.createTable(accountsCache);
          if (from < 4) {
            await m.createTable(financeVoucherHeadersCache);
            await m.createTable(financeVoucherLinesCache);
          }
          if (from < 5) {
            await m.createTable(commonMasterTypesCache);
            await m.createTable(commonMastersCache);
          }
          if (from < 6) await m.createTable(productsCache);
          if (from < 7) {
            await m.createTable(purchaseOrdersCache);
            await m.createTable(purchaseOrderLinesCache);
            await m.createTable(poChargeLinesCache);
          }
          if (from < 8) await m.createTable(genericLookupCache);
          // v9 drops PurchaseOrdersCache.paymentTerms (superseded by
          // PoPaymentTermsCache, mirroring PoChargeLinesCache) — the column
          // is simply left as an unused orphan in the underlying SQLite file
          // on upgrade rather than migrated, since this is a device-local
          // cache rebuilt from the server, not a data store of record.
          if (from < 9) await m.createTable(poPaymentTermsCache);
          if (from < 10) {
            await m.createTable(grnHeadersCache);
            await m.createTable(grnLinesCache);
            await m.createTable(grnChargeLinesCache);
          }
          if (from < 11) {
            await m.createTable(materialRequisitionHeadersCache);
            await m.createTable(materialRequisitionLinesCache);
            await m.createTable(materialIssueHeadersCache);
            await m.createTable(materialIssueLinesCache);
            await m.createTable(purchaseReturnHeadersCache);
            await m.createTable(purchaseReturnLinesCache);
            await m.createTable(purchaseReturnChargeLinesCache);
            await m.createTable(stockTransferRequestHeadersCache);
            await m.createTable(stockTransferRequestLinesCache);
            await m.createTable(stockTransferHeadersCache);
            await m.createTable(stockTransferLinesCache);
            await m.createTable(stockTransferChargeLinesCache);
            await m.createTable(stockReceiptHeadersCache);
            await m.createTable(stockReceiptLinesCache);
          }
          if (from < 12) {
            await m.createTable(stockAdjustmentHeadersCache);
            await m.createTable(stockAdjustmentLinesCache);
          }
          if (from < 13) {
            await m.createTable(openingStockHeadersCache);
            await m.createTable(openingStockLinesCache);
          }
        },
      );
}

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

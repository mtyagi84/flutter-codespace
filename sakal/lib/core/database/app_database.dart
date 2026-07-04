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
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sakal_local'));

  @override
  int get schemaVersion => 9;

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
        },
      );
}

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

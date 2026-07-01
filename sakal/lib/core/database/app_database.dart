import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tables/pending_sync_queue.dart';
import 'tables/exchange_rate_cache_table.dart';
import 'tables/accounts_cache_table.dart';
import 'tables/finance_voucher_cache_tables.dart';
import 'tables/common_masters_cache_table.dart';
import 'tables/products_cache_table.dart';

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
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sakal_local'));

  @override
  int get schemaVersion => 6;

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
        },
      );
}

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

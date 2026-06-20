import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tables/pending_sync_queue.dart';
import 'tables/exchange_rate_cache_table.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [PendingSyncQueue, ExchangeRateCache])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sakal_local'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(exchangeRateCache);
        },
      );
}

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

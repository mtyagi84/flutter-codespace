import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'tables/pending_sync_queue.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [PendingSyncQueue])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sakal_local'));

  @override
  int get schemaVersion => 1;
}

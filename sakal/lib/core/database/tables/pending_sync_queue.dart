import 'package:drift/drift.dart';

@DataClassName('SyncQueueEntry')
class PendingSyncQueue extends Table {
  IntColumn      get id           => integer().autoIncrement()();
  TextColumn     get documentType => text()();
  TextColumn     get documentId   => text()();
  TextColumn     get endpoint     => text()();
  TextColumn     get payload      => text()(); // Full document JSON
  IntColumn      get retryCount   => integer().withDefault(const Constant(0))();
  BoolColumn     get synced       => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt    => dateTime().withDefault(currentDateAndTime)();
}

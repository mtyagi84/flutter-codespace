import 'package:drift/drift.dart';

/// STANDARD-label tax rates (rim_tax_rates) — mirrors the same date-window
/// semantics the remote getTaxRatesByIds already implements
/// (pick, per tax_id, the row where effective_from <= asOf <= effective_to),
/// run client-side against cached rows instead of a server query.
@DataClassName('TaxRateCacheEntry')
class TaxRatesCache extends Table {
  TextColumn get taxId          => text()();
  TextColumn get rateLabel      => text().withDefault(const Constant('STANDARD'))();
  RealColumn get rate           => real().withDefault(const Constant(0))();
  TextColumn get effectiveFrom  => text()();
  TextColumn get effectiveTo    => text().nullable()();
  BoolColumn get isActive       => boolean().withDefault(const Constant(true))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {taxId, effectiveFrom};
}

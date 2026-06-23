import 'package:drift/drift.dart';

@DataClassName('FinanceVoucherHeadersCacheEntry')
class FinanceVoucherHeadersCache extends Table {
  // Business composite key — no server UUID needed; trans_no is unique per company/location
  TextColumn get clientId        => text()();
  TextColumn get companyId       => text()();
  TextColumn get locationId      => text().withDefault(const Constant(''))();
  TextColumn get transNo         => text()();
  TextColumn get transDate       => text()(); // 'YYYY-MM-DD'
  TextColumn get voucherTypeCode => text()();
  TextColumn get paymentModeCode => text().withDefault(const Constant(''))();
  BoolColumn get isOnAccount     => boolean().withDefault(const Constant(false))();
  TextColumn get referenceNo     => text().withDefault(const Constant(''))();
  TextColumn get referenceDate   => text().withDefault(const Constant(''))();
  TextColumn get chequeNo        => text().withDefault(const Constant(''))();
  TextColumn get chequeDate      => text().withDefault(const Constant(''))();
  TextColumn get remarks         => text().withDefault(const Constant(''))();
  BoolColumn get isPosted        => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted       => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt    => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transNo, transDate};
}

@DataClassName('FinanceVoucherLinesCacheEntry')
class FinanceVoucherLinesCache extends Table {
  TextColumn get clientId       => text()();
  TextColumn get companyId      => text()();
  TextColumn get locationId     => text().withDefault(const Constant(''))();
  TextColumn get transNo        => text()();
  TextColumn get transDate      => text()();
  IntColumn  get serialNo       => integer()();
  TextColumn get accountId      => text()();
  TextColumn get transNature    => text()();
  RealColumn get transAmount    => real().withDefault(const Constant(0.0))();
  TextColumn get transCurrency  => text().withDefault(const Constant(''))();
  RealColumn get baseAmount     => real().withDefault(const Constant(0.0))();
  RealColumn get baseRate       => real().withDefault(const Constant(1.0))();
  RealColumn get localAmount    => real().withDefault(const Constant(0.0))();
  RealColumn get localRate      => real().withDefault(const Constant(1.0))();
  RealColumn get partyAmount    => real().withDefault(const Constant(0.0))();
  TextColumn get partyCurrency  => text().withDefault(const Constant(''))();
  RealColumn get partyRate      => real().withDefault(const Constant(1.0))();
  TextColumn get invBillNo      => text().withDefault(const Constant(''))();
  TextColumn get invBillDate    => text().withDefault(const Constant(''))();
  TextColumn get lineRemarks    => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted      => boolean().withDefault(const Constant(false))();
  DateTimeColumn get cachedAt   => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {clientId, companyId, transNo, transDate, serialNo};
}

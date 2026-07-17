import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/database/app_database.dart';
import 'package:sakal/core/database/datasources/generic_lookup_local_ds.dart';
import 'package:sakal/core/database/datasources/product_uom_local_ds.dart';
import 'package:sakal/core/database/datasources/accounts_local_ds.dart';
import 'package:sakal/core/database/datasources/module_sync_status_local_ds.dart';

/// Real read/write round-trips against an in-memory Drift database for the
/// Master-Data Sync facility's local-ds classes (core/sync/master_data_modules.dart).
/// Uses AppDatabase.forTesting(NativeDatabase.memory()) — the standard Drift
/// testing idiom — never the real on-disk database.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('GenericLookupLocalDs', () {
    test('upsertLookups then getLookups returns scoped, ordered rows', () async {
      final ds = GenericLookupLocalDs(db);
      await ds.upsertLookups(
        cacheKey: 'TAX_GROUPS',
        rows: [
          {'id': 'g2', 'group_name': 'Zeta Group'},
          {'id': 'g1', 'group_name': 'Alpha Group'},
        ],
        idOf: (r) => r['id'] as String,
        labelOf: (r) => r['group_name'] as String,
        clientId: 'c1',
        companyId: 'co1',
      );

      final rows = await ds.getLookups(cacheKey: 'TAX_GROUPS', clientId: 'c1', companyId: 'co1');
      expect(rows.length, 2);
      // Ordered by label (sortOrder ties) — Alpha before Zeta.
      expect(rows[0]['group_name'], 'Alpha Group');
      expect(rows[1]['group_name'], 'Zeta Group');
    });

    test('getLookups scopes by clientId/companyId — a different tenant sees nothing', () async {
      final ds = GenericLookupLocalDs(db);
      await ds.upsertLookups(
        cacheKey: 'TAX_GROUPS', rows: [{'id': 'g1'}], idOf: (r) => r['id'] as String,
        clientId: 'c1', companyId: 'co1',
      );
      final rows = await ds.getLookups(cacheKey: 'TAX_GROUPS', clientId: 'c2', companyId: 'co2');
      expect(rows, isEmpty);
    });

    test('parentId scoping (department -> consumption area style)', () async {
      final ds = GenericLookupLocalDs(db);
      await ds.upsertLookups(
        cacheKey: 'DEPARTMENT_CONSUMPTION_AREAS',
        rows: [
          {'id': 'area1', 'description': 'Printing', 'department_id': 'dept1'},
          {'id': 'area2', 'description': 'Cleaning', 'department_id': 'dept2'},
        ],
        idOf: (r) => r['id'] as String,
        labelOf: (r) => r['description'] as String,
        parentIdOf: (r) => r['department_id'] as String,
        clientId: 'c1', companyId: 'co1',
      );

      final dept1Areas = await ds.getLookups(cacheKey: 'DEPARTMENT_CONSUMPTION_AREAS', parentId: 'dept1');
      expect(dept1Areas.length, 1);
      expect(dept1Areas.first['id'], 'area1');
    });

    test('getLookupById returns a single row by exact id, or null', () async {
      final ds = GenericLookupLocalDs(db);
      await ds.upsertLookups(
        cacheKey: 'QUICK_INVOICE_SETUP', rows: [{'location_id': 'loc1'}], idOf: (_) => 'user1',
        clientId: 'c1', companyId: 'co1',
      );

      final found = await ds.getLookupById(cacheKey: 'QUICK_INVOICE_SETUP', id: 'user1');
      expect(found?['location_id'], 'loc1');

      final missing = await ds.getLookupById(cacheKey: 'QUICK_INVOICE_SETUP', id: 'user2');
      expect(missing, isNull);
    });
  });

  group('ProductUomLocalDs', () {
    test('getForProduct returns cached UOM rows for that product only', () async {
      final ds = ProductUomLocalDs(db);
      await ds.upsert([
        {'product_id': 'p1', 'uom_id': 'u1', 'conversion_factor': 1, 'is_base_uom': true, 'uom': {'description': 'Piece'}},
        {'product_id': 'p1', 'uom_id': 'u2', 'conversion_factor': 12, 'is_base_uom': false, 'uom': {'description': 'Dozen'}},
        {'product_id': 'p2', 'uom_id': 'u1', 'conversion_factor': 1, 'is_base_uom': true, 'uom': {'description': 'Piece'}},
      ]);

      final p1Uoms = await ds.getForProduct('p1');
      expect(p1Uoms.length, 2);
      expect(p1Uoms.first['is_base_uom'], isTrue); // ordered base-uom first
    });

    test('getByBarcode resolves through to the product row, or null if not found/inactive', () async {
      await db.into(db.productsCache).insert(ProductsCacheCompanion.insert(
        id: 'p1', clientId: 'c1', companyId: 'co1', productCode: 'SI-001', productName: 'Test Item',
      ));

      final ds = ProductUomLocalDs(db);
      await ds.upsert([
        {'product_id': 'p1', 'uom_id': 'u1', 'conversion_factor': 1, 'is_base_uom': true, 'barcode': '1234567890', 'uom': {'description': 'Piece'}},
      ]);

      final match = await ds.getByBarcode('1234567890');
      expect(match?['product_code'], 'SI-001');
      expect(match?['matched_uom_id'], 'u1');

      final noMatch = await ds.getByBarcode('does-not-exist');
      expect(noMatch, isNull);
    });

    test('getByBarcode returns null when the matched product is deleted', () async {
      await db.into(db.productsCache).insert(ProductsCacheCompanion.insert(
        id: 'p1', clientId: 'c1', companyId: 'co1', productCode: 'SI-001', productName: 'Test Item',
        isDeleted: const Value(true),
      ));
      final ds = ProductUomLocalDs(db);
      await ds.upsert([
        {'product_id': 'p1', 'uom_id': 'u1', 'conversion_factor': 1, 'barcode': 'abc', 'uom': {'description': 'Piece'}},
      ]);
      expect(await ds.getByBarcode('abc'), isNull);
    });
  });

  group('AccountsLocalDs', () {
    test('upsertAccounts then getAccounts returns active accounts for the tenant', () async {
      final ds = AccountsLocalDs(db);
      await ds.upsertAccounts([
        {'id': 'a1', 'account_code': '3000001', 'account_name': 'Cash Customer', 'account_nature': 'Customer'},
      ], clientId: 'c1', companyId: 'co1');

      final rows = await ds.getAccounts(clientId: 'c1', companyId: 'co1');
      expect(rows.length, 1);
      expect(rows.first['account_name'], 'Cash Customer');
    });

    test('getById returns the 7 new nullable customer-detail columns', () async {
      final ds = AccountsLocalDs(db);
      await ds.upsertAccounts([
        {
          'id': 'a1', 'account_code': '3000001', 'account_name': 'Cash Customer', 'account_nature': 'Customer',
          'credit_limit': 5000, 'credit_days': 30, 'is_credit_blocked': false,
          'phone': '123456', 'email': 'a@b.com', 'address_line1': 'Line 1', 'address_line2': 'Line 2',
        },
      ], clientId: 'c1', companyId: 'co1');

      final row = await ds.getById('a1');
      expect(row?['credit_limit'], 5000.0);
      expect(row?['credit_days'], 30);
      expect(row?['is_credit_blocked'], false);
      expect(row?['phone'], '123456');
      expect(row?['email'], 'a@b.com');
      expect(row?['address_line1'], 'Line 1');
      expect(row?['address_line2'], 'Line 2');
    });

    test('getById returns null for an unknown account', () async {
      final ds = AccountsLocalDs(db);
      expect(await ds.getById('does-not-exist'), isNull);
    });
  });

  group('ModuleSyncStatusLocalDs', () {
    test('recordSync then setEnabled does not reset lastSyncedAt/rowCount', () async {
      final ds = ModuleSyncStatusLocalDs(db);
      await ds.recordSync('PRODUCTS_PRICING', 42);
      await ds.setEnabled('PRODUCTS_PRICING', false);

      final row = await ds.get('PRODUCTS_PRICING');
      expect(row?.enabled, isFalse);
      expect(row?.rowCount, 42); // must survive the setEnabled call
      expect(row?.lastSyncedAt, isNotNull);
    });

    test('setEnabled then recordSync does not reset the enabled flag', () async {
      final ds = ModuleSyncStatusLocalDs(db);
      await ds.setEnabled('PRODUCTS_PRICING', false);
      await ds.recordSync('PRODUCTS_PRICING', 10);

      final row = await ds.get('PRODUCTS_PRICING');
      expect(row?.enabled, isFalse); // must survive the recordSync call
      expect(row?.rowCount, 10);
    });

    test('a never-touched module has no row (defaults to enabled in calling code)', () async {
      final ds = ModuleSyncStatusLocalDs(db);
      expect(await ds.get('NEVER_TOUCHED'), isNull);
    });
  });
}

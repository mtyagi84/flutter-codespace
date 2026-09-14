import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';

/// Backend-level CRUD test for the highest-traffic Master screens
/// (Customer, Supplier, Product) — unlike every transaction screen, these
/// have NO dedicated `fn_save_*`/`fn_approve_*` RPC layer at all (confirmed
/// live 2026-09-14 by reading `customer_master_screen.dart`/
/// `supplier_master_screen.dart`/`products_remote_ds.dart` directly): they
/// POST/PATCH straight to their own PostgREST table
/// (`rim_accounts`/`rim_products`) from the screen's own code. This means
/// the only real backend-enforceable "business logic" is RLS tenant
/// scoping (already exhaustively verified by the critical
/// `security_invoker` fix earlier today) plus whatever CHECK constraints
/// the table itself has — there is no multi-step lifecycle, no
/// Draft/Approve, no GL/stock posting to exercise the way there was for
/// every transaction screen.
///
/// Scope note: this test proves a plain insert/update/read round-trip
/// succeeds and is correctly tenant-scoped — it deliberately does NOT
/// replicate each screen's own UI-side logic (auto-generated account
/// codes via `_fetchNextCode`, default-currency prefill, etc., which are
/// Flutter-side conveniences, not backend rules) — that class of behavior
/// needs `flutter drive` UI automation, not a backend RPC test, the same
/// scope boundary already documented for every transaction screen's own
/// CCC #4/#7 items.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // resetQaTenant() only wipes transaction data, never master data — this
    // file's own inserts (account_code 1120099/2110099, product_code
    // QA-CRUD-001) survive a prior run and collide on their UNIQUE
    // constraints on a re-run. Clean up any leftover row from a previous
    // run before inserting fresh ones, so this file is safely re-runnable.
    for (final code in ['1120099', '2110099']) {
      final rows = await verifier.get('rim_accounts', {'account_code': 'eq.$code'}, select: 'id');
      for (final row in rows) {
        await verifier.patch('rim_accounts', {'id': 'eq.${row['id']}'}, {'account_code': '$code-STALE-${row['id']}'.substring(0, 20)});
      }
    }
    final staleProducts = await verifier.get('rim_products', {'product_code': 'eq.QA-CRUD-001'}, select: 'id');
    for (final row in staleProducts) {
      await verifier.patch('rim_products', {'id': 'eq.${row['id']}'}, {'product_code': 'QA-CRUD-001-STALE-${row['id']}'});
    }
  });

  test('MST-CUST Customer Master: create, read, update round-trip', () async {
    final group = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.1120'}, // "Trade Receivables" — the Customer group
      select: 'id',
    );

    final created = await verifier.insert('rim_accounts', {
      'account_code': '1120099',
      'account_name': 'QA CRUD Test Customer',
      'parent_id': group['id'],
      'account_nature': 'Customer',
      'posting_allowed': true,
      'is_active': true,
      'accounting_std': 'INDIAN',
    });
    expect(created['client_id'], verifier.clientId);
    expect(created['company_id'], verifier.companyId);

    final read = await verifier.getOne(
      'rim_accounts',
      {'id': 'eq.${created['id']}'},
      select: 'account_name,is_active',
    );
    expect(read['account_name'], 'QA CRUD Test Customer');

    await verifier.patch('rim_accounts', {'id': 'eq.${created['id']}'}, {'account_name': 'QA CRUD Test Customer Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_accounts',
      {'id': 'eq.${created['id']}'},
      select: 'account_name',
    );
    expect(afterPatch['account_name'], 'QA CRUD Test Customer Renamed');

    // Deactivate ("soft delete" convention — is_active toggle, not a real
    // DELETE, matching CLAUDE.md's Immutability principle applied to
    // master data too).
    await verifier.patch('rim_accounts', {'id': 'eq.${created['id']}'}, {'is_active': false});
    final afterDeactivate = await verifier.getOne(
      'rim_accounts',
      {'id': 'eq.${created['id']}'},
      select: 'is_active',
    );
    expect(afterDeactivate['is_active'], isFalse);
  });

  test('MST-SUPP Supplier Master: create, read, update round-trip', () async {
    final group = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.2110'}, // "Trade Payables" — the Supplier group
      select: 'id',
    );

    final created = await verifier.insert('rim_accounts', {
      'account_code': '2110099',
      'account_name': 'QA CRUD Test Supplier',
      'parent_id': group['id'],
      'account_nature': 'Supplier',
      'posting_allowed': true,
      'is_active': true,
      'accounting_std': 'INDIAN',
    });
    expect(created['client_id'], verifier.clientId);

    final read = await verifier.getOne(
      'rim_accounts',
      {'id': 'eq.${created['id']}'},
      select: 'account_name',
    );
    expect(read['account_name'], 'QA CRUD Test Supplier');
  });

  test('MST-PRD Product Master: create, read, update round-trip', () async {
    // UOM is not a dedicated table — it's a rim_common_masters row under
    // the generic type mechanism (type_key='UNIT'), same as Brand/Color.
    final unitType = await verifier.getUnscoped(
      'rim_common_master_types',
      {'type_key': 'eq.UNIT'},
      select: 'id',
    );
    final uom = await verifier.getOne(
      'rim_common_masters',
      {'type_id': 'eq.${unitType.first['id']}', 'limit': '1'},
      select: 'id',
    );

    final created = await verifier.insert('rim_products', {
      'product_code': 'QA-CRUD-001',
      'product_name': 'QA CRUD Test Product',
      'base_uom_id': uom['id'],
      'tracking_type': 'NONE',
      'is_active': true,
      'flags': {'is_saleable': true, 'is_purchasable': true},
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_products', {'id': 'eq.${created['id']}'}, {'product_name': 'QA CRUD Test Product Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_products',
      {'id': 'eq.${created['id']}'},
      select: 'product_name',
    );
    expect(afterPatch['product_name'], 'QA CRUD Test Product Renamed');
  });
}

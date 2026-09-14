import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';

/// Backend-level CRUD test for the remaining Inventory Masters group —
/// Product Category Level Setup, Item Categories, Product Flag Types.
/// Product Master (MST-PRD) is already covered by masters_crud_backend_test.dart.
/// Consumption Area Setup (IN-DCA) is NOT re-tested here — it's already
/// exercised repeatedly, all session, via CommonRefs.loadOrCreateDepartmentArea()
/// as fixture setup for Material Requisition/Issue tests, the exact same
/// rim_department_consumption_areas table this screen edits.
void main() {
  late BackendVerifier verifier;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // Master-data cleanup — resetQaTenant() only wipes transaction data.
    final staleFlags = await verifier.get('rim_product_flag_types', {'flag_key': 'eq.QA_CRUD_FLAG'}, select: 'id');
    for (final row in staleFlags) {
      await verifier.patch('rim_product_flag_types', {'id': 'eq.${row['id']}'}, {'is_active': false, 'flag_key': 'QA_CRUD_FLAG_STALE_${row['id']}'.substring(0, 30)});
    }
    final staleCats = await verifier.get('rim_item_categories', {'category_name': 'eq.QA CRUD Test Category'}, select: 'id');
    for (final row in staleCats) {
      await verifier.patch('rim_item_categories', {'id': 'eq.${row['id']}'}, {'is_deleted': true, 'category_name': 'QA CRUD Test Category (stale ${row['id']})'});
    }
  });

  test('AD-PCS Product Category Level Setup: read seeded levels, toggle mandatory', () async {
    // Levels are seeded 1-4 at company creation (level_no CHECK 1..4) —
    // this screen edits label/mandatory/active on existing rows, it doesn't
    // create new ones (level_no is capped at 4).
    final levels = await verifier.get('rim_category_levels', {}, select: 'id,level_no,level_label,is_mandatory');
    expect(levels, isNotEmpty, reason: 'category levels should be seeded for every company');

    final level1 = levels.firstWhere((l) => l['level_no'] == 1);
    final originalMandatory = level1['is_mandatory'] as bool;

    await verifier.patch('rim_category_levels', {'id': 'eq.${level1['id']}'}, {'is_mandatory': !originalMandatory});
    final afterPatch = await verifier.getOne('rim_category_levels', {'id': 'eq.${level1['id']}'}, select: 'is_mandatory');
    expect(afterPatch['is_mandatory'], !originalMandatory);

    // Restore — this is shared seed config other tests/screens may depend on.
    await verifier.patch('rim_category_levels', {'id': 'eq.${level1['id']}'}, {'is_mandatory': originalMandatory});
  });

  test('MST-ITC Item Categories: create a Level-1 category with flags, read, update round-trip', () async {
    final created = await verifier.insert('rim_item_categories', {
      'level_no': 1,
      'category_name': 'QA CRUD Test Category',
      'flags': {'is_saleable': true, 'is_purchasable': true},
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);
    expect(created['flags']['is_saleable'], isTrue);

    await verifier.patch('rim_item_categories', {'id': 'eq.${created['id']}'}, {'category_name': 'QA CRUD Test Category Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_item_categories',
      {'id': 'eq.${created['id']}'},
      select: 'category_name',
    );
    expect(afterPatch['category_name'], 'QA CRUD Test Category Renamed');
  });

  test('AD-PGS Product Flag Types: create a custom flag, read, update round-trip', () async {
    final created = await verifier.insert('rim_product_flag_types', {
      'flag_key': 'QA_CRUD_FLAG',
      'flag_label': 'QA CRUD Test Flag',
      'default_value': true,
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_product_flag_types', {'id': 'eq.${created['id']}'}, {'flag_label': 'QA CRUD Test Flag Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_product_flag_types',
      {'id': 'eq.${created['id']}'},
      select: 'flag_label',
    );
    expect(afterPatch['flag_label'], 'QA CRUD Test Flag Renamed');
  });
}

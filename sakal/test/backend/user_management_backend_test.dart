import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for the User Management group — User Management,
/// User Permissions, User Location Setup, Master Menu.
///
/// Unlike every other Master screen tested so far, User Management has a
/// real dedicated RPC (`fn_create_user`, migration 011) — confirmed by
/// reading `users_screen.dart` directly — since a new user's password
/// needs server-side `crypt()` hashing, not a plain client-side insert.
void main() {
  late BackendVerifier verifier;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // uq_users_client_username is a plain (not partial) UNIQUE index —
    // "includes soft-deleted, prevents username reuse" per its own comment
    // in migration 002 — so is_deleted=true alone does NOT free the
    // username for a fresh insert. Rename the stale row's username too.
    final staleUsers = await verifier.get('rim_users', {'username': 'eq.qa_crud_test'}, select: 'id');
    for (final row in staleUsers) {
      await verifier.patch('rim_users', {'id': 'eq.${row['id']}'},
          {'is_deleted': true, 'is_active': false, 'username': 'qa_crud_test_stale_${row['id']}'});
    }
    final staleLocations = await verifier.get('ric_locations', {'location_name': 'eq.QA CRUD Test Location'}, select: 'id');
    for (final row in staleLocations) {
      await verifier.patch('ric_locations', {'id': 'eq.${row['id']}'}, {'is_deleted': true, 'is_active': false});
    }
  });

  test('AD-USR User Management: fn_create_user, read, update, deactivate round-trip', () async {
    final userId = await verifier.rpc('fn_create_user', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_username': 'qa_crud_test',
      'p_full_name': 'QA CRUD Test User',
      'p_password': 'QaCrudTest#2026',
      'p_must_change_password': true,
      'p_created_by': verifier.userId,
    });
    expect(userId, isNotNull);

    final read = await verifier.getOne(
      'rim_users',
      {'id': 'eq.$userId'},
      select: 'username,full_name,is_active,must_change_password',
    );
    expect(read['username'], 'qa_crud_test');
    expect(read['must_change_password'], isTrue);

    await verifier.patch('rim_users', {'id': 'eq.$userId'}, {'full_name': 'QA CRUD Test User Renamed'});
    final afterPatch = await verifier.getOne('rim_users', {'id': 'eq.$userId'}, select: 'full_name');
    expect(afterPatch['full_name'], 'QA CRUD Test User Renamed');

    await verifier.patch('rim_users', {'id': 'eq.$userId'}, {'is_active': false});
    final afterDeactivate = await verifier.getOne('rim_users', {'id': 'eq.$userId'}, select: 'is_active');
    expect(afterDeactivate['is_active'], isFalse);
  });

  test('AD-PRM User Permissions: grant a feature right, read, update round-trip', () async {
    final adminUser = await verifier.getOne(
      'rim_users',
      {'username': 'eq.${TestTenantConfig.username}'},
      select: 'id',
    );
    // fn_login-created admin already has ric_user_menus rows seeded at
    // client registration — read-then-update, not insert, to respect the
    // table's own UNIQUE(user_id, feature_code).
    final existing = await verifier.getOne(
      'ric_user_menus',
      {'user_id': 'eq.${adminUser['id']}', 'feature_code': 'eq.PR-PO'},
      select: 'id,view_allowed',
    );
    final original = existing['view_allowed'] as bool;

    await verifier.patch('ric_user_menus', {'id': 'eq.${existing['id']}'}, {'view_allowed': !original});
    final afterPatch = await verifier.getOne('ric_user_menus', {'id': 'eq.${existing['id']}'}, select: 'view_allowed');
    expect(afterPatch['view_allowed'], !original);

    // Restore — this is the live QA admin's own real permission, needed by
    // every other test file in this suite.
    await verifier.patch('ric_user_menus', {'id': 'eq.${existing['id']}'}, {'view_allowed': original});
  });

  test('AD-ULS User Location Setup: grant a second location, read, revoke round-trip', () async {
    final adminUser = await verifier.getOne(
      'rim_users',
      {'username': 'eq.${TestTenantConfig.username}'},
      select: 'id',
    );

    // Create a throwaway second location rather than reusing
    // CommonRefs.loadOrCreateSecondLocation() — avoids interacting with
    // any other test file's own use of that shared fixture location.
    final location = await verifier.insert('ric_locations', {
      'location_name': 'QA CRUD Test Location',
      'location_short': 'QACRUD',
      'is_active': true,
    });

    final created = await verifier.insert('ric_user_location_access', {
      'user_id': adminUser['id'],
      'location_id': location['id'],
      'is_default': false,
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    final read = await verifier.getOne(
      'ric_user_location_access',
      {'id': 'eq.${created['id']}'},
      select: 'is_active',
    );
    expect(read['is_active'], isTrue);

    await verifier.patch('ric_user_location_access', {'id': 'eq.${created['id']}'}, {'is_active': false});
    final afterRevoke = await verifier.getOne(
      'ric_user_location_access',
      {'id': 'eq.${created['id']}'},
      select: 'is_active',
    );
    expect(afterRevoke['is_active'], isFalse);
  });

  test('AD-MST Master Menu: read seeded feature list, toggle a feature active flag', () async {
    final features = await verifier.get('ric_master_menus', {}, select: 'id,feature_code,is_active');
    expect(features, isNotEmpty, reason: 'master menu should be seeded for every company via fn_seed_client_modules');

    final target = features.firstWhere((f) => f['feature_code'] == 'PR-PO');
    final original = target['is_active'] as bool;

    await verifier.patch('ric_master_menus', {'id': 'eq.${target['id']}'}, {'is_active': !original});
    final afterPatch = await verifier.getOne('ric_master_menus', {'id': 'eq.${target['id']}'}, select: 'is_active');
    expect(afterPatch['is_active'], !original);

    // Restore — disabling PR-PO app-wide would break every Purchase Order
    // backend test that runs after this one in the same suite.
    await verifier.patch('ric_master_menus', {'id': 'eq.${target['id']}'}, {'is_active': original});
  });
}

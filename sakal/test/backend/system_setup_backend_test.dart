import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';

/// Backend-level test for the System Setup group. Not every one of the 13
/// screens gets a dedicated test case here — three are singleton
/// per-company config editors already exercised implicitly by every other
/// test file in this suite (Company Setup / Accounting Setup — every test
/// logs in against an already-configured real QA company; Quick Invoice
/// Setup — exercised directly by CommonRefs.ensureQuickInvoiceSetup() as
/// Cash Receipt/Sales Invoice fixture setup). Country Divisions (rim_divisions)
/// is a GLOBAL lookup table per CLAUDE.md's own documented design
/// (is_system=true OR client+company) — not company-specific CRUD to test
/// here.
void main() {
  late BackendVerifier verifier;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // These tables' own UNIQUE constraints are plain (not partial on
    // is_deleted=false) — soft-deleting a stale row alone does NOT free
    // its unique key for a fresh insert on re-run, so rename it too.
    // like.* (not eq.) — a completed prior run leaves the RENAMED value
    // behind ("QA CRUD Test Renamed"), not the original one, so an exact
    // match would miss it.
    for (final entry in {
      'rim_cities': 'city_name',
      'ric_print_templates': 'template_name',
      'rim_payment_terms': 'term_code',
    }.entries) {
      final rows = await verifier.get(entry.key, {entry.value: 'like.QA CRUD Test*'}, select: 'id');
      for (final row in rows) {
        await verifier.patch(entry.key, {'id': 'eq.${row['id']}'},
            {'is_deleted': true, entry.value: 'QA CRUD Test STALE ${row['id']}'});
      }
    }
  });

  test('AD-CUR Currency Setup: activate a seeded currency, deactivate round-trip', () async {
    // Currencies are auto-seeded per company (migration 007's own trigger)
    // — this screen activates/edits existing rows, it doesn't create new
    // ISO currency codes.
    final currency = await verifier.getOne('rim_currencies', {'currency_id': 'eq.EUR'}, select: 'id,is_active');
    final original = currency['is_active'] as bool;

    await verifier.patch('rim_currencies', {'id': 'eq.${currency['id']}'}, {'is_active': !original});
    final afterPatch = await verifier.getOne('rim_currencies', {'id': 'eq.${currency['id']}'}, select: 'is_active');
    expect(afterPatch['is_active'], !original);

    await verifier.patch('rim_currencies', {'id': 'eq.${currency['id']}'}, {'is_active': original});
  });

  test('AD-CNT Country Setup: activate a seeded country, deactivate round-trip', () async {
    // Countries are auto-seeded per company too (migration 008) — ~200
    // rows, default is_active=false, this screen activates the ones a
    // tenant actually trades with.
    final country = await verifier.getOne('rim_countries', {'country_code': 'eq.FR'}, select: 'id,is_active');
    final original = country['is_active'] as bool;

    await verifier.patch('rim_countries', {'id': 'eq.${country['id']}'}, {'is_active': !original});
    final afterPatch = await verifier.getOne('rim_countries', {'id': 'eq.${country['id']}'}, select: 'is_active');
    expect(afterPatch['is_active'], !original);

    await verifier.patch('rim_countries', {'id': 'eq.${country['id']}'}, {'is_active': original});
  });

  test('AD-CIT Cities: create, read, update round-trip', () async {
    final created = await verifier.insert('rim_cities', {
      'country_code': 'FR',
      'city_name': 'QA CRUD Test',
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_cities', {'id': 'eq.${created['id']}'}, {'city_name': 'QA CRUD Test Renamed'});
    final afterPatch = await verifier.getOne('rim_cities', {'id': 'eq.${created['id']}'}, select: 'city_name');
    expect(afterPatch['city_name'], 'QA CRUD Test Renamed');
  });

  test('AD-PDC Period Close: lock a past period, read, reopen round-trip', () async {
    final created = await verifier.insert('ric_period_locks', {
      'period_start_date': '2020-01-01',
      'period_end_date': '2020-01-31',
      'locked_by': verifier.userId,
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    // Reopen — logged, permission-gated action per CLAUDE.md's own doc
    // comment for this table; a plain PATCH here is the same shape the
    // screen itself uses (is_active=false + reopened_by/reopened_at/reason).
    await verifier.patch('ric_period_locks', {'id': 'eq.${created['id']}'}, {
      'is_active': false,
      'reopened_by': verifier.userId,
      'reopened_at': DateTime.now().toIso8601String(),
      'reopen_reason': 'QA CRUD test cleanup',
    });
    final afterReopen = await verifier.getOne('ric_period_locks', {'id': 'eq.${created['id']}'}, select: 'is_active');
    expect(afterReopen['is_active'], isFalse);
  });

  test('AD-BDC Backdated Entry Control: set a limit for a transaction type, read, update round-trip', () async {
    final staleControl = await verifier.get('ric_backdated_entry_control', {'transaction_type': 'eq.QA_CRUD_TEST'}, select: 'id');
    for (final row in staleControl) {
      await verifier.patch('ric_backdated_entry_control', {'id': 'eq.${row['id']}'}, {'transaction_type': 'QA_CRUD_TEST_STALE_${row['id']}'});
    }

    final created = await verifier.insert('ric_backdated_entry_control', {
      'transaction_type': 'QA_CRUD_TEST',
      'max_backdate_days': 7,
      'allow_future_date': false,
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('ric_backdated_entry_control', {'id': 'eq.${created['id']}'}, {'max_backdate_days': 14});
    final afterPatch = await verifier.getOne(
      'ric_backdated_entry_control',
      {'id': 'eq.${created['id']}'},
      select: 'max_backdate_days',
    );
    expect(afterPatch['max_backdate_days'], 14);
  });

  test('AD-PDT Print Templates: create, read, update round-trip', () async {
    final created = await verifier.insert('ric_print_templates', {
      'document_type': 'QA_CRUD_DOC_TYPE',
      'template_name': 'QA CRUD Test',
      'paper_profile': 'A4',
      'is_default': false,
      'layout': {'elements': []},
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('ric_print_templates', {'id': 'eq.${created['id']}'}, {'paper_profile': 'RECEIPT_80MM'});
    final afterPatch = await verifier.getOne(
      'ric_print_templates',
      {'id': 'eq.${created['id']}'},
      select: 'paper_profile',
    );
    expect(afterPatch['paper_profile'], 'RECEIPT_80MM');
  });

  test('AD-PAYTERM Payment Terms: create, read, update round-trip', () async {
    final created = await verifier.insert('rim_payment_terms', {
      'term_code': 'QA CRUD Test',
      'term_name': 'QA CRUD Test Terms',
      'description': '50% Advance, 50% on Delivery',
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_payment_terms', {'id': 'eq.${created['id']}'}, {'term_name': 'QA CRUD Test Terms Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_payment_terms',
      {'id': 'eq.${created['id']}'},
      select: 'term_name',
    );
    expect(afterPatch['term_name'], 'QA CRUD Test Terms Renamed');
  });

  test('MST-CMN Common Masters: create a Brand entry, read, update round-trip', () async {
    final brandType = (await verifier.getUnscoped('rim_common_master_types', {'type_key': 'eq.BRAND'}, select: 'id')).first;

    final staleBrand = await verifier.get('rim_common_masters', {'description': 'like.QA CRUD Test Brand*'}, select: 'id');
    for (final row in staleBrand) {
      await verifier.patch('rim_common_masters', {'id': 'eq.${row['id']}'},
          {'is_deleted': true, 'description': 'QA CRUD Test Brand STALE ${row['id']}'});
    }

    final created = await verifier.insert('rim_common_masters', {
      'type_id': brandType['id'],
      'description': 'QA CRUD Test Brand',
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_common_masters', {'id': 'eq.${created['id']}'}, {'description': 'QA CRUD Test Brand Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_common_masters',
      {'id': 'eq.${created['id']}'},
      select: 'description',
    );
    expect(afterPatch['description'], 'QA CRUD Test Brand Renamed');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level CRUD test for the Finance Masters group — Tax Master, Tax
/// Groups, Additional Charges, Opening Balance, Exchange Rates. Same scope
/// boundary as masters_crud_backend_test.dart: these screens have no
/// dedicated fn_save_*/fn_approve_* RPC layer, so the only real
/// backend-enforceable behavior is a plain insert/update round-trip,
/// correctly tenant-scoped, plus whatever CHECK constraints the table
/// itself has.
///
/// Chart of Accounts (MST-COA) is already covered by
/// masters_crud_backend_test.dart's Customer/Supplier tests (same
/// rim_accounts table). Account Link Setup (MST-ALS) and Item Account
/// Links (MST-IAL) are NOT re-tested here — they're already exhaustively
/// exercised indirectly, all session, via CommonRefs'
/// ensure*AccountLink()/ensureQuickInvoiceSetup() helpers used as fixture
/// setup in every transaction test (rim_account_link_setup +
/// rim_account_link_defaults), which is a real, repeated insert/update
/// round-trip against those exact tables.
void main() {
  late BackendVerifier verifier;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    // Master-data cleanup — resetQaTenant() only wipes transaction data.
    // Rename/retire any leftover row from a previous run of this file so
    // re-running it (or the whole suite) doesn't collide on a UNIQUE code.
    for (final entry in {
      'rim_taxes': 'tax_code',
      'rim_tax_groups': 'group_code',
      'rim_additional_charges': 'charge_code',
    }.entries) {
      final rows = await verifier.get(entry.key, {'${entry.value}': 'eq.QA-CRUD-01'}, select: 'id');
      for (final row in rows) {
        await verifier.patch(entry.key, {'id': 'eq.${row['id']}'},
            {entry.value: 'QA-CRUD-01-STALE-${row['id']}'.substring(0, 20)});
      }
    }
    // uq_rim_exchange_rates (company, location, date, from, to) — delete any
    // leftover row from a prior run of this file rather than rename (no
    // soft-delete-friendly rename target for a currency-code column here).
    final staleRates = await verifier.get(
      'rim_exchange_rates',
      {'to_currency': 'eq.ZZZ-QA-TEST'},
      select: 'id',
    );
    for (final row in staleRates) {
      await verifier.patch('rim_exchange_rates', {'id': 'eq.${row['id']}'}, {'to_currency': 'ZZZ-STALE-${row['id']}'.substring(0, 20)});
    }
  });

  test('MST-TAX Tax Master: create tax + rate, read, update round-trip', () async {
    // rim_tax_types is a global lookup table — no client_id/company_id.
    final taxType = (await verifier.getUnscoped(
      'rim_tax_types',
      {'limit': '1'},
      select: 'tax_type_code',
    )).first;

    final created = await verifier.insert('rim_taxes', {
      'tax_code': 'QA-CRUD-01',
      'tax_name': 'QA CRUD Test Tax',
      'tax_type_code': taxType['tax_type_code'],
      'applicable_on': 'BOTH',
      'calculation_type': 'PERCENTAGE',
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    final rate = await verifier.insert('rim_tax_rates', {
      'tax_id': created['id'],
      'rate_label': 'STANDARD',
      'rate': 16,
      'effective_from': '2020-01-01',
      'is_active': true,
    });
    expect((rate['rate'] as num).toDouble(), 16);

    await verifier.patch('rim_taxes', {'id': 'eq.${created['id']}'}, {'tax_name': 'QA CRUD Test Tax Renamed'});
    final afterPatch = await verifier.getOne('rim_taxes', {'id': 'eq.${created['id']}'}, select: 'tax_name');
    expect(afterPatch['tax_name'], 'QA CRUD Test Tax Renamed');
  });

  test('MST-TXG Tax Groups: create group + member, read round-trip', () async {
    final anyTax = await verifier.getOne('rim_taxes', {'limit': '1'}, select: 'id');

    final group = await verifier.insert('rim_tax_groups', {
      'group_code': 'QA-CRUD-01',
      'group_name': 'QA CRUD Test Tax Group',
      'applicable_on': 'BOTH',
      'is_active': true,
    });
    expect(group['client_id'], verifier.clientId);

    final member = await verifier.insert('rim_tax_group_members', {
      'tax_group_id': group['id'],
      'tax_id': anyTax['id'],
      'sequence_no': 1,
    });
    expect(member['tax_group_id'], group['id']);

    final read = await verifier.getOne('rim_tax_groups', {'id': 'eq.${group['id']}'}, select: 'group_name');
    expect(read['group_name'], 'QA CRUD Test Tax Group');
  });

  test('MST-CHG Additional Charges: create, read, update round-trip', () async {
    final created = await verifier.insert('rim_additional_charges', {
      'charge_code': 'QA-CRUD-01',
      'charge_name': 'QA CRUD Test Charge',
      'applicable_on': 'BOTH',
      'nature': 'ADD',
      'amount_or_percent': 'AMOUNT',
      'default_amount': 5,
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_additional_charges', {'id': 'eq.${created['id']}'}, {'default_amount': 7.5});
    final afterPatch = await verifier.getOne(
      'rim_additional_charges',
      {'id': 'eq.${created['id']}'},
      select: 'default_amount',
    );
    expect((afterPatch['default_amount'] as num).toDouble(), 7.5);
  });

  test('MST-OB Opening Balance: create against an existing account + FY, read round-trip', () async {
    // The real live table is rid_opening_balance_lines, NOT rim_opening_balances
    // — migration 013's rim_opening_balances is dead/superseded schema, never
    // actually consumed by opening_balance_remote_ds.dart (confirmed by reading
    // it directly: it POSTs to /rid_opening_balance_lines, added in migration
    // 133). Worth a real follow-up: the orphan rim_opening_balances table/
    // migration should probably be removed to avoid future confusion.
    final account = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.5210'}, // Administrative Expenses — postable leaf, confirmed elsewhere this session
      select: 'id,account_currency_id',
    );
    final fy = await verifier.getOne('rim_financial_years', {'limit': '1'}, select: 'id');

    final created = await verifier.insert('rid_opening_balance_lines', {
      'account_id': account['id'],
      'fy_id': fy['id'],
      'base_amount': 1000,
      'local_amount': 1000,
      'party_amount': 1000,
      'party_currency': 'USD',
      'ob_type': 'Dr',
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rid_opening_balance_lines', {'id': 'eq.${created['id']}'}, {'base_amount': 1500});
    final afterPatch = await verifier.getOne(
      'rid_opening_balance_lines',
      {'id': 'eq.${created['id']}'},
      select: 'base_amount',
    );
    expect((afterPatch['base_amount'] as num).toDouble(), 1500);

    // Soft-delete cleanup — no UNIQUE constraint blocks a re-run, but leaving
    // test rows live would pollute a real Opening Balance report/screen.
    await verifier.patch('rid_opening_balance_lines', {'id': 'eq.${created['id']}'}, {'is_deleted': true});
  });

  test('FN-EX Exchange Rates: create a daily rate, read round-trip', () async {
    // Migration 179 renamed the old GENERATED mid_rate column to a plain,
    // independently user-editable exchange_rate — buying_rate/selling_rate
    // still exist but no longer derive it.
    final created = await verifier.insert('rim_exchange_rates', {
      'location_id': TestTenantConfig.locationId,
      'rate_date': '2020-01-01', // deliberately a date no real transaction ever used
      'from_currency': 'USD',
      'to_currency': 'ZZZ-QA-TEST',
      'buying_rate': 1.0,
      'selling_rate': 1.01,
      'exchange_rate': 1.005,
      'source': 'MANUAL',
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);
    expect((created['exchange_rate'] as num).toDouble(), closeTo(1.005, 0.0001));

    final read = await verifier.getOne(
      'rim_exchange_rates',
      {'id': 'eq.${created['id']}'},
      select: 'to_currency,buying_rate,selling_rate',
    );
    expect(read['to_currency'], 'ZZZ-QA-TEST');
  });
}

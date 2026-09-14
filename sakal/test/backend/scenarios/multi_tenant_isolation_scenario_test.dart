import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Production-Readiness Roadmap, Phase B: proves multi-tenant isolation
/// end-to-end using a REAL second tenant registered through the exact same
/// public RPC the Registration screen itself calls (fn_register_client +
/// fn_complete_accounting_setup), not a fixture row inserted directly.
///
/// This is a stronger and more direct proof than Phase A's per-table RLS
/// checks: it registers a genuinely independent tenant, posts a real GL
/// transaction in it, then confirms from BOTH sides that neither tenant's
/// JWT can see the other's client/company/location/account/transaction
/// rows. Complements (does not replace) tenancy_rls_probe_test.dart, which
/// checks the 3 root tables against the QA tenant's own long-lived data.
///
/// NOTE: fn_register_client has no corresponding delete function in this
/// schema (confirmed via a full grep) — the tenant created here is
/// PERMANENT. This was a deliberate, confirmed tradeoff (same DB as QA
/// testing, using already-active access) rather than an oversight.
void main() {
  late BackendVerifier qaVerifier;
  late BackendVerifier newTenantVerifier;
  late String newClientId;
  late String newClientNo;
  late String newCompanyId;
  late String newLocationId;

  const newTenantUsername = 'qa_isolation_admin';
  const newTenantPassword = 'QaIsolation#2026';

  setUpAll(() async {
    qaVerifier = BackendVerifier();
    await qaVerifier.login();

    // Unique email every run (fn_register_client rejects EMAIL_EXISTS) —
    // timestamp-based, since this tenant is permanent and can never be
    // re-registered under the same email on a re-run.
    final uniqueSuffix = DateTime.now().millisecondsSinceEpoch;
    final email = 'qa.isolation.$uniqueSuffix@sakal-test.invalid';

    newTenantVerifier = BackendVerifier();
    final reg = await newTenantVerifier.registerNewTenant(
      businessName: 'QA Isolation Test Co $uniqueSuffix',
      country: 'Zambia',
      contactName: 'QA Isolation Tester',
      email: email,
      phone: '0000000000',
      companyName: 'QA Isolation Test Co',
      companyShort: 'QAISO',
      baseCurrency: 'USD',
      localCurrency: 'ZMW',
      locationName: 'Main Store',
      locationShort: 'MAIN',
      locationType: 'STORE',
      adminName: 'QA Isolation Admin',
      username: newTenantUsername,
      password: newTenantPassword,
    );
    newClientId = reg['client_id'] as String;
    newClientNo = reg['client_no'] as String;
    newCompanyId = reg['company_id'] as String;
    newLocationId = reg['location_id'] as String;

    await newTenantVerifier.completeAccountingSetup(
      clientId: newClientId,
      companyId: newCompanyId,
      accountingStd: 'ZAMBIA',
      fyStartMonth: 1,
    );

    await newTenantVerifier.loginToTenant(newClientNo, newTenantUsername, newTenantPassword);
  });

  test('A real second tenant, registered through fn_register_client, is fully isolated from the QA tenant', () async {
    // ── Sanity: the new tenant really is different from the QA tenant ──
    expect(newClientId, isNot(equals(qaVerifier.clientId)));

    // ── Post a real transaction in the NEW tenant (proves its own seeded
    // COA/currency setup actually works, not just that registration
    // returned success) ─────────────────────────────────────────────────
    final leafAccounts = await newTenantVerifier.get(
      'rim_accounts',
      {'posting_allowed': 'eq.true', 'order': 'account_code.asc', 'limit': '2'},
      select: 'id,account_code',
    );
    expect(leafAccounts.length, 2, reason: 'fn_complete_accounting_setup must have seeded at least 2 postable leaf accounts');
    final accountA = leafAccounts[0]['id'] as String;
    final accountB = leafAccounts[1]['id'] as String;

    final today = todayStr();
    final jvTransNo = await newTenantVerifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': newTenantVerifier.clientId,
        'company_id': newTenantVerifier.companyId,
        'location_id': newLocationId,
        'trans_no': null,
        'trans_date': today,
        'voucher_type_code': 'JV',
        'remarks': 'QA multi-tenant isolation proof',
      },
      'p_lines': [
        {
          'serial_no': 1, 'account_id': accountA, 'trans_nature': 'DR',
          'trans_amount': 100, 'trans_currency': 'USD',
          'base_amount': 100, 'base_rate': 1,
          'local_amount': 100, 'local_rate': 1,
          'party_amount': 100, 'party_currency': 'USD', 'party_rate': 1,
        },
        {
          'serial_no': 2, 'account_id': accountB, 'trans_nature': 'CR',
          'trans_amount': 100, 'trans_currency': 'USD',
          'base_amount': 100, 'base_rate': 1,
          'local_amount': 100, 'local_rate': 1,
          'party_amount': 100, 'party_currency': 'USD', 'party_rate': 1,
        },
      ],
      'p_user_id': newTenantVerifier.userId,
    }) as String;

    await newTenantVerifier.rpc('fn_post_finance_voucher', {
      'p_client_id': newTenantVerifier.clientId,
      'p_company_id': newTenantVerifier.companyId,
      'p_location_id': newLocationId,
      'p_trans_no': jvTransNo,
      'p_trans_date': today,
      'p_posted_by': newTenantVerifier.userId,
    });

    final newTenantOwnLines = await newTenantVerifier.get(
      'rid_finance_lines', {'trans_no': 'eq.$jvTransNo', 'trans_date': 'eq.$today'}, select: 'id,base_amount',
    );
    expect(newTenantOwnLines.length, 2, reason: 'The new tenant must see its own just-posted voucher');

    // ── Root-table isolation (migration 188's own guarantee), re-proven
    // against a genuinely FRESH second tenant rather than the QA tenant's
    // long-lived data ───────────────────────────────────────────────────
    final visibleClients = await newTenantVerifier.getUnscoped('ric_clients', {'select': 'id'});
    expect(visibleClients.length, 1);
    expect(visibleClients.first['id'], newClientId);

    final visibleCompanies = await newTenantVerifier.getUnscoped('ric_companies', {'select': 'id,client_id'});
    expect(visibleCompanies.every((c) => c['client_id'] == newClientId), isTrue);

    // ── The NEW tenant must NOT see the QA tenant's transaction data ───
    final qaVoucherVisibleToNewTenant = await newTenantVerifier.get(
      'rid_finance_lines', {'account_id': 'eq.${TestTenantConfig.stockAccountId}'}, select: 'id',
    );
    expect(qaVoucherVisibleToNewTenant, isEmpty,
        reason: 'The new tenant must never see rows referencing the QA tenant\'s own account IDs');

    final qaAccountsVisibleToNewTenant = await newTenantVerifier.get(
      'rim_accounts', {'id': 'eq.${TestTenantConfig.stockAccountId}'}, select: 'id',
    );
    expect(qaAccountsVisibleToNewTenant, isEmpty,
        reason: 'The new tenant must never see the QA tenant\'s own rim_accounts row, even by direct id lookup');

    // ── The QA tenant must NOT see the NEW tenant's just-posted voucher,
    // company, or location — the reverse direction of the same proof ───
    final newTenantVoucherVisibleToQa = await qaVerifier.get(
      'rid_finance_lines', {'account_id': 'eq.$accountA'}, select: 'id',
    );
    expect(newTenantVoucherVisibleToQa, isEmpty,
        reason: 'The QA tenant must never see rows referencing the new tenant\'s own account IDs');

    final newTenantCompanyVisibleToQa = await qaVerifier.getUnscoped(
      'ric_companies', {'id': 'eq.$newCompanyId', 'select': 'id'},
    );
    expect(newTenantCompanyVisibleToQa, isEmpty,
        reason: 'The QA tenant must never see the new tenant\'s own ric_companies row, even by direct id lookup');

    final newTenantLocationVisibleToQa = await qaVerifier.getUnscoped(
      'ric_locations', {'id': 'eq.$newLocationId', 'select': 'id'},
    );
    expect(newTenantLocationVisibleToQa, isEmpty,
        reason: 'The QA tenant must never see the new tenant\'s own ric_locations row, even by direct id lookup');
  });
}

String todayStr() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

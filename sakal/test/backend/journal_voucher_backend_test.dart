import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for FN-JRN (Journal Voucher) — calls
/// fn_save_finance_voucher/fn_post_finance_voucher directly with
/// voucher_type_code='JV', a plain free-form Dr/Cr entry between two
/// General accounts. Reuses the generic voucher engine unchanged (per
/// CLAUDE.md's Journal Voucher section — zero new posting logic needed for
/// this module), so this test doubles as a smoke test of the shared engine
/// itself.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late String cashAccountId;
  late String expenseAccountId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);

    final cash = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.1110001001'}, // "Cash In Had USD"
      select: 'id',
    );
    cashAccountId = cash['id'] as String;

    final expense = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.5210'}, // "Administrative Expenses"
      select: 'id',
    );
    expenseAccountId = expense['id'] as String;
  });

  test('Journal Voucher: balanced Dr/Cr entry posts, immutability blocked', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final transNo = await verifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'trans_no': null,
        'trans_date': today,
        'voucher_type_code': 'JV',
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'account_id': expenseAccountId,
          'trans_nature': 'DR',
          'trans_amount': 75,
          'trans_currency': 'USD',
          'base_amount': 75,
          'base_rate': 1,
          'local_amount': 75,
          'local_rate': 1,
          'party_amount': 75,
          'party_currency': 'USD',
          'party_rate': 1,
        },
        {
          'serial_no': 2,
          'account_id': cashAccountId,
          'trans_nature': 'CR',
          'trans_amount': 75,
          'trans_currency': 'USD',
          'base_amount': 75,
          'base_rate': 1,
          'local_amount': 75,
          'local_rate': 1,
          'party_amount': 75,
          'party_currency': 'USD',
          'party_rate': 1,
        },
      ],
      'p_user_id': verifier.userId,
    });

    // rih_finance_headers uses is_posted (boolean), not the status TEXT
    // enum every document-based module (GRN/PO/...) uses — confirmed live
    // 2026-09-14 (a genuinely different schema shape for the generic
    // voucher engine, not a typo to fix).
    final draft = await verifier.getOne(
      'rih_finance_headers',
      {'trans_no': 'eq.$transNo'},
      select: 'trans_no,is_posted',
    );
    expect(draft['is_posted'], isFalse);

    await verifier.rpc('fn_post_finance_voucher', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_trans_no': transNo,
      'p_trans_date': today,
      'p_posted_by': verifier.userId,
    });

    final posted = await verifier.getOne(
      'rih_finance_headers',
      {'trans_no': 'eq.$transNo'},
      select: 'trans_no,is_posted',
    );
    expect(posted['is_posted'], isTrue);

    final lines = await verifier.get(
      'rid_finance_lines',
      {'trans_no': 'eq.$transNo', 'trans_date': 'eq.$today'},
      select: 'account_id,trans_nature,base_amount',
    );
    expect(lines.length, 2);
    final drLine = lines.firstWhere((l) => l['trans_nature'] == 'DR');
    final crLine = lines.firstWhere((l) => l['trans_nature'] == 'CR');
    expect(drLine['account_id'], expenseAccountId);
    expect(crLine['account_id'], cashAccountId);
    expect((drLine['base_amount'] as num).toDouble(), closeTo(75, 0.01));
    expect((crLine['base_amount'] as num).toDouble(), closeTo(75, 0.01));

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_finance_voucher', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'trans_no': transNo,
          'trans_date': today,
          'voucher_type_code': 'JV',
          'remarks': 'edited',
        },
        'p_lines': [
          {
            'serial_no': 1,
            'account_id': expenseAccountId,
            'trans_nature': 'DR',
            'trans_amount': 999,
            'trans_currency': 'USD',
            'base_amount': 999,
          },
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Journal Voucher must be rejected',
    );
  });

  test('Journal Voucher: an unbalanced entry is rejected', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    await expectLater(
      verifier.rpc('fn_save_finance_voucher', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'trans_no': null,
          'trans_date': today,
          'voucher_type_code': 'JV',
          'remarks': 'QA backend test - unbalanced',
        },
        'p_lines': [
          {
            'serial_no': 1,
            'account_id': expenseAccountId,
            'trans_nature': 'DR',
            'trans_amount': 100,
            'trans_currency': 'USD',
            'base_amount': 100,
          },
          {
            'serial_no': 2,
            'account_id': cashAccountId,
            'trans_nature': 'CR',
            'trans_amount': 50,
            'trans_currency': 'USD',
            'base_amount': 50,
          },
        ],
        'p_user_id': verifier.userId,
      }).then((transNo) => verifier.rpc('fn_post_finance_voucher', {
            'p_client_id': verifier.clientId,
            'p_company_id': verifier.companyId,
            'p_location_id': TestTenantConfig.locationId,
            'p_trans_no': transNo,
            'p_trans_date': today,
            'p_posted_by': verifier.userId,
          })),
      throwsA(anything),
      reason: 'Posting an unbalanced (Dr != Cr) voucher must be rejected',
    );
  });
}

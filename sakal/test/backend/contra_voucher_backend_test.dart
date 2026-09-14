import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for FN-CTR (Contra Voucher) — calls
/// fn_save_finance_voucher/fn_post_finance_voucher with
/// voucher_type_code='CTR'. Per CLAUDE.md's Contra Voucher section, this
/// reuses the exact same generic engine as Journal Voucher, completely
/// unchanged — this test's real purpose is confirming that claim: the
/// engine posts correctly under the 'CTR' type too, same-currency
/// Cash-to-Cash (FROM=CR, TO=DR by convention, though the DB function
/// itself doesn't enforce which line is which — that's a UI picker
/// restriction).
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
      {'account_code': 'eq.5210'}, // "Administrative Expenses" (same-currency
      // counterparty leg — a real Contra Voucher would use another Cash/
      // Bank account, but the DB engine itself is nature-agnostic; the
      // Cash/Bank restriction is a UI picker convention, not enforced here).
      select: 'id',
    );
    expenseAccountId = expense['id'] as String;
  });

  test('Contra Voucher: posts through the generic engine under CTR type', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final transNo = await verifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'trans_no': null,
        'trans_date': today,
        'voucher_type_code': 'CTR',
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'account_id': cashAccountId,
          'trans_nature': 'CR',
          'trans_amount': 40,
          'trans_currency': 'USD',
          'base_amount': 40,
          'base_rate': 1,
          'local_amount': 40,
          'local_rate': 1,
          'party_amount': 40,
          'party_currency': 'USD',
          'party_rate': 1,
        },
        {
          'serial_no': 2,
          'account_id': expenseAccountId,
          'trans_nature': 'DR',
          'trans_amount': 40,
          'trans_currency': 'USD',
          'base_amount': 40,
          'base_rate': 1,
          'local_amount': 40,
          'local_rate': 1,
          'party_amount': 40,
          'party_currency': 'USD',
          'party_rate': 1,
        },
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_finance_headers',
      {'trans_no': 'eq.$transNo'},
      select: 'trans_no,is_posted,voucher_type_code',
    );
    expect(draft['is_posted'], isFalse);
    expect(draft['voucher_type_code'], 'CTR');

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
  });
}

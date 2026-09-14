import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for FN-PRV (Payment/Receipt Voucher) — calls
/// fn_save_finance_voucher/fn_post_finance_voucher with voucher_type_code
/// 'CPV' (Cash Payment Voucher), is_on_account=true (an "On Account"
/// payment, not settling a specific bill). This is the exact scenario
/// where bug #3 (Party Amount not populating on-screen) was found and
/// fixed earlier today (a172574) — that fix was UI-only (a rendering
/// condition), so this test instead confirms the DATA side: party_amount
/// is correctly saved and readable back, which was never actually broken
/// (the bug was purely that the UI hid an already-correct value).
///
/// NOTE — a real inconsistency found while researching this test, not
/// fixed here: `fn_post_finance_voucher`'s Against-Bill settlement lookup
/// (migration 037) matches a line's `inv_bill_no` against another
/// voucher's own `trans_no` (`WHERE trans_no = v_line.inv_bill_no`) — this
/// works for Sales Invoice/Cash Receipt (which tag inv_bill_no with the
/// ORIGINAL POSTING VOUCHER's own trans_no, confirmed in
/// cash_receipt_backend_test.dart) but NOT for Expense Voucher (which
/// tags inv_bill_no with the user's own paper bill_no, e.g. "QA-BILL-001"
/// — confirmed via migration 107 line ~498) or Purchase Bill (which
/// CLAUDE.md documents as tagging the SUPPLIER's own invoice number).
/// A Payment Voucher trying to settle "Against Bill" for an Expense-
/// Voucher- or Purchase-Bill-originated payable would silently compute
/// was_balance=0 (the lookup finds nothing, `coalesce(...,0)` masks it)
/// rather than the real outstanding balance — worth a real follow-up
/// investigation, out of scope for fixing in this test session.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late String cashAccountId;

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
  });

  test('Payment Voucher: On Account payment to supplier, party_amount round-trips correctly', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final transNo = await verifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'trans_no': null,
        'trans_date': today,
        'voucher_type_code': 'CPV',
        'is_on_account': true,
        'remarks': 'QA backend test - on account payment',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'account_id': TestTenantConfig.supplierId,
          'trans_nature': 'DR',
          'trans_amount': 45,
          'trans_currency': 'USD',
          'base_amount': 45,
          'base_rate': 1,
          'local_amount': 45,
          'local_rate': 1,
          // The exact field bug #3 was about — On Account line's Party
          // Amount. Same-currency here (supplier has no ledger currency
          // configured, confirmed earlier this session), so party_amount
          // should equal trans_amount exactly.
          'party_amount': 45,
          'party_currency': 'USD',
          'party_rate': 1,
        },
        {
          'serial_no': 2,
          'account_id': cashAccountId,
          'trans_nature': 'CR',
          'trans_amount': 45,
          'trans_currency': 'USD',
          'base_amount': 45,
          'base_rate': 1,
          'local_amount': 45,
          'local_rate': 1,
          'party_amount': 45,
          'party_currency': 'USD',
          'party_rate': 1,
        },
      ],
      'p_user_id': verifier.userId,
    });

    await verifier.rpc('fn_post_finance_voucher', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_trans_no': transNo,
      'p_trans_date': today,
      'p_posted_by': verifier.userId,
    });

    final supplierLine = await verifier.getOne(
      'rid_finance_lines',
      {'trans_no': 'eq.$transNo', 'trans_date': 'eq.$today', 'account_id': 'eq.${TestTenantConfig.supplierId}'},
      select: 'trans_nature,trans_amount,party_amount,party_currency',
    );
    expect(supplierLine['trans_nature'], 'DR');
    expect((supplierLine['party_amount'] as num).toDouble(), closeTo(45, 0.01),
        reason: 'party_amount must be correctly saved regardless of the earlier UI-display bug (a172574)');
  });
}

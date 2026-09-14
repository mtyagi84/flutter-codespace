import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for FN-EXP (Expense Voucher) — calls
/// fn_save_expense_voucher/fn_approve_expense_voucher directly. Unlike
/// Journal/Contra Voucher (which reuse the generic engine unchanged), this
/// module has its own real source-document table
/// (`rih_expense_voucher_headers`, using `status` TEXT, NOT the generic
/// engine's `is_posted` boolean — confirmed live 2026-09-14) and its own
/// bespoke approve function that composes fn_post_voucher. No tax group
/// on the line here (a no-tax service bill) — the automatic-tax expansion
/// is a separate, more involved scenario left as a follow-up.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String expenseAccountId;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);

    final expense = await verifier.getOne(
      'rim_accounts',
      {'account_code': 'eq.5230'}, // "IT Expenses"
      select: 'id',
    );
    expenseAccountId = expense['id'] as String;
  });

  test('Expense Voucher: no-tax service bill, approve, immutability blocked', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final transNo = await verifier.rpc('fn_save_expense_voucher', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'trans_no': null,
        'trans_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'bill_no': 'QA-BILL-001',
        'bill_date': today,
        'remarks': 'QA backend test',
      },
      'p_lines': [
        {
          'account_id': expenseAccountId,
          'amount': 60,
          'line_remarks': 'Internet service',
        },
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_expense_voucher_headers',
      {'trans_no': 'eq.$transNo'},
      select: 'trans_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_expense_voucher', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_trans_no': transNo,
      'p_trans_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_expense_voucher_headers',
      {'trans_no': 'eq.$transNo'},
      select: 'trans_no,status,posted_voucher_no',
    );
    expect(approved['status'], 'APPROVED');
    expect(approved['posted_voucher_no'], isNotNull);

    // Bill-linkage is MANDATORY (not opt-in like JV's) — inv_bill_no/date
    // always = the header's own Bill No/Bill Date (CLAUDE.md's Expense
    // Voucher section). The supplier line must be findable via the
    // pending-bills mechanism by the bill's own number.
    final pendingBillLine = await verifier.getOne(
      'rid_finance_lines',
      {'inv_bill_no': 'eq.QA-BILL-001'},
      select: 'inv_bill_no,account_id,trans_nature',
    );
    expect(pendingBillLine['account_id'], TestTenantConfig.supplierId);
    expect(pendingBillLine['trans_nature'], 'CR');

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_expense_voucher', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'trans_no': transNo,
          'trans_date': today,
          'supplier_id': TestTenantConfig.supplierId,
          'currency_id': refs.currencyId,
          'bill_no': 'QA-BILL-001-EDITED',
          'bill_date': today,
          'remarks': 'edited',
        },
        'p_lines': [
          {'account_id': expenseAccountId, 'amount': 999},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Expense Voucher must be rejected',
    );
  });
}

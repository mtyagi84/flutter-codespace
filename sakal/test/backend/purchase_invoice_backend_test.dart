import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for PR-INV (Purchase Invoice / Purchase Bill) — calls
/// fn_save_purchase_invoice/fn_approve_purchase_invoice directly. Needs an
/// APPROVED GRN first (whole-GRN billing only, per CLAUDE.md's Purchase
/// Bill section) — creates and approves one via fn_save_grn/fn_approve_grn
/// in this file's own setUp, same as grn_backend_test.dart.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
  });

  test('Purchase Bill: bill an APPROVED GRN, approve, GRN gets linked', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: a fresh APPROVED GRN to bill against ──────────────────
    final grnNo = await verifier.rpc('fn_save_grn', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'grn_no': null,
        'grn_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'receipt_mode': 'DIRECT',
        'grn_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': 1000,
        'grand_total': 1000,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 100,
          'base_qty': 100,
          'rate': 10,
          'gross_amount': 1000,
          'final_amount': 1000,
          'base_amount': 1000,
          'local_amount': 1000,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    });
    await verifier.rpc('fn_approve_grn', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_grn_no': grnNo,
      'p_grn_date': today,
      'p_approved_by': verifier.userId,
    });

    // ── Act: raise a Purchase Bill against that GRN ────────────────────
    final invoiceNo = await verifier.rpc('fn_save_purchase_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'supplier_invoice_no': 'SUPP-INV-001',
        'supplier_invoice_date': today,
        'invoice_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'taxable_amount': 1000,
        'tax_amount': 0,
        'invoice_total': 1000,
      },
      'p_grn_refs': [
        {'grn_no': grnNo, 'grn_date': today},
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_purchase_invoices',
      {'invoice_no': 'eq.$invoiceNo'},
      select: 'invoice_no,status',
    );
    expect(draft['status'], 'DRAFT');

    final grnAfterBillDraft = await verifier.getOne(
      'rih_grn_headers',
      {'grn_no': 'eq.$grnNo'},
      select: 'billed_invoice_no',
    );
    expect(grnAfterBillDraft['billed_invoice_no'], invoiceNo,
        reason: 'A GRN is reserved onto its Purchase Bill at DRAFT save already, per CLAUDE.md');

    // ── Assert: a second bill can't double-claim the same GRN ──────────
    await expectLater(
      verifier.rpc('fn_save_purchase_invoice', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'invoice_no': null,
          'invoice_date': today,
          'supplier_id': TestTenantConfig.supplierId,
          'supplier_invoice_no': 'SUPP-INV-002',
          'supplier_invoice_date': today,
          'invoice_currency_id': refs.currencyId,
          'taxable_amount': 1000,
          'invoice_total': 1000,
        },
        'p_grn_refs': [
          {'grn_no': grnNo, 'grn_date': today},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'A GRN already reserved onto one Purchase Bill must be rejected on a second',
    );

    // ── Act: approve the bill ───────────────────────────────────────────
    await verifier.rpc('fn_approve_purchase_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_purchase_invoices',
      {'invoice_no': 'eq.$invoiceNo'},
      select: 'invoice_no,status,posted_voucher_no',
    );
    expect(approved['status'], 'APPROVED');
    expect(approved['posted_voucher_no'], isNotNull,
        reason: 'Approve must post a PUR voucher and record its number');

    // Pending-bills mechanism (CLAUDE.md: inv_bill_no rides v_pending_bills
    // for free) — the supplier's payable must now be findable via the
    // SUPPLIER's own invoice number, not our internal invoice_no.
    final pendingBillLine = await verifier.getOne(
      'rid_finance_lines',
      {'inv_bill_no': 'eq.SUPP-INV-001'},
      select: 'inv_bill_no,account_id',
    );
    expect(pendingBillLine['account_id'], TestTenantConfig.supplierId);

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_purchase_invoice', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'invoice_no': invoiceNo,
          'invoice_date': today,
          'supplier_id': TestTenantConfig.supplierId,
          'supplier_invoice_no': 'SUPP-INV-001-EDITED',
          'invoice_currency_id': refs.currencyId,
          'taxable_amount': 2000,
          'invoice_total': 2000,
        },
        'p_grn_refs': [
          {'grn_no': grnNo, 'grn_date': today},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Purchase Bill must be rejected',
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for SL-CINV (Credit Sales Invoice) — reuses
/// fn_save_sales_invoice with `p_credit_invoice_screen: true` (per
/// CLAUDE.md, this is the same rih_sales_invoices engine as Quick Invoice,
/// gated by that flag). Covers the module's OWN distinguishing behaviors,
/// not already exercised by sales_invoice_backend_test.dart or
/// sales_delivery_backend_test.dart: the hard future-date block and the
/// date-lock-after-first-save rule, both added in migration 146.
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

    // A sellable line needs an established cost price (COST_PRICE_NOT_
    // AVAILABLE otherwise) — confirmed live 2026-09-14 when this test's
    // own "create a valid DRAFT" step failed with exactly that error,
    // since resetQaTenant() wipes stock/cost and this file never received
    // any stock via GRN. Every other sales backend test already does this;
    // this file just needed the same setup.
    final today = DateTime.now().toIso8601String().split('T').first;
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
        'gross_amount': 500,
        'grand_total': 500,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 50,
          'base_qty': 50,
          'rate': 10,
          'gross_amount': 500,
          'final_amount': 500,
          'base_amount': 500,
          'local_amount': 500,
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
  });

  test('Credit Sales Invoice: future-date blocked, date locked after first save', () async {
    final today = DateTime.now();
    final todayStr = today.toIso8601String().split('T').first;
    final tomorrowStr = today.add(const Duration(days: 1)).toIso8601String().split('T').first;
    final yesterdayStr = today.subtract(const Duration(days: 1)).toIso8601String().split('T').first;

    // Hard future-date block — non-configurable, scoped to this screen
    // only (migration 146's own comment).
    var threw = false;
    try {
      await verifier.rpc('fn_save_sales_invoice', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'invoice_no': null,
          'invoice_date': tomorrowStr,
          'invoice_mode': 'DIRECT',
          'sale_type': 'CREDIT',
          'customer_id': TestTenantConfig.customerId,
          'invoice_currency_id': refs.currencyId,
          'gross_amount': 50,
          'grand_total': 50,
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'base_qty': 5,
            'rate': 10,
            'price_override_reason': 'QA backend test',
            'final_amount': 50,
            'base_amount': 50,
            'local_amount': 50,
          },
        ],
        'p_charges': [],
        'p_batches': [],
        'p_serials': [],
        'p_user_id': verifier.userId,
        'p_credit_invoice_screen': true,
      });
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: 'A Credit Sales Invoice dated in the future must be rejected (FUTURE_DATE_NOT_ALLOWED)');

    // Create a valid DRAFT dated today, then try to change its date on a
    // second save — must be rejected (INVOICE_DATE_LOCKED_AFTER_FIRST_SAVE).
    final invoiceNo = await verifier.rpc('fn_save_sales_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': todayStr,
        'invoice_mode': 'DIRECT',
        'sale_type': 'CREDIT',
        'customer_id': TestTenantConfig.customerId,
        'invoice_currency_id': refs.currencyId,
        'gross_amount': 50,
        'grand_total': 50,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'base_qty': 5,
          'rate': 10,
          'price_override_reason': 'QA backend test',
          'final_amount': 50,
          'base_amount': 50,
          'local_amount': 50,
        },
      ],
      'p_charges': [],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
      'p_credit_invoice_screen': true,
    });

    final draft = await verifier.getOne(
      'rih_sales_invoices',
      {'invoice_no': 'eq.$invoiceNo'},
      select: 'invoice_no,status,invoice_date',
    );
    expect(draft['status'], 'DRAFT');
    expect(draft['invoice_date'], todayStr);

    var threwOnDateChange = false;
    try {
      await verifier.rpc('fn_save_sales_invoice', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'invoice_no': invoiceNo,
          'invoice_date': yesterdayStr,
          'invoice_mode': 'DIRECT',
          'sale_type': 'CREDIT',
          'customer_id': TestTenantConfig.customerId,
          'invoice_currency_id': refs.currencyId,
          'gross_amount': 50,
          'grand_total': 50,
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'base_qty': 5,
            'rate': 10,
            'price_override_reason': 'QA backend test',
            'final_amount': 50,
            'base_amount': 50,
            'local_amount': 50,
          },
        ],
        'p_charges': [],
        'p_batches': [],
        'p_serials': [],
        'p_user_id': verifier.userId,
        'p_credit_invoice_screen': true,
      });
    } catch (_) {
      threwOnDateChange = true;
    }
    expect(threwOnDateChange, isTrue,
        reason: 'Changing the date on a re-saved Credit Sales Invoice DRAFT must be rejected (INVOICE_DATE_LOCKED_AFTER_FIRST_SAVE)');
  });
}

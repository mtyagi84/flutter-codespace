import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario (Phase A, edge case #2): a genuinely multi-currency
/// Purchase-to-Pay chain. Every other scenario in this suite keeps
/// `rate_to_base: 1` for simplicity (transacting in the company's own
/// base currency, USD) — this one raises the PO/GRN/Purchase Invoice/
/// Payment all in the tenant's real LOCAL currency (CDF, the only other
/// currency with a real seeded exchange rate — `fn_get_exchange_rate`
/// only ever queries the from_currency=base_currency direction, per
/// `018_exchange_rates.sql`'s own comment, so CDF is the only genuine
/// non-1.0-rate option this fixture supports without adding a new rate
/// row), and verifies the base-currency conversion actually flows through
/// correctly at every step — not just that a rate field was stored.
///
/// Numbers: buy 10 units at 141,250 CDF/unit (= exactly $50/unit at the
/// tenant's real seeded rate of 2825 CDF/USD) = 1,412,500 CDF = $500 total.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late String cdfCurrencyId;
  late double rateToBase; // CDF -> USD

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);

    final cdf = await verifier.getOne('rim_currencies', {'currency_id': 'eq.CDF'}, select: 'id');
    cdfCurrencyId = cdf['id'] as String;

    final rateRow = await verifier.getOne(
      'rim_exchange_rates',
      {'from_currency': 'eq.USD', 'to_currency': 'eq.CDF', 'limit': '1'},
      select: 'exchange_rate',
    );
    final cdfPerUsd = (rateRow['exchange_rate'] as num).toDouble();
    rateToBase = 1 / cdfPerUsd; // USD per CDF
  });

  test('Multi-currency Purchase-to-Pay: PO/GRN/Invoice/Payment all in CDF, base conversion correct throughout', () async {
    final today = todayStr();
    const qty = 10.0;
    final rateCdfPerUnit = 50 / rateToBase; // exactly $50/unit worth of CDF
    final grossCdf = qty * rateCdfPerUnit;

    // ── PO in CDF ────────────────────────────────────────────────────────
    final orderNo = await verifier.rpc('fn_save_purchase_order', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'order_no': null,
        'order_date': today,
        'po_type': 'LOCAL',
        'supplier_id': TestTenantConfig.supplierId,
        'po_currency_id': cdfCurrencyId,
        'rate_to_base': rateToBase,
        'rate_to_local': 1,
        'gross_amount': grossCdf,
        'discount_amount': 0,
        'charges_amount': 0,
        'item_tax_amount': 0,
        'charge_tax_amount': 0,
        'grand_total': grossCdf,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': qty,
          'qty_loose': 0,
          'base_qty': qty,
          'rate': rateCdfPerUnit,
          'gross_amount': grossCdf,
          'discount_percent': 0,
          'discount_amount': 0,
          'tax_amount': 0,
          'final_amount': grossCdf,
          'base_amount': grossCdf * rateToBase,
          'local_amount': grossCdf,
          'charge_amount': 0,
          'landed_amount': grossCdf,
          'qty_on_hand_at_order': 0,
          'reorder_level_at_order': 0,
        },
      ],
      'p_charges': [],
      'p_payment_terms': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_purchase_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_approved_by': verifier.userId,
    });

    // ── GRN AGAINST_PO, same CDF currency ───────────────────────────────
    final grnNo = await verifier.rpc('fn_save_grn', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'grn_no': null,
        'grn_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'receipt_mode': 'AGAINST_PO',
        'grn_currency_id': cdfCurrencyId,
        'rate_to_base': rateToBase,
        'rate_to_local': 1,
        'gross_amount': grossCdf,
        'grand_total': grossCdf,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'source_po_order_no': orderNo,
          'source_po_order_date': today,
          'source_po_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': qty,
          'qty_loose': 0,
          'base_qty': qty,
          'rate': rateCdfPerUnit,
          'gross_amount': grossCdf,
          'final_amount': grossCdf,
          'base_amount': grossCdf * rateToBase,
          'local_amount': grossCdf,
          'charge_amount': 0,
          'landed_amount': grossCdf,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_charges': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_grn', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_grn_no': grnNo,
      'p_grn_date': today,
      'p_approved_by': verifier.userId,
    });

    final stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 10);
    expect(stock.costPrice, closeTo(50, 0.5),
        reason: '141,250 CDF/unit at the real seeded rate must convert to exactly \$50/unit base cost');

    // GRN's own provisional accrual — trans_currency is CDF (the GRN's
    // own currency), but base_amount must reflect the real $500 converted
    // value, proving the currency conversion actually flows into the GL
    // posting, not just sits unused on the header.
    final grnLines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'GRN', sourceDocNo: grnNo, voucherTypeCode: 'JV',
    );
    ScenarioHelpers.assertLinesBalance(grnLines);
    final grnStockLine = grnLines.firstWhere((l) => l['account_id'] == TestTenantConfig.stockAccountId);
    expect(grnStockLine['trans_currency'], 'CDF');
    expect((grnStockLine['trans_amount'] as num).toDouble(), closeTo(grossCdf, 1));
    expect((grnStockLine['base_amount'] as num).toDouble(), closeTo(500, 0.5),
        reason: 'base_amount must be the real USD-equivalent (~\$500), not the raw CDF figure');

    // ── Purchase Invoice, same CDF currency ─────────────────────────────
    final invoiceNo = await verifier.rpc('fn_save_purchase_invoice', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'invoice_no': null,
        'invoice_date': today,
        'supplier_id': TestTenantConfig.supplierId,
        'supplier_invoice_no': 'QA-SCEN-FX-BILL',
        'supplier_invoice_date': today,
        'invoice_currency_id': cdfCurrencyId,
        'rate_to_base': rateToBase,
        'rate_to_local': 1,
        'taxable_amount': grossCdf,
        'tax_amount': 0,
        'invoice_total': grossCdf,
      },
      'p_grn_refs': [
        {'grn_no': grnNo, 'grn_date': today},
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_purchase_invoice', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_invoice_no': invoiceNo,
      'p_invoice_date': today,
      'p_approved_by': verifier.userId,
    });

    // Supplier ledger, forced to BASE mode — must show ~$500 Cr regardless
    // of the fact every document in this chain was raised in CDF.
    final ledgerAfterBill = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.supplierId,
      'p_date_from': today,
      'p_date_to': today,
      'p_currency_mode': 'BASE',
    });
    final billRow = (ledgerAfterBill as List).first as Map<String, dynamic>;
    expect((billRow['running_balance'] as num).toDouble(), closeTo(500, 0.5));
    expect(billRow['running_balance_type'], 'Cr');

    // ── Payment, also in CDF, on-account ─────────────────────────────────
    final cashCdf = await verifier.getOne('rim_accounts', {'account_code': 'eq.1110001002'}, select: 'id'); // "Cash In Had CDF"
    final payTransNo = await verifier.rpc('fn_save_finance_voucher', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'trans_no': null,
        'trans_date': today,
        'voucher_type_code': 'CPV',
        'is_on_account': true,
        'remarks': 'QA scenario test - multi-currency on-account payment',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'account_id': TestTenantConfig.supplierId,
          'trans_nature': 'DR',
          'trans_amount': grossCdf,
          'trans_currency': 'CDF',
          'base_amount': grossCdf * rateToBase,
          'base_rate': rateToBase,
          'local_amount': grossCdf,
          'local_rate': 1,
          'party_amount': grossCdf,
          'party_currency': 'CDF',
          'party_rate': 1,
        },
        {
          'serial_no': 2,
          'account_id': cashCdf['id'],
          'trans_nature': 'CR',
          'trans_amount': grossCdf,
          'trans_currency': 'CDF',
          'base_amount': grossCdf * rateToBase,
          'base_rate': rateToBase,
          'local_amount': grossCdf,
          'local_rate': 1,
          'party_amount': grossCdf,
          'party_currency': 'CDF',
          'party_rate': 1,
        },
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_post_finance_voucher', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_trans_no': payTransNo,
      'p_trans_date': today,
      'p_posted_by': verifier.userId,
    });

    final ledgerAfterPayment = await verifier.rpc('fn_account_ledger_totals', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_account_id': TestTenantConfig.supplierId,
      'p_date_from': today,
      'p_date_to': today,
      'p_currency_mode': 'BASE',
    });
    final payRow = (ledgerAfterPayment as List).first as Map<String, dynamic>;
    expect((payRow['running_balance'] as num).toDouble(), closeTo(0, 0.5),
        reason: 'Paying the exact CDF amount owed must net the base-currency ledger to zero');

    // The ultimate proof of internal consistency: if any of the several
    // independently-computed CDF->base conversions above were wrong, the
    // base_amount DR=CR balance check inside fn_post_voucher/fn_post_
    // finance_voucher would have already rejected the offending voucher
    // outright — Trial Balance still reconciling here confirms the WHOLE
    // chain's conversions are mutually consistent, not just individually
    // plausible.
    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}

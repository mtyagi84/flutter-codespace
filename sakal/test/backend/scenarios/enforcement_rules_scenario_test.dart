import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario (Phase A, edge cases #3-5): proves four separate
/// enforcement rules actually fire live, not just that they exist in the
/// codebase — each one guards against a real production risk that a
/// "happy path" scenario would never exercise:
///   1. Permission denial (CCC #6) — a user without approve_allowed for a
///      feature must be rejected by the RPC itself, not just hidden by
///      the UI.
///   2. Period Close — a transaction dated inside a locked period must be
///      rejected at Approve.
///   3. Backdated Entry Control — a transaction dated further back than
///      the configured limit must be rejected at Approve.
///   4. Negative Stock — an untracked product with default flags can
///      never be oversold into a negative balance.
///
/// Each sub-test cleans up its own fixture state (deactivating the period
/// lock / backdate control it created) since these tables are master/
/// setup data `resetQaTenant()` never touches, and a lingering lock or
/// control row could silently break every OTHER test file's own GRN
/// fixtures that run after this one in the same `--concurrency=1` suite.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);

    // uq_users_client_username is a plain (not partial) UNIQUE index — a
    // stale user from a prior run of this file needs its username renamed,
    // not just soft-deleted (same gotcha found in
    // user_management_backend_test.dart's own setUpAll).
    final staleUsers = await verifier.get('rim_users', {'username': 'eq.qa_crud_restricted'}, select: 'id');
    for (final row in staleUsers) {
      await verifier.patch('rim_users', {'id': 'eq.${row['id']}'},
          {'is_deleted': true, 'is_active': false, 'username': 'qa_crud_restricted_stale_${row['id']}'});
    }
  });

  test('Permission denial: a user without approve_allowed is rejected by the RPC itself', () async {
    final today = todayStr();

    // Admin creates and saves the PO as a normal DRAFT.
    final orderNo = await verifier.rpc('fn_save_purchase_order', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'order_no': null,
        'order_date': today,
        'po_type': 'LOCAL',
        'supplier_id': TestTenantConfig.supplierId,
        'po_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
        'gross_amount': 100,
        'grand_total': 100,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 2,
          'base_qty': 2,
          'rate': 50,
          'gross_amount': 100,
          'final_amount': 100,
          'base_amount': 100,
          'local_amount': 100,
        },
      ],
      'p_charges': [],
      'p_payment_terms': [],
      'p_user_id': verifier.userId,
    }) as String;

    // A fresh user gets NO ric_user_menus rows at all by default — missing
    // row = deny, never permissive (CLAUDE.md's own documented convention
    // for fn_check_approve_permission).
    final restrictedUserId = await verifier.rpc('fn_create_user', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_location_id': TestTenantConfig.locationId,
      'p_username': 'qa_crud_restricted',
      'p_full_name': 'QA CRUD Restricted User',
      'p_password': 'QaCrudRestricted#2026',
      'p_must_change_password': false,
      'p_created_by': verifier.userId,
    }) as String;
    expect(restrictedUserId, isNotNull);

    final restrictedVerifier = BackendVerifier();
    await restrictedVerifier.loginAs('qa_crud_restricted', 'QaCrudRestricted#2026');

    var threw = false;
    try {
      await restrictedVerifier.rpc('fn_approve_purchase_order', {
        'p_client_id': restrictedVerifier.clientId,
        'p_company_id': restrictedVerifier.companyId,
        'p_order_no': orderNo,
        'p_order_date': today,
        'p_approved_by': restrictedVerifier.userId,
      });
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: 'A user with no PR-PO approve_allowed row must be rejected by fn_approve_purchase_order itself, not just hidden by the UI');

    // Confirm the PO is genuinely still DRAFT (the rejected attempt had no
    // partial effect) and that the ADMIN can still approve it normally —
    // proves this is a real per-user denial, not a broken function.
    final stillDraft = await verifier.getOne('rih_purchase_orders', {'order_no': 'eq.$orderNo'}, select: 'status');
    expect(stillDraft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_purchase_order', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_order_no': orderNo,
      'p_order_date': today,
      'p_approved_by': verifier.userId,
    });
    final nowApproved = await verifier.getOne('rih_purchase_orders', {'order_no': 'eq.$orderNo'}, select: 'status');
    expect(nowApproved['status'], 'APPROVED');
  });

  test('Period Close: a transaction dated inside a locked period is rejected at Approve', () async {
    final today = todayStr();

    final lock = await verifier.insert('ric_period_locks', {
      'period_start_date': today,
      'period_end_date': today,
      'locked_by': verifier.userId,
      'is_active': true,
    });

    try {
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
          'gross_amount': 100,
          'grand_total': 100,
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'uom_conversion_factor': 1,
            'qty_pack': 2,
            'base_qty': 2,
            'rate': 50,
            'gross_amount': 100,
            'final_amount': 100,
            'base_amount': 100,
            'local_amount': 100,
          },
        ],
        'p_batches': [],
        'p_serials': [],
        'p_charges': [],
        'p_user_id': verifier.userId,
      }) as String;

      var threw = false;
      try {
        await verifier.rpc('fn_approve_grn', {
          'p_client_id': verifier.clientId,
          'p_company_id': verifier.companyId,
          'p_grn_no': grnNo,
          'p_grn_date': today,
          'p_approved_by': verifier.userId,
        });
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue, reason: 'Approving a GRN dated inside a locked period must be rejected (PERIOD_LOCKED)');
    } finally {
      // Cleanup — this table is master/setup data, not wiped by
      // resetQaTenant(), and a lingering lock covering "today" would
      // break every OTHER GRN/transaction test that runs after this one.
      await verifier.patch('ric_period_locks', {'id': 'eq.${lock['id']}'}, {
        'is_active': false,
        'reopened_by': verifier.userId,
        'reopened_at': DateTime.now().toIso8601String(),
        'reopen_reason': 'QA scenario test cleanup',
      });
    }
  });

  test('Backdated Entry Control: a transaction dated further back than the limit is rejected at Approve', () async {
    final today = DateTime.now();
    final fiveDaysAgo = today.subtract(const Duration(days: 5)).toIso8601String().split('T').first;

    // Rename/deactivate any leftover control row from a previous run
    // (plain, not partial, UNIQUE(client_id, company_id, transaction_type)
    // — same pattern as system_setup_backend_test.dart's own cleanup).
    final stale = await verifier.get('ric_backdated_entry_control', {'transaction_type': 'eq.GRN'}, select: 'id');
    for (final row in stale) {
      await verifier.delete('ric_backdated_entry_control', {'id': 'eq.${row['id']}'});
    }

    final control = await verifier.insert('ric_backdated_entry_control', {
      'transaction_type': 'GRN',
      'max_backdate_days': 1,
      'allow_future_date': false,
      'is_active': true,
    });

    try {
      final grnNo = await verifier.rpc('fn_save_grn', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'grn_no': null,
          'grn_date': fiveDaysAgo,
          'supplier_id': TestTenantConfig.supplierId,
          'receipt_mode': 'DIRECT',
          'grn_currency_id': refs.currencyId,
          'rate_to_base': 1,
          'rate_to_local': 1,
          'gross_amount': 100,
          'grand_total': 100,
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'uom_conversion_factor': 1,
            'qty_pack': 2,
            'base_qty': 2,
            'rate': 50,
            'gross_amount': 100,
            'final_amount': 100,
            'base_amount': 100,
            'local_amount': 100,
          },
        ],
        'p_batches': [],
        'p_serials': [],
        'p_charges': [],
        'p_user_id': verifier.userId,
      }) as String;

      var threw = false;
      try {
        await verifier.rpc('fn_approve_grn', {
          'p_client_id': verifier.clientId,
          'p_company_id': verifier.companyId,
          'p_grn_no': grnNo,
          'p_grn_date': fiveDaysAgo,
          'p_approved_by': verifier.userId,
        });
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue, reason: 'A GRN dated 5 days back must be rejected when max_backdate_days=1 (BACKDATE_NOT_ALLOWED)');
    } finally {
      await verifier.delete('ric_backdated_entry_control', {'id': 'eq.${control['id']}'});
    }
  });

  test('Negative Stock: an untracked product with default flags can never be oversold', () async {
    final today = todayStr();

    // A small GRN establishes SOME stock, but nowhere near enough for the
    // oversell attempt below.
    await ScenarioHelpers.establishStockViaDirectGrn(verifier, refs, qty: 2, rate: 50);
    final stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 2);

    var threw = false;
    try {
      final invoiceNo = await verifier.rpc('fn_save_sales_invoice', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'invoice_no': null,
          'invoice_date': today,
          'invoice_mode': 'DIRECT',
          'sale_type': 'CREDIT',
          'customer_id': TestTenantConfig.customerId,
          'invoice_currency_id': refs.currencyId,
          'gross_amount': 500,
          'grand_total': 500,
        },
        'p_lines': [
          {
            'serial_no': 1,
            'product_id': TestTenantConfig.productId,
            'uom_id': refs.uomId,
            'base_qty': 10, // far more than the 2 units in stock
            'rate': 50,
            'price_override_reason': 'QA scenario test',
            'final_amount': 500,
            'base_amount': 500,
            'local_amount': 500,
          },
        ],
        'p_charges': [],
        'p_batches': [],
        'p_serials': [],
        'p_user_id': verifier.userId,
      });
      await verifier.rpc('fn_approve_sales_invoice', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_invoice_no': invoiceNo,
        'p_invoice_date': today,
        'p_approved_by': verifier.userId,
      });
    } catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: 'Selling 10 units of an untracked product with only 2 in stock, and default (false) allow_negative_stock flags, must be rejected (NEGATIVE_STOCK_NOT_ALLOWED)');

    final stockAfter = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stockAfter.currentStock, 2, reason: 'A rejected oversell must leave stock completely unchanged');
  });
}

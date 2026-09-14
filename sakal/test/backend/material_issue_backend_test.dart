import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-MIS (Material Issue) — calls
/// fn_save_material_issue/fn_approve_material_issue directly, consolidating
/// against a fresh APPROVED Material Requisition (this schema's only path
/// to a resolvable department/consumption-area expense account). Verifies
/// stock decreases and the Dr Expense/Cr Stock GL pair actually posts.
///
/// See grn_backend_test.dart's doc comment for why this backend-RPC
/// pattern is used instead of `flutter drive` UI automation.
void main() {
  late BackendVerifier verifier;
  late CommonRefs refs;
  late DepartmentAreaRef deptArea;

  setUpAll(() async {
    verifier = BackendVerifier();
    await verifier.login();
    await resetQaTenant(verifier);
    refs = await CommonRefs.load(verifier);
    deptArea = await CommonRefs.loadOrCreateDepartmentArea(verifier);
  });

  test('Material Issue: consolidate a requisition, approve, stock decreases + GL posts', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    // ── Arrange: stock via a fresh GRN, then an APPROVED requisition ────
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

    final requisitionNo = await verifier.rpc('fn_save_material_requisition', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'requisition_no': null,
        'requisition_date': today,
        'reason': 'QA backend test - for Material Issue',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 20,
          'base_qty': 20,
          'department_id': deptArea.departmentId,
          'consumption_area_id': deptArea.consumptionAreaId,
        },
      ],
      'p_user_id': verifier.userId,
    });
    await verifier.rpc('fn_approve_material_requisition', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_requisition_no': requisitionNo,
      'p_requisition_date': today,
      'p_approved_by': verifier.userId,
    });

    // ── Act: issue against that requisition ─────────────────────────────
    final issueNo = await verifier.rpc('fn_save_material_issue', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'issue_no': null,
        'issue_date': today,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'source_requisition_no': requisitionNo,
          'source_requisition_date': today,
          'source_requisition_line_serial': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 20,
          'base_qty': 20,
          'department_id': deptArea.departmentId,
          'consumption_area_id': deptArea.consumptionAreaId,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_material_issue_headers',
      {'issue_no': 'eq.$issueNo'},
      select: 'issue_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_material_issue', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_issue_no': issueNo,
      'p_issue_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_material_issue_headers',
      {'issue_no': 'eq.$issueNo'},
      select: 'issue_no,status',
    );
    expect(approved['status'], 'APPROVED');

    final stockAfterIssue = await verifier.getOne(
      'rim_product_location',
      {'product_id': 'eq.${TestTenantConfig.productId}', 'location_id': 'eq.${TestTenantConfig.locationId}'},
      select: 'current_stock',
    );
    expect((stockAfterIssue['current_stock'] as num).toDouble(), 30,
        reason: '50 received - 20 issued must leave exactly 30 in stock');

    // GL: Dr the mapped expense account, Cr Stock — both legs must exist.
    // source_doc_type/no/date live on rih_finance_headers, not
    // rid_finance_lines (per CLAUDE.md's Finance-line-traceability section)
    // — look up the MIC voucher's trans_no/trans_date first, then its lines.
    final micHeader = await verifier.getOne(
      'rih_finance_headers',
      {'source_doc_type': 'eq.MATERIAL_ISSUE', 'source_doc_no': 'eq.$issueNo'},
      select: 'trans_no,trans_date',
    );

    final expenseLine = await verifier.getOne(
      'rid_finance_lines',
      {
        'trans_no': 'eq.${micHeader['trans_no']}',
        'trans_date': 'eq.${micHeader['trans_date']}',
        'account_id': 'eq.${deptArea.accountId}',
      },
      select: 'trans_nature,base_amount',
    );
    expect(expenseLine['trans_nature'], 'DR');
    expect((expenseLine['base_amount'] as num).toDouble(), closeTo(200, 0.01),
        reason: '20 units at the GRN cost of 10/unit must post exactly 200');

    final stockCreditLine = await verifier.getOne(
      'rid_finance_lines',
      {
        'trans_no': 'eq.${micHeader['trans_no']}',
        'trans_date': 'eq.${micHeader['trans_date']}',
        'account_id': 'eq.${TestTenantConfig.stockAccountId}',
      },
      select: 'trans_nature,base_amount',
    );
    expect(stockCreditLine['trans_nature'], 'CR');
    expect((stockCreditLine['base_amount'] as num).toDouble(), closeTo(200, 0.01));
  });
}

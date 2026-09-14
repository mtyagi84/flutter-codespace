import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

import 'scenario_helpers.dart';

/// Business scenario 6: Material Requisition -> Material Issue, verifying
/// the CUMULATIVE stock + GL effect (the existing per-document test files
/// already check each step's status transition; this checks the numbers
/// actually land where a real day-to-day consumption cycle expects).
///
/// Numbers: establish 10 units @ $50, requisition + issue 3 units to a
/// department's consumption area.
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

  test('Material Requisition -> Issue: stock decreases, Dr Expense / Cr Stock posts exactly', () async {
    final today = todayStr();

    await ScenarioHelpers.establishStockViaDirectGrn(verifier, refs, qty: 10, rate: 50);
    var stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 10);
    expect(stock.costPrice, closeTo(50, 0.01));

    final requisitionNo = await verifier.rpc('fn_save_material_requisition', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'requisition_no': null,
        'requisition_date': today,
        'reason': 'QA scenario test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 3,
          'qty_loose': 0,
          'base_qty': 3,
          'department_id': deptArea.departmentId,
          'consumption_area_id': deptArea.consumptionAreaId,
        },
      ],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_material_requisition', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_requisition_no': requisitionNo,
      'p_requisition_date': today,
      'p_approved_by': verifier.userId,
    });

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
          'qty_pack': 3,
          'base_qty': 3,
          'department_id': deptArea.departmentId,
          'consumption_area_id': deptArea.consumptionAreaId,
        },
      ],
      'p_batches': [],
      'p_serials': [],
      'p_user_id': verifier.userId,
    }) as String;

    await verifier.rpc('fn_approve_material_issue', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_issue_no': issueNo,
      'p_issue_date': today,
      'p_approved_by': verifier.userId,
    });

    stock = await ScenarioHelpers.stockAt(verifier, TestTenantConfig.locationId);
    expect(stock.currentStock, 7, reason: '10 - 3 issued must leave exactly 7 in stock');

    final lines = await ScenarioHelpers.financeLinesFor(
      verifier, sourceDocType: 'MATERIAL_ISSUE', sourceDocNo: issueNo,
    );
    ScenarioHelpers.assertLinesBalance(lines);

    final expenseLine = lines.firstWhere((l) => l['account_id'] == deptArea.accountId);
    expect(expenseLine['trans_nature'], 'DR');
    expect((expenseLine['base_amount'] as num).toDouble(), closeTo(150, 0.01),
        reason: '3 units at the GRN cost of 50/unit must post exactly 150');

    final stockLine = lines.firstWhere((l) => l['account_id'] == TestTenantConfig.stockAccountId);
    expect(stockLine['trans_nature'], 'CR');
    expect((stockLine['base_amount'] as num).toDouble(), closeTo(150, 0.01));

    await ScenarioHelpers.assertTrialBalanceBalances(verifier, dateFrom: today, dateTo: today);
  });
}

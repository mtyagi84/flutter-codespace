import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for IN-MRQ (Material Requisition) — calls
/// fn_save_material_requisition/fn_approve_material_requisition directly.
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

  test('Material Requisition: create DRAFT, approve; missing dept/area rejected', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final requisitionNo = await verifier.rpc('fn_save_material_requisition', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'requisition_no': null,
        'requisition_date': today,
        'reason': 'QA backend test',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'qty_pack': 5,
          'qty_loose': 0,
          'base_qty': 5,
          'department_id': deptArea.departmentId,
          'consumption_area_id': deptArea.consumptionAreaId,
        },
      ],
      'p_user_id': verifier.userId,
    });

    final draft = await verifier.getOne(
      'rih_material_requisition_headers',
      {'requisition_no': 'eq.$requisitionNo'},
      select: 'requisition_no,status',
    );
    expect(draft['status'], 'DRAFT');

    await verifier.rpc('fn_approve_material_requisition', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_requisition_no': requisitionNo,
      'p_requisition_date': today,
      'p_approved_by': verifier.userId,
    });

    final approved = await verifier.getOne(
      'rih_material_requisition_headers',
      {'requisition_no': 'eq.$requisitionNo'},
      select: 'requisition_no,status',
    );
    expect(approved['status'], 'APPROVED');

    // A requisition with a line missing department/consumption area must be
    // rejected at Approve (LINE_DEPARTMENT_AREA_REQUIRED) — this is exactly
    // the validation that would otherwise let Material Issue's GL posting
    // silently have nowhere to post an expense.
    final badRequisitionNo = await verifier.rpc('fn_save_material_requisition', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'requisition_no': null,
        'requisition_date': today,
        'reason': 'QA backend test - missing dept/area',
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'base_qty': 5,
        },
      ],
      'p_user_id': verifier.userId,
    });
    await expectLater(
      verifier.rpc('fn_approve_material_requisition', {
        'p_client_id': verifier.clientId,
        'p_company_id': verifier.companyId,
        'p_requisition_no': badRequisitionNo,
        'p_requisition_date': today,
        'p_approved_by': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Approving a requisition line with no department/consumption area must be rejected',
    );

    // Immutability (CCC #5).
    await expectLater(
      verifier.rpc('fn_save_material_requisition', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'requisition_no': requisitionNo,
          'requisition_date': today,
          'reason': 'edited',
        },
        'p_lines': [
          {'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'base_qty': 99},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(anything),
      reason: 'Editing an APPROVED Material Requisition must be rejected',
    );
  });
}

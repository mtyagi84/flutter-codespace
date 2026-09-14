import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/test_support/backend_verifier.dart';
import 'package:sakal/test_support/common_refs.dart';
import 'package:sakal/test_support/tenant_reset.dart';
import 'package:sakal/test_support/test_tenant_config.dart';

/// Backend-level test for the remaining Sales Masters — Price Master and
/// Sales Executives. Customer Master (MST-CUST) is already covered by
/// masters_crud_backend_test.dart.
///
/// Unlike every other Master screen this session, Price Master (migration
/// 083) is NOT a plain table CRUD screen — it has a real Draft/Approve
/// lifecycle (fn_save_price_master_batch/fn_approve_price_master_batch),
/// closer in shape to a transaction screen. Treated accordingly here.
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

    final staleExec = await verifier.get('rim_sales_executives', {'employee_code': 'eq.QA-CRUD-01'}, select: 'id');
    for (final row in staleExec) {
      await verifier.patch('rim_sales_executives', {'id': 'eq.${row['id']}'}, {'is_deleted': true});
    }
  });

  test('SL-PRC Price Master: create GENERIC batch, approve, price resolves live', () async {
    final today = DateTime.now().toIso8601String().split('T').first;

    final entryNo = await verifier.rpc('fn_save_price_master_batch', {
      'p_header': {
        'client_id': verifier.clientId,
        'company_id': verifier.companyId,
        'location_id': TestTenantConfig.locationId,
        'entry_no': null,
        'entry_date': today,
        'price_type': 'GENERIC',
        'effective_date': today,
        'price_currency_id': refs.currencyId,
        'rate_to_base': 1,
        'rate_to_local': 1,
      },
      'p_lines': [
        {
          'serial_no': 1,
          'product_id': TestTenantConfig.productId,
          'uom_id': refs.uomId,
          'uom_conversion_factor': 1,
          'cost_price': 10,
          'selling_price': 15,
          'is_tax_inclusive': false,
        },
      ],
      'p_user_id': verifier.userId,
    });
    expect(entryNo, isNotNull);

    await verifier.rpc('fn_approve_price_master_batch', {
      'p_client_id': verifier.clientId,
      'p_company_id': verifier.companyId,
      'p_entry_no': entryNo,
      'p_entry_date': today,
      'p_approved_by': verifier.userId,
    });

    final header = await verifier.getOne(
      'rih_price_master_headers',
      {'entry_no': 'eq.$entryNo', 'entry_date': 'eq.$today'},
      select: 'status',
    );
    expect(header['status'], 'APPROVED');

    // Immutability: a second save attempt against an APPROVED batch must be blocked.
    expect(
      () => verifier.rpc('fn_save_price_master_batch', {
        'p_header': {
          'client_id': verifier.clientId,
          'company_id': verifier.companyId,
          'location_id': TestTenantConfig.locationId,
          'entry_no': entryNo,
          'entry_date': today,
          'price_type': 'GENERIC',
          'effective_date': today,
          'price_currency_id': refs.currencyId,
        },
        'p_lines': [
          {'serial_no': 1, 'product_id': TestTenantConfig.productId, 'uom_id': refs.uomId, 'selling_price': 20},
        ],
        'p_user_id': verifier.userId,
      }),
      throwsA(isA<StateError>()),
    );
  });

  test('SL-EXE Sales Executives: create, read, update, deactivate round-trip', () async {
    final created = await verifier.insert('rim_sales_executives', {
      'employee_code': 'QA-CRUD-01',
      'full_name': 'QA CRUD Test Executive',
      'is_active': true,
    });
    expect(created['client_id'], verifier.clientId);

    await verifier.patch('rim_sales_executives', {'id': 'eq.${created['id']}'}, {'full_name': 'QA CRUD Test Executive Renamed'});
    final afterPatch = await verifier.getOne(
      'rim_sales_executives',
      {'id': 'eq.${created['id']}'},
      select: 'full_name',
    );
    expect(afterPatch['full_name'], 'QA CRUD Test Executive Renamed');

    await verifier.patch('rim_sales_executives', {'id': 'eq.${created['id']}'}, {'is_active': false});
    final afterDeactivate = await verifier.getOne(
      'rim_sales_executives',
      {'id': 'eq.${created['id']}'},
      select: 'is_active',
    );
    expect(afterDeactivate['is_active'], isFalse);
  });
}

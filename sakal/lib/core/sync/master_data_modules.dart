import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../database/app_database.dart';
import '../database/datasources/generic_lookup_local_ds.dart';
import '../database/datasources/accounts_local_ds.dart';
import '../database/datasources/product_uom_local_ds.dart';
import '../database/datasources/tax_group_members_local_ds.dart';
import '../database/datasources/tax_rates_local_ds.dart';
import '../network/dio_client.dart';
import '../providers/session_provider.dart';
import '../../features/master/data/datasources/products_local_ds.dart';
import '../../features/master/data/models/product_model.dart';
import 'master_data_remote_ds.dart';

/// One user-facing "module" the Offline Settings screen shows as a
/// checkbox. Each groups 1+ internal sync tasks that share a natural
/// user-facing label (see the plan's registry-grouping rationale — the
/// binding design doc's own moderate granularity, "Customers, Products,
/// Chart of Accounts, Sales Invoices, etc.", not one checkbox per table).
class MasterDataModule {
  final String key;
  final String label;
  final IconData icon;
  final Future<int> Function(AppDatabase db, UserSession session) sync;

  const MasterDataModule({required this.key, required this.label, required this.icon, required this.sync});
}

final Dio _dio = DioClient.instance;

/// Common-master type keys every registered module currently needs offline
/// — a future module extending this list just needs its own type_key added
/// here, no other change.
const List<String> _commonMasterTypeKeys = [
  'UNIT',
  'DEPARTMENT',
  'CONSUMPTION_AREA',
  'PAYMENT_TERMS',
  'PURCHASE_RETURN_REASON',
];

Future<int> _syncProductsAndPricing(AppDatabase db, UserSession session) async {
  final remote = MasterDataRemoteDs();
  var count = 0;

  final productRows = await remote.getAllProducts(clientId: session.clientId, companyId: session.companyId);
  final products = productRows.map(ProductModel.fromJson).toList();
  await ProductsLocalDs(db).upsertProducts(products);
  count += products.length;

  final productIds = products.map((p) => p.id).whereType<String>().toList();
  final uomRows = await remote.getAllProductUoms(productIds);
  await ProductUomLocalDs(db).upsert(uomRows);
  count += uomRows.length;

  final taxGroupsRes = await _dio.get('/rim_tax_groups', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_deleted': 'eq.false',
    'is_active': 'eq.true',
    'select': 'id,group_code,group_name',
    'order': 'group_name.asc',
  });
  final taxGroups = List<Map<String, dynamic>>.from(taxGroupsRes.data as List);
  await GenericLookupLocalDs(db).upsertLookups(
    cacheKey: 'TAX_GROUPS', rows: taxGroups, idOf: (r) => r['id'] as String,
    labelOf: (r) => r['group_name'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += taxGroups.length;

  final memberRows = await remote.getAllTaxGroupMembers(clientId: session.clientId, companyId: session.companyId);
  await TaxGroupMembersLocalDs(db).upsert(memberRows);
  count += memberRows.length;

  final rateRows = await remote.getAllTaxRates(clientId: session.clientId, companyId: session.companyId);
  await TaxRatesLocalDs(db).upsert(rateRows);
  count += rateRows.length;

  return count;
}

Future<int> _syncCustomersSuppliers(AppDatabase db, UserSession session) async {
  final res = await _dio.get('/rim_accounts', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_deleted': 'eq.false',
    'is_active': 'eq.true',
    'or': '(posting_allowed.eq.true,account_nature.eq.Customer,account_nature.eq.Supplier)',
    'select': 'id,account_code,account_name,account_nature,posting_allowed,credit_limit,credit_days,'
        'is_credit_blocked,phone,email,address_line1,address_line2,'
        'parent:rim_accounts!parent_id(account_name),'
        'rim_currencies!account_currency_id(currency_id)',
    'order': 'account_code.asc',
    'limit': '2000',
  });
  final accounts = List<Map<String, dynamic>>.from(res.data as List);
  for (final a in accounts) {
    final parentRel = a['parent'];
    if (parentRel is List) a['parent'] = parentRel.isNotEmpty ? parentRel.first as Map<String, dynamic>? : null;
    final currRel = a['rim_currencies'];
    if (currRel is List) a['rim_currencies'] = currRel.isNotEmpty ? currRel.first as Map<String, dynamic>? : null;
  }
  await AccountsLocalDs(db).upsertAccounts(accounts, clientId: session.clientId, companyId: session.companyId);
  return accounts.length;
}

Future<int> _syncLocationsAndCurrencies(AppDatabase db, UserSession session) async {
  final lookupDs = GenericLookupLocalDs(db);
  var count = 0;

  final locRes = await _dio.get('/ric_locations', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_active': 'eq.true',
    'is_deleted': 'eq.false',
    'select': 'id,location_name,location_short,is_issue_allowed',
    'order': 'location_name.asc',
  });
  final locations = List<Map<String, dynamic>>.from(locRes.data as List);
  await lookupDs.upsertLookups(
    cacheKey: 'LOCATIONS', rows: locations, idOf: (r) => r['id'] as String,
    labelOf: (r) => r['location_name'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += locations.length;

  final ccyRes = await _dio.get('/rim_currencies', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_active': 'eq.true',
    'select': 'id,currency_id,currency_name',
    'order': 'currency_id.asc',
  });
  final currencies = List<Map<String, dynamic>>.from(ccyRes.data as List);
  await lookupDs.upsertLookups(
    cacheKey: 'CURRENCIES', rows: currencies, idOf: (r) => r['id'] as String,
    labelOf: (r) => r['currency_id'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += currencies.length;

  final coRes = await _dio.get('/ric_companies', queryParameters: {
    'id': 'eq.${session.companyId}', 'select': 'id,base_currency,local_currency', 'limit': '1',
  });
  final coList = List<Map<String, dynamic>>.from(coRes.data as List);
  if (coList.isNotEmpty) {
    await lookupDs.upsertLookups(
      cacheKey: 'COMPANY_CURRENCY_CONFIG', rows: coList, idOf: (r) => r['id'] as String,
      clientId: session.clientId, companyId: session.companyId,
    );
    count += 1;
  }

  return count;
}

Future<int> _syncOperationalReferenceData(AppDatabase db, UserSession session) async {
  final lookupDs = GenericLookupLocalDs(db);
  var count = 0;

  for (final typeKey in _commonMasterTypeKeys) {
    final typeRes = await _dio.get('/rim_common_master_types', queryParameters: {
      'type_key': 'eq.$typeKey', 'select': 'id', 'limit': '1',
    });
    final typeList = typeRes.data as List;
    if (typeList.isEmpty) continue;
    final typeId = (typeList.first as Map<String, dynamic>)['id'] as String;
    final res = await _dio.get('/rim_common_masters', queryParameters: {
      'type_id': 'eq.$typeId',
      'client_id': 'eq.${session.clientId}',
      'company_id': 'eq.${session.companyId}',
      'is_deleted': 'eq.false',
      'is_active': 'eq.true',
      'select': 'id,description',
      'order': 'sort_order.asc,description.asc',
    });
    final rows = List<Map<String, dynamic>>.from(res.data as List);
    await lookupDs.upsertLookups(
      cacheKey: 'COMMON_MASTERS_$typeKey', rows: rows, idOf: (r) => r['id'] as String,
      labelOf: (r) => r['description'] as String? ?? '',
      clientId: session.clientId, companyId: session.companyId,
    );
    count += rows.length;
  }

  // Department -> Consumption Area (rim_department_consumption_areas) —
  // a relational join, not a flat common-master list (consumption_area_id
  // is company-wide UNIQUE, belongs to exactly ONE department per
  // 066_material_consumption.sql), so it fits GenericLookupCache's
  // existing parentId column exactly (same "city -> division -> country
  // chain" mechanism countriesProvider/citiesProvider already use) —
  // cached under id=consumption_area_id, parentId=department_id, read back
  // offline via getLookups(parentId: departmentId).
  final deptAreasRes = await _dio.get('/rim_department_consumption_areas', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_deleted': 'eq.false',
    'select': 'department_id,consumption_area_id,area:rim_common_masters!consumption_area_id(id,description)',
  });
  final deptAreaRows = (deptAreasRes.data as List).map((e) {
    final m = e as Map<String, dynamic>;
    final area = m['area'] as Map<String, dynamic>?;
    return {'department_id': m['department_id'], 'id': area?['id'], 'description': area?['description']};
  }).where((r) => r['id'] != null).toList();
  await lookupDs.upsertLookups(
    cacheKey: 'DEPARTMENT_CONSUMPTION_AREAS', rows: deptAreaRows, idOf: (r) => r['id'] as String,
    labelOf: (r) => r['description'] as String? ?? '',
    parentIdOf: (r) => r['department_id'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += deptAreaRows.length;

  final chargesRes = await _dio.get('/rim_additional_charges', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_deleted': 'eq.false',
    'is_active': 'eq.true',
    'select': '*',
    'order': 'sort_order.asc,charge_name.asc',
  });
  final charges = List<Map<String, dynamic>>.from(chargesRes.data as List);
  await lookupDs.upsertLookups(
    cacheKey: 'ADDITIONAL_CHARGES', rows: charges, idOf: (r) => r['id'] as String,
    labelOf: (r) => r['charge_name'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += charges.length;

  final usersRes = await _dio.get('/rim_users', queryParameters: {
    'client_id': 'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_active': 'eq.true',
    'is_deleted': 'eq.false',
    'select': 'id,full_name',
    'order': 'full_name.asc',
  });
  final users = List<Map<String, dynamic>>.from(usersRes.data as List);
  await lookupDs.upsertLookups(
    cacheKey: 'USERS', rows: users, idOf: (r) => r['id'] as String,
    labelOf: (r) => r['full_name'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += users.length;

  final modesRes = await _dio.get('/rim_payment_modes', queryParameters: {
    'is_active': 'eq.true', 'is_deleted': 'eq.false',
    'select': 'payment_mode_code,payment_mode_name',
    'or': '(is_system.eq.true,and(client_id.eq.${session.clientId},company_id.eq.${session.companyId}))',
    'order': 'payment_mode_name.asc',
  });
  final modes = List<Map<String, dynamic>>.from(modesRes.data as List);
  await lookupDs.upsertLookups(
    cacheKey: 'PAYMENT_MODES', rows: modes, idOf: (r) => r['payment_mode_code'] as String,
    labelOf: (r) => r['payment_mode_name'] as String? ?? '',
    clientId: session.clientId, companyId: session.companyId,
  );
  count += modes.length;

  return count;
}

Future<int> _syncSalesInvoiceSetup(AppDatabase db, UserSession session) async {
  final lookupDs = GenericLookupLocalDs(db);
  var count = 0;

  final setupRes = await _dio.get('/ric_user_quick_invoice_setup', queryParameters: {
    'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
    'user_id': 'eq.${session.userId}', 'is_deleted': 'eq.false', 'is_active': 'eq.true',
    'select': '*,'
        'location:ric_locations!location_id(location_name),'
        'cash_customer:rim_accounts!cash_customer_id(account_code,account_name),'
        'default_sales_person:rim_users!default_sales_person_id(full_name)',
    'limit': '1',
  });
  final setupList = List<Map<String, dynamic>>.from(setupRes.data as List);
  if (setupList.isNotEmpty) {
    await lookupDs.upsertLookups(
      cacheKey: 'QUICK_INVOICE_SETUP', rows: setupList, idOf: (_) => session.userId,
      clientId: session.clientId, companyId: session.companyId,
    );
    count += 1;
  }

  final controlsRes = await _dio.get('/ric_user_sales_controls', queryParameters: {
    'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
    'user_id': 'eq.${session.userId}', 'is_deleted': 'eq.false',
    'select': 'can_override_price,can_give_discount,max_discount_percent,can_view_cost_price',
    'limit': '1',
  });
  final controlsList = List<Map<String, dynamic>>.from(controlsRes.data as List);
  if (controlsList.isNotEmpty) {
    await lookupDs.upsertLookups(
      cacheKey: 'USER_SALES_CONTROLS', rows: controlsList, idOf: (_) => session.userId,
      clientId: session.clientId, companyId: session.companyId,
    );
    count += 1;
  }

  return count;
}

final List<MasterDataModule> masterDataModules = [
  const MasterDataModule(key: 'PRODUCTS_PRICING', label: 'Products & Pricing', icon: Icons.inventory_2_outlined, sync: _syncProductsAndPricing),
  const MasterDataModule(key: 'CUSTOMERS_SUPPLIERS', label: 'Customers & Suppliers', icon: Icons.people_outline, sync: _syncCustomersSuppliers),
  const MasterDataModule(key: 'LOCATIONS_CURRENCIES', label: 'Locations & Currencies', icon: Icons.place_outlined, sync: _syncLocationsAndCurrencies),
  const MasterDataModule(key: 'OPERATIONAL_REFERENCE_DATA', label: 'Operational Reference Data', icon: Icons.tune, sync: _syncOperationalReferenceData),
  const MasterDataModule(key: 'SALES_INVOICE_SETUP', label: 'Sales Invoice Setup', icon: Icons.point_of_sale_outlined, sync: _syncSalesInvoiceSetup),
];

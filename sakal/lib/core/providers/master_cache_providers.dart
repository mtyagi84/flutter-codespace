import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../database/datasources/generic_lookup_local_ds.dart';
import '../database/datasources/accounts_local_ds.dart';
import '../network/dio_client.dart';
import 'session_provider.dart';

// Non-autoDispose: lives for the app lifetime, rebuilds when session changes.
// All providers watch sessionProvider so a company switch triggers an automatic
// re-fetch with the new client_id / company_id.

// Shared offline/online branch for simple reference-data lookups, backed by
// GenericLookupCache. Offline + no prior sync for this cacheKey => empty list
// (not an error) — same "transaction/reference browsing isn't guaranteed
// offline, only what's already been seen or created is" rationale used
// throughout the offline rollout.
Future<List<Map<String, dynamic>>> _cachedFetch({
  required Ref ref,
  required String cacheKey,
  required bool offlineMode,
  required String clientId,
  required String companyId,
  required Future<List<Map<String, dynamic>>> Function() fetchRemote,
}) async {
  if (offlineMode && !kIsWeb) {
    final local = GenericLookupLocalDs(ref.watch(appDatabaseProvider));
    return local.getLookups(cacheKey: cacheKey, clientId: clientId, companyId: companyId);
  }
  final rows = await fetchRemote();
  if (!kIsWeb) {
    final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
    unawaited(local.upsertLookups(
      cacheKey: cacheKey, rows: rows, idOf: (r) => r['id'] as String,
      clientId: clientId, companyId: companyId,
    ));
  }
  return rows;
}

final locationsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  return _cachedFetch(
    ref: ref, cacheKey: 'LOCATIONS', offlineMode: session.offlineMode,
    clientId: session.clientId, companyId: session.companyId,
    fetchRemote: () async {
      final res = await DioClient.instance.get('/ric_locations', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_active':  'eq.true',
        'is_deleted': 'eq.false',
        'select':     'id,location_name,location_short',
        'order':      'location_name.asc',
      });
      return List<Map<String, dynamic>>.from(res.data as List);
    },
  );
});

final baseCurrencyProvider = FutureProvider<String>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return '';
  final res = await DioClient.instance.get('/ric_companies', queryParameters: {
    'id':     'eq.${session.companyId}',
    'select': 'base_currency',
    'limit':  '1',
  });
  final list = List<Map<String, dynamic>>.from(res.data as List);
  return list.isNotEmpty ? (list.first['base_currency'] as String? ?? '') : '';
});

final localCurrencyProvider = FutureProvider<String>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return '';
  final res = await DioClient.instance.get('/ric_companies', queryParameters: {
    'id':     'eq.${session.companyId}',
    'select': 'local_currency',
    'limit':  '1',
  });
  final list = List<Map<String, dynamic>>.from(res.data as List);
  return list.isNotEmpty ? (list.first['local_currency'] as String? ?? '') : '';
});

// The company's real chosen accounting standard (rim_accounting_setup,
// set once via the Accounting Setup screen) — 'INDIAN' or 'OHADA'. Every
// place that inserts a new rim_accounts row must read this instead of
// hardcoding 'OHADA' (real bug found live: Customer Master, Supplier
// Master, Chart of Accounts, and fn_convert_prospect_to_customer all
// hardcoded the literal regardless of what the company actually chose
// at setup). Falls back to 'OHADA' only if no setup row exists yet
// (shouldn't happen once past onboarding), matching this provider's own
// established scalar-lookup shape (baseCurrencyProvider/localCurrencyProvider).
final accountingStdProvider = FutureProvider<String>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return 'OHADA';
  final res = await DioClient.instance.get('/rim_accounting_setup', queryParameters: {
    'client_id':  'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'select':     'accounting_std',
    'limit':      '1',
  });
  final list = List<Map<String, dynamic>>.from(res.data as List);
  return list.isNotEmpty ? (list.first['accounting_std'] as String? ?? 'OHADA') : 'OHADA';
});

final currenciesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  return _cachedFetch(
    ref: ref, cacheKey: 'CURRENCIES', offlineMode: session.offlineMode,
    clientId: session.clientId, companyId: session.companyId,
    fetchRemote: () async {
      final res = await DioClient.instance.get('/rim_currencies', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_active':  'eq.true',
        'select':     'id,currency_id,currency_name,rate_decimal_places',
        'order':      'currency_id.asc',
      });
      return List<Map<String, dynamic>>.from(res.data as List);
    },
  );
});

final paymentModesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  final res = await DioClient.instance.get('/rim_payment_modes', queryParameters: {
    'is_active':  'eq.true',
    'is_deleted': 'eq.false',
    'select':     'payment_mode_code,payment_mode_name',
    'or':         '(is_system.eq.true,and(client_id.eq.${session.clientId},'
                  'company_id.eq.${session.companyId}))',
    'order':      'payment_mode_name.asc',
  });
  return List<Map<String, dynamic>>.from(res.data as List);
});

// Loads accounts available for voucher entry: all posting-allowed accounts
// plus all Customer and Supplier accounts (which may have posting_allowed=false
// if created before the flag was enforced). Shared across screens — this is
// also the offline picker source for Finance Voucher and Purchase Order.
//
// Offline: served from AccountsCache (Drift, mobile/desktop only — no Drift
// on Flutter Web, so web sessions must always be online). Online: fetched
// from PostgREST, then opportunistically cached so the next offline session
// has this data. (Drift is unavailable on web, hence the kIsWeb guard.)
final accountsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];

  if (session.offlineMode && !kIsWeb) {
    final local = AccountsLocalDs(ref.watch(appDatabaseProvider));
    return local.getAccounts(clientId: session.clientId, companyId: session.companyId);
  }

  final res = await DioClient.instance.get('/rim_accounts', queryParameters: {
    'client_id':  'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_deleted': 'eq.false',
    'is_active':  'eq.true',
    'or':         '(posting_allowed.eq.true,'
                  'account_nature.eq.Customer,'
                  'account_nature.eq.Supplier)',
    'select':     'id,account_code,account_name,account_nature,posting_allowed,'
                  'parent:rim_accounts!parent_id(account_name),'
                  'rim_currencies!account_currency_id(currency_id)',
    'order':      'account_code.asc',
    'limit':      '500',
  });
  final accounts = List<Map<String, dynamic>>.from(res.data as List);

  // Defensive normalization: a to-one PostgREST embed (parent/rim_currencies)
  // is expected to come back as an object or null, but returns a LIST if the
  // embed relationship becomes ambiguous (e.g. a second FK added between the
  // same two tables elsewhere in the schema). Sanitize once here, at the
  // source, so every current and future consumer of this shared provider
  // gets a guaranteed Map-or-null — never has to defensively re-check this
  // itself, and never crashes on an unguarded `as Map<String, dynamic>?`.
  for (final a in accounts) {
    final parentRel = a['parent'];
    if (parentRel is List) a['parent'] = parentRel.isNotEmpty ? parentRel.first as Map<String, dynamic>? : null;
    final currRel = a['rim_currencies'];
    if (currRel is List) a['rim_currencies'] = currRel.isNotEmpty ? currRel.first as Map<String, dynamic>? : null;
  }

  if (!kIsWeb) {
    final local = AccountsLocalDs(ref.read(appDatabaseProvider));
    unawaited(local.upsertAccounts(accounts, clientId: session.clientId, companyId: session.companyId));
  }

  return accounts;
});

// Purchase-applicable tax groups (id, group_code, group_name) — shared by
// Chart of Accounts' own default-tax-group picker and Expense Voucher's
// per-line Tax Group picker. Every other module that needs tax groups
// (PO/GRN/Sales Invoice/...) fetches them via its own datasource method
// with this identical query shape — added here as one shared provider
// instead of a third/fourth duplicate now that two new call sites need it
// at once.
final taxGroupsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  return _cachedFetch(
    ref: ref, cacheKey: 'TAX_GROUPS', offlineMode: session.offlineMode,
    clientId: session.clientId, companyId: session.companyId,
    fetchRemote: () async {
      final res = await DioClient.instance.get('/rim_tax_groups', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'is_active':  'eq.true',
        'or':         '(applicable_on.eq.PURCHASE,applicable_on.eq.BOTH)',
        'select':     'id,group_code,group_name',
        'order':      'group_name.asc',
      });
      return List<Map<String, dynamic>>.from(res.data as List);
    },
  );
});

// All company details needed for printing (logo, address, tax fields).
// Fetched on demand (when Print is pressed) and cached for the session.
final companyDetailsProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;
  final res = await DioClient.instance.get('/ric_companies', queryParameters: {
    'id':     'eq.${session.companyId}',
    'select': 'company_name,address,landline_no,email,country,'
              'state_name,city_name,pin_zip_code,website,logo,'
              'tax_1_label,tax_1_value,tax_2_label,tax_2_value,'
              'tax_3_label,tax_3_value,tax_4_label,tax_4_value',
    'limit':  '1',
  });
  final list = List<Map<String, dynamic>>.from(res.data as List);
  return list.isNotEmpty ? list.first : null;
});

// Includes country_code because ChartOfAccounts needs it for division/city lookups.
// Customer and Supplier screens ignore the extra field — it's harmless.
final countriesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  return _cachedFetch(
    ref: ref, cacheKey: 'COUNTRIES', offlineMode: session.offlineMode,
    clientId: session.clientId, companyId: session.companyId,
    fetchRemote: () async {
      final res = await DioClient.instance.get('/rim_countries', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'select':     'id,country_name,country_code',
        'order':      'country_name.asc',
      });
      return List<Map<String, dynamic>>.from(res.data as List);
    },
  );
});

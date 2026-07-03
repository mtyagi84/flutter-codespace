import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;
import '../database/app_database.dart';
import '../database/datasources/generic_lookup_local_ds.dart';
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
        'select':     'id,currency_id,currency_name',
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
    final db = ref.watch(appDatabaseProvider);
    final rows = await (db.select(db.accountsCache)
          ..where((t) => t.clientId.equals(session.clientId))
          ..where((t) => t.companyId.equals(session.companyId))
          ..where((t) => t.isActive.equals(true)))
        .get();
    return rows.map((r) => {
      'id':             r.id,
      'account_code':   r.accountCode,
      'account_name':   r.accountName,
      'account_nature': r.accountNature,
      'parent':         {'account_name': r.parentName},
      'rim_currencies': {'currency_id':  r.accountCurrency},
    }).toList();
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

  if (!kIsWeb) {
    final db  = ref.read(appDatabaseProvider);
    final now = DateTime.now();
    unawaited(() async {
      for (final a in accounts) {
        final parentRel = a['parent'];
        final currRel   = a['rim_currencies'];
        await db.into(db.accountsCache).insertOnConflictUpdate(AccountsCacheCompanion.insert(
          id:              a['id'] as String,
          clientId:        session.clientId,
          companyId:       session.companyId,
          accountCode:     a['account_code']   as String? ?? '',
          accountName:     a['account_name']   as String? ?? '',
          accountNature:   a['account_nature'] as String? ?? '',
          parentName:      Value(parentRel is Map ? (parentRel['account_name'] as String? ?? '') : ''),
          accountCurrency: Value(currRel is Map ? (currRel['currency_id'] as String? ?? '') : ''),
          cachedAt:        Value(now),
        ));
      }
    }());
  }

  return accounts;
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

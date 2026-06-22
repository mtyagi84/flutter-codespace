import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/dio_client.dart';
import 'session_provider.dart';

// Non-autoDispose: lives for the app lifetime, rebuilds when session changes.
// All providers watch sessionProvider so a company switch triggers an automatic
// re-fetch with the new client_id / company_id.

final locationsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  final res = await DioClient.instance.get('/ric_locations', queryParameters: {
    'client_id':  'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_active':  'eq.true',
    'is_deleted': 'eq.false',
    'select':     'id,location_name,location_short',
    'order':      'location_name.asc',
  });
  return List<Map<String, dynamic>>.from(res.data as List);
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
  final res = await DioClient.instance.get('/rim_currencies', queryParameters: {
    'client_id':  'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'is_active':  'eq.true',
    'select':     'id,currency_id,currency_name',
    'order':      'currency_id.asc',
  });
  return List<Map<String, dynamic>>.from(res.data as List);
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

// Loads all posting-allowed accounts with code, name, nature, parent name,
// and ledger currency. Used by every screen with an account picker.
// Shared so the 500-row fetch happens once per session, not per screen.
final accountsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  final res = await DioClient.instance.get('/rim_accounts', queryParameters: {
    'client_id':       'eq.${session.clientId}',
    'company_id':      'eq.${session.companyId}',
    'is_deleted':      'eq.false',
    'is_active':       'eq.true',
    'posting_allowed': 'eq.true',
    'select':          'id,account_code,account_name,account_nature,'
                       'parent:rim_accounts!parent_id(account_name),'
                       'rim_currencies!account_currency_id(currency_id)',
    'order':           'account_code.asc',
    'limit':           '500',
  });
  return List<Map<String, dynamic>>.from(res.data as List);
});

// Includes country_code because ChartOfAccounts needs it for division/city lookups.
// Customer and Supplier screens ignore the extra field — it's harmless.
final countriesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  final res = await DioClient.instance.get('/rim_countries', queryParameters: {
    'client_id':  'eq.${session.clientId}',
    'company_id': 'eq.${session.companyId}',
    'select':     'id,country_name,country_code',
    'order':      'country_name.asc',
  });
  return List<Map<String, dynamic>>.from(res.data as List);
});

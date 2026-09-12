import 'package:dio/dio.dart';
import 'package:sakal/core/config/app_config.dart';

import 'test_tenant_config.dart';

/// Verifies data the UI just saved by reading it straight back over
/// PostgREST, authenticated as the SAME QA tenant user the UI itself logged
/// in as — never a service-role key or direct Postgres connection (locked
/// decision in the approved E2E test automation plan, reconfirmed
/// 2026-09-12). This is architecturally identical to what the real app does
/// when it reads data: fully RLS-scoped, zero elevated access.
///
/// Deliberately a SEPARATE Dio instance from the app's own `DioClient` —
/// this runs from test code, not from within the running app, and gets its
/// own JWT via its own direct `fn_login` call (the "explicit" login
/// described in the plan, as opposed to the "implicit" one `integration_test`
/// triggers by driving the real Login screen).
class BackendVerifier {
  final Dio _dio;
  String? _accessToken;
  String? _clientId;
  String? _companyId;
  String? _userId;

  BackendVerifier()
      : _dio = Dio(BaseOptions(
          baseUrl: AppConfig.restBaseUrl,
          headers: {
            'apikey':       AppConfig.supabaseAnonKey,
            'Content-Type': 'application/json',
            'Accept':       'application/json',
          },
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ));

  String get companyId => _companyId ?? (throw StateError('Call login() first'));
  String get clientId => _clientId ?? (throw StateError('Call login() first'));

  /// Direct fn_login call — same RPC the real Login screen calls, just
  /// invoked straight from test code instead of by driving the UI.
  Future<void> login() async {
    TestTenantConfig.assertConfigured();
    final res = await _dio.post('/rpc/fn_login', data: {
      'p_client_no': TestTenantConfig.clientNo,
      'p_username':  TestTenantConfig.username,
      'p_password':  TestTenantConfig.password,
    });
    final d = res.data as Map<String, dynamic>;
    _accessToken = d['access_token'] as String;
    _clientId    = d['client_id'] as String;
    _companyId   = d['company_id'] as String;
    _userId      = d['user_id'] as String;
    _dio.options.headers['Authorization'] = 'Bearer $_accessToken';
  }

  /// Plain PostgREST GET, e.g. `get('rih_grn_headers', {'grn_no': 'eq.GRN-1'})`.
  /// Always scopes by client_id/company_id automatically — every caller
  /// gets tenant-scoped rows without repeating those two filters everywhere.
  Future<List<Map<String, dynamic>>> get(
    String table,
    Map<String, String> filters, {
    String select = '*',
  }) async {
    if (_accessToken == null) throw StateError('Call login() first');
    final res = await _dio.get('/$table', queryParameters: {
      'select':     select,
      'client_id':  'eq.$_clientId',
      'company_id': 'eq.$_companyId',
      ...filters,
    });
    return (res.data as List).cast<Map<String, dynamic>>();
  }

  /// Convenience for the common "expect exactly one row" case — throws with
  /// a clear message if zero or more than one row comes back, rather than
  /// letting a caller silently index into an empty/ambiguous list.
  Future<Map<String, dynamic>> getOne(
    String table,
    Map<String, String> filters, {
    String select = '*',
  }) async {
    final rows = await get(table, filters, select: select);
    if (rows.isEmpty) {
      throw StateError('Expected exactly one row from $table matching $filters, got none.');
    }
    if (rows.length > 1) {
      throw StateError('Expected exactly one row from $table matching $filters, got ${rows.length}.');
    }
    return rows.first;
  }

  /// Calls a report/aggregate RPC directly (e.g. a Stock Ledger or Trial
  /// Balance backend function) — used by report_diff.dart to fetch actual
  /// report output the same way the app's own report screen does.
  Future<dynamic> rpc(String functionName, Map<String, dynamic> params) async {
    if (_accessToken == null) throw StateError('Call login() first');
    final res = await _dio.post('/rpc/$functionName', data: params);
    return res.data;
  }
}

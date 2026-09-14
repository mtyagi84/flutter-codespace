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
  String get userId => _userId ?? (throw StateError('Call login() first'));

  /// Direct fn_login call — same RPC the real Login screen calls, just
  /// invoked straight from test code instead of by driving the UI.
  Future<void> login() async {
    TestTenantConfig.assertConfigured();
    await loginAs(TestTenantConfig.username, TestTenantConfig.password);
  }

  /// Same fn_login call, but as an arbitrary username/password — for tests
  /// that need to act as a SECOND, non-admin user (e.g. proving a
  /// permission-denial rule actually rejects an RPC for a user who lacks
  /// the right, not just that the admin who has every right can call it).
  /// Still the QA tenant's own client_no (TestTenantConfig.clientNo) —
  /// only the username/password vary.
  Future<void> loginAs(String username, String password) async {
    final res = await _dio.post('/rpc/fn_login', data: {
      'p_client_no': TestTenantConfig.clientNo,
      'p_username':  username,
      'p_password':  password,
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
    try {
      final res = await _dio.get('/$table', queryParameters: {
        'select':     select,
        'client_id':  'eq.$_clientId',
        'company_id': 'eq.$_companyId',
        ...filters,
      });
      return (res.data as List).cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      throw StateError('get($table, $filters) failed: ${e.response?.statusCode} ${e.response?.data}');
    }
  }

  /// Plain PostgREST PATCH (update). `filters` are applied exactly like
  /// `get()`'s (client_id/company_id NOT auto-injected here, unlike get() —
  /// callers pass whatever filter uniquely identifies the row, e.g. `{'id':
  /// 'eq.<uuid>'}`, since a PATCH's own row is already known to belong to
  /// this tenant from a prior read).
  Future<void> patch(
    String table,
    Map<String, String> filters,
    Map<String, dynamic> data,
  ) async {
    if (_accessToken == null) throw StateError('Call login() first');
    try {
      await _dio.patch('/$table', queryParameters: filters, data: data);
    } on DioException catch (e) {
      throw StateError('patch($table, $filters) failed: ${e.response?.statusCode} ${e.response?.data}');
    }
  }

  /// Plain PostgREST GET with NO automatic client_id/company_id filters —
  /// for genuinely global/shared tables that have no such columns at all
  /// (e.g. `rim_common_master_types`, confirmed via a direct query
  /// 2026-09-14: `column rim_common_master_types.client_id does not
  /// exist`). Use `get()` instead for any tenant-scoped table — this
  /// exists specifically for the exception, not as a general-purpose
  /// alternative.
  Future<List<Map<String, dynamic>>> getUnscoped(
    String table,
    Map<String, String> filters, {
    String select = '*',
  }) async {
    if (_accessToken == null) throw StateError('Call login() first');
    final res = await _dio.get('/$table', queryParameters: {'select': select, ...filters});
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
    try {
      final res = await _dio.post('/rpc/$functionName', data: params);
      return res.data;
    } on DioException catch (e) {
      // Dio's own exception message never includes the response body — the
      // PostgREST error (code/message/details) that actually explains WHY,
      // which is the whole point of a RAISE EXCEPTION on the backend. Every
      // test file's own diagnosis session this far had to fall back to a
      // manual curl/Invoke-RestMethod call to see it. Surface it here once,
      // for every future caller.
      throw StateError('rpc($functionName) failed: ${e.response?.statusCode} ${e.response?.data}');
    }
  }

  /// Plain PostgREST POST (insert) for master/setup tables that have no
  /// dedicated `fn_save_*` RPC — e.g. seeding test-fixture master data
  /// (a Department/Consumption Area mapping) that a real onboarding flow
  /// would set up once through the admin UI. `client_id`/`company_id` are
  /// injected automatically, same convention as `get()`. Returns the
  /// inserted row (PostgREST `Prefer: return=representation` — safe here
  /// since this is test-only code, not the app's own save path, which
  /// CLAUDE.md documents avoiding that header for due to an RLS+401
  /// interaction on the app's own JWT-refresh timing, not a concern here).
  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, dynamic> data,
  ) async {
    if (_accessToken == null) throw StateError('Call login() first');
    try {
      final res = await _dio.post(
        '/$table',
        data: {'client_id': _clientId, 'company_id': _companyId, ...data},
        options: Options(headers: {'Prefer': 'return=representation'}),
      );
      return (res.data as List).cast<Map<String, dynamic>>().first;
    } on DioException catch (e) {
      throw StateError('insert($table) failed: ${e.response?.statusCode} ${e.response?.data}');
    }
  }

  /// Raw PostgREST GET against an arbitrary path (a view, or `/rpc/<fn>`)
  /// with a caller-fully-specified query string — no automatic client_id/
  /// company_id injection, no result wrapping. Built for the Reporting
  /// Engine smoke test, which needs to call ~80 different views/functions
  /// generically from data-driven `ric_report_definitions` rows, each with
  /// its own filter shape — `get()`'s fixed tenant-scoping assumption
  /// doesn't fit a call that's sometimes a VIEW (RLS-scoped for free) and
  /// sometimes a FUNCTION (needs explicit p_client_id/p_company_id args).
  Future<List<dynamic>> rawGet(String path, Map<String, dynamic> params) async {
    if (_accessToken == null) throw StateError('Call login() first');
    try {
      final res = await _dio.get(path, queryParameters: params);
      return res.data as List<dynamic>;
    } on DioException catch (e) {
      throw StateError('rawGet($path) failed: ${e.response?.statusCode} ${e.response?.data}');
    }
  }

  /// Plain PostgREST DELETE — for the rare test-fixture cleanup case where
  /// a table's own UNIQUE constraint is NOT partial on is_deleted (so a
  /// soft-delete-then-rename cleanup, the pattern used everywhere else in
  /// this suite, can't free the key for a fresh insert on re-run) and a
  /// hard delete of a throwaway test row is the only practical option.
  /// Never use this against a real transaction/document row.
  Future<void> delete(String table, Map<String, String> filters) async {
    if (_accessToken == null) throw StateError('Call login() first');
    try {
      await _dio.delete('/$table', queryParameters: filters);
    } on DioException catch (e) {
      throw StateError('delete($table, $filters) failed: ${e.response?.statusCode} ${e.response?.data}');
    }
  }
}

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/app_config.dart';
import '../config/app_constants.dart';

class DioClient {
  static const _storage = FlutterSecureStorage();
  static final Dio _instance = _build();

  static Dio get instance => _instance;

  // RPCs that run with NO session yet (anon-role, pre-login/pre-tenant
  // bootstrap calls) — a stale/expired stored JWT must never be injected
  // into any of these, or PostgREST rejects the request with a 401 before
  // the function body (which doesn't even need a JWT) ever runs. Real bug
  // found live 2026-10-16: only '/rpc/fn_login' was ever exempted, so a
  // browser carrying a leftover token from an earlier, unrelated session
  // (e.g. testing a different tenant's login) made BOTH `fn_register_client`
  // and `fn_complete_accounting_setup` fail with a confusing, unrelated-
  // looking 401 on the FIRST attempt — the onError handler then deletes the
  // bad token on that same 401, so a retry (with completely different form
  // data) coincidentally succeeds, making the failure look data-dependent
  // when it never was. `fn_login_by_email` (added migration 226) had the
  // identical gap — a stale token broke email login the same way `fn_login`
  // itself was already correctly protected against.
  static const _bootstrapRpcPaths = {
    '/rpc/fn_login',
    '/rpc/fn_login_by_email',
    '/rpc/fn_register_client',
    '/rpc/fn_complete_accounting_setup',
  };

  // Set once in main() to redirect to login when the JWT expires.
  static void Function()? onSessionExpired;

  static Dio _build() {
    final dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.restBaseUrl,
        headers: {
          'apikey':        AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer ${AppConfig.supabaseAnonKey}',
          'Content-Type':  'application/json',
          'Accept':        'application/json',
        },
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );

    // Inject user JWT on every request after login.
    // Falls back to anon key (set in BaseOptions) when not logged in.
    // Works on web (FlutterSecureStorage uses localStorage) and native.
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Bootstrap RPCs run anon, with no session yet — never inject a
        // stale stored JWT into them. All other requests use the stored
        // token (falls back to anon key from BaseOptions).
        final isBootstrapRpc = _bootstrapRpcPaths.contains(options.path);
        if (!isBootstrapRpc) {
          try {
            final token = await _storage.read(key: AppConstants.keyAccessToken);
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          } catch (_) {
            // FlutterSecureStorage Web Crypto failure — fall back to anon key in BaseOptions
          }
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        // PostgREST error bodies are {code, details, hint, message} —
        // `message` is the short RAISE EXCEPTION code (e.g.
        // 'ACCOUNT_LINK_NOT_CONFIGURED'), `details` is the actual
        // human-readable text from `USING DETAIL` (see CLAUDE.md's
        // "Error messages — never a raw ID" convention: every backend
        // RAISE EXCEPTION already resolves account/product/tax names into
        // USING DETAIL for exactly this reason). Every save/action error
        // handler in this app reads only `data['message']` (confirmed
        // app-wide: 75 occurrences across 43 files) — meaning that
        // carefully human-readable text was built and then silently
        // discarded every time, and the user only ever saw the bare code.
        // Two screens (Purchase Order, GRN) had already independently
        // discovered and locally worked around this with their own
        // _serverError() helper; promoting `details` into `message` here
        // fixes it once for every screen — present and future — with no
        // other file needing to change.
        final data = error.response?.data;
        if (data is Map) {
          final details = data['details'];
          if (details is String && details.isNotEmpty) {
            data['message'] = details;
          }
        }

        if (error.response?.statusCode == 401) {
          // Clear the stored JWT so the next request doesn't retry with it.
          try {
            await _storage.delete(key: AppConstants.keyAccessToken);
          } catch (_) {}
          // Don't signal session-expired for a bootstrap call itself — a
          // 401 there is handled by that screen's own catch block (login,
          // registration, accounting setup), not by forcing a redirect.
          final isBootstrapRpc = _bootstrapRpcPaths.contains(error.requestOptions.path);
          if (!isBootstrapRpc) {
            onSessionExpired?.call();
          }
        }
        handler.next(error);
      },
    ));

    return dio;
  }
}

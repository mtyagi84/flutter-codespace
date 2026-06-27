import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/app_config.dart';
import '../config/app_constants.dart';

class DioClient {
  static const _storage = FlutterSecureStorage();
  static final Dio _instance = _build();

  static Dio get instance => _instance;

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
        // fn_login is fetching a NEW token — never inject a stale stored JWT.
        // All other requests use the stored token (falls back to anon key from BaseOptions).
        final isLoginRpc = options.path == '/rpc/fn_login';
        if (!isLoginRpc) {
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
        if (error.response?.statusCode == 401) {
          // Clear the stored JWT so the next request doesn't retry with it.
          try {
            await _storage.delete(key: AppConstants.keyAccessToken);
          } catch (_) {}
          // Don't signal session-expired for the login call itself — the error
          // is handled by the login screen's own catch block.
          final isLoginRpc = error.requestOptions.path == '/rpc/fn_login';
          if (!isLoginRpc) {
            onSessionExpired?.call();
          }
        }
        handler.next(error);
      },
    ));

    return dio;
  }
}

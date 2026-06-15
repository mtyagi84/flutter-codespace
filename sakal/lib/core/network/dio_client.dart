import 'package:dio/dio.dart';
import '../config/app_config.dart';

class DioClient {
  static final Dio _instance = _build();

  static Dio get instance => _instance;

  static Dio _build() {
    return Dio(
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
  }
}

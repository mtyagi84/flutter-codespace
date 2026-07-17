import 'package:shared_preferences/shared_preferences.dart';

class LocalStorage {
  static late SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Client session
  static String? get clientNo => _prefs.getString('client_no');
  static String? get clientId => _prefs.getString('client_id');

  static Future<void> saveClientSession({
    required String clientNo,
    required String clientId,
  }) async {
    await _prefs.setString('client_no', clientNo);
    await _prefs.setString('client_id', clientId);
  }

  static Future<void> clearSession() async {
    await _prefs.remove('client_no');
    await _prefs.remove('client_id');
  }

  // Offline mode — per-device toggle (see Offline Settings screen). Native
  // only; offline mode is never offered on web (no Drift there).
  static bool get deviceOfflineEnabled => _prefs.getBool('device_offline_enabled') ?? false;

  static Future<void> setDeviceOfflineEnabled(bool value) async {
    await _prefs.setBool('device_offline_enabled', value);
  }
}

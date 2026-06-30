import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/app_constants.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';

class OfflineSessionCache {
  static const _storage   = FlutterSecureStorage();
  static const _kUsername = 'off_username';
  static const _kPassHash = 'off_pass_hash';
  static const _kSession  = 'off_session';
  static const _kMenu     = 'off_menu';
  // Marks that the user is actively logged in — cleared on logout.
  // Prevents page-refresh from restoring a session the user intentionally ended.
  static const _kIsActive = 'session_active';

  /// Called after every successful online login to keep credentials fresh.
  static Future<void> save({
    required String username,
    required String password,
    required UserSession session,
    required List<MenuModule> menu,
  }) async {
    final hash = sha256.convert(utf8.encode(password)).toString();
    await Future.wait([
      _storage.write(key: _kUsername, value: username),
      _storage.write(key: _kPassHash, value: hash),
      _storage.write(key: _kSession,  value: jsonEncode(_encodeSession(session))),
      _storage.write(key: _kMenu,     value: jsonEncode(menu.map((m) => m.toJson()).toList())),
      _storage.write(key: _kIsActive, value: 'true'),
    ]);
  }

  /// Restores session + menu after a browser page refresh, without a password
  /// check. Returns null if the user previously logged out (deactivate() was called)
  /// OR if the stored JWT has already expired.
  static Future<({UserSession session, List<MenuModule> menu})?> tryRestoreSession() async {
    final vals = await Future.wait([
      _storage.read(key: _kIsActive),
      _storage.read(key: _kSession),
      _storage.read(key: _kMenu),
      _storage.read(key: AppConstants.keyAccessToken),
    ]);
    if (vals[0] != 'true' || vals[1] == null || vals[2] == null) return null;

    // If the JWT is already expired, treat as logged-out immediately so the user
    // is sent to the login screen on startup rather than mid-session on first API call.
    final jwt = vals[3];
    if (jwt != null && _isJwtExpired(jwt)) {
      await deactivate();
      return null;
    }

    try {
      final session = _decodeSession(jsonDecode(vals[1]!) as Map<String, dynamic>);
      final menu    = (jsonDecode(vals[2]!) as List)
          .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
          .toList();
      return (session: session, menu: menu);
    } catch (_) {
      return null;
    }
  }

  /// Returns true if the JWT's exp claim is in the past.
  static bool _isJwtExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      var payload = parts[1];
      // Base64Url padding
      switch (payload.length % 4) {
        case 2: payload += '==';
        case 3: payload += '=';
      }
      final decoded = utf8.decode(base64Url.decode(payload));
      final claims  = jsonDecode(decoded) as Map<String, dynamic>;
      final exp     = claims['exp'] as int?;
      if (exp == null) return false; // no expiry = never expires
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000).isBefore(DateTime.now());
    } catch (_) {
      return true; // unparseable token → treat as expired
    }
  }

  /// Clears the active flag on logout. Keeps the password hash so offline
  /// login (on mobile) still works after the user is back online.
  static Future<void> deactivate() async {
    await _storage.delete(key: _kIsActive);
  }

  /// Verifies credentials against cached hash.
  /// Returns UserSession + menu if they match; null if no cache or wrong password.
  static Future<({UserSession session, List<MenuModule> menu})?> tryLogin({
    required String username,
    required String password,
  }) async {
    final vals = await Future.wait([
      _storage.read(key: _kUsername),
      _storage.read(key: _kPassHash),
      _storage.read(key: _kSession),
      _storage.read(key: _kMenu),
    ]);

    if (vals.any((v) => v == null)) return null;
    if (vals[0] != username) return null;

    final hash = sha256.convert(utf8.encode(password)).toString();
    if (vals[1] != hash) return null;

    final session = _decodeSession(
        jsonDecode(vals[2]!) as Map<String, dynamic>);
    final menu = (jsonDecode(vals[3]!) as List)
        .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
        .toList();

    return (session: session, menu: menu);
  }

  static Future<bool> hasCachedCredentials() async =>
      await _storage.read(key: _kUsername) != null;

  static Map<String, dynamic> _encodeSession(UserSession s) => {
    'userId':           s.userId,
    'clientId':         s.clientId,
    'clientNo':         s.clientNo,
    'companyId':        s.companyId,
    'companyName':      s.companyName,
    'locationId':       s.locationId,
    'fullName':         s.fullName,
    'username':         s.username,
    'enableBarcode':    s.enableBarcode,
    'enablePartNumber': s.enablePartNumber,
  };

  static UserSession _decodeSession(Map<String, dynamic> m) => UserSession(
    userId:           m['userId']           as String,
    clientId:         m['clientId']         as String,
    clientNo:         m['clientNo']         as String,
    companyId:        m['companyId']        as String,
    companyName:      m['companyName']      as String,
    locationId:       m['locationId']       as String?,
    fullName:         m['fullName']         as String,
    username:         m['username']         as String,
    offlineMode:      false,
    enableBarcode:    m['enableBarcode']    as bool? ?? false,
    enablePartNumber: m['enablePartNumber'] as bool? ?? false,
  );
}

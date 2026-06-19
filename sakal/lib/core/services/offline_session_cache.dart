import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';

class OfflineSessionCache {
  static const _storage   = FlutterSecureStorage();
  static const _kUsername = 'off_username';
  static const _kPassHash = 'off_pass_hash';
  static const _kSession  = 'off_session';
  static const _kMenu     = 'off_menu';

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
      _storage.write(key: _kMenu,
          value: jsonEncode(menu.map((m) => m.toJson()).toList())),
    ]);
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
    'userId':      s.userId,
    'clientId':    s.clientId,
    'clientNo':    s.clientNo,
    'companyId':   s.companyId,
    'companyName': s.companyName,
    'locationId':  s.locationId,
    'fullName':    s.fullName,
    'username':    s.username,
  };

  static UserSession _decodeSession(Map<String, dynamic> m) => UserSession(
    userId:      m['userId']      as String,
    clientId:    m['clientId']    as String,
    clientNo:    m['clientNo']    as String,
    companyId:   m['companyId']   as String,
    companyName: m['companyName'] as String,
    locationId:  m['locationId']  as String?,
    fullName:    m['fullName']    as String,
    username:    m['username']    as String,
    offlineMode: false,
  );
}

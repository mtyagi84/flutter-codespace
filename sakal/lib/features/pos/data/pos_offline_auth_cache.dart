import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/models/menu_models.dart';
import '../../../core/providers/session_provider.dart';

/// Lets a POS till authenticate a cashier with no connectivity at all —
/// the until-now missing offline half of `fn_pos_pin_login`. Modeled
/// directly on `OfflineSessionCache` (the back-office app's own
/// username/password offline cache): same `flutter_secure_storage`
/// mechanism, same "cache a digest on every successful online login, never
/// the plaintext credential" shape — not a Drift table, since this is
/// small, per-device credential state, not document data to sync.
///
/// Deliberate design choice (user-confirmed 2026-10-03, see
/// docs/pos/06_access_security.md §4): the cached digest is NEVER the
/// server's own bcrypt `rim_users.pin_hash` — `fn_pos_pin_login` has no
/// reason to (and does not) return that hash to the client. Instead it is
/// a SHA-256 digest computed over `'$deviceUid:$userId:$pin'` the moment an
/// online PIN login succeeds. Salting with the device's own stable UID
/// means a digest copied off one till's secure storage is meaningless on
/// another device, and the real server-side bcrypt hash is never exposed
/// to any client. Several cashiers can share one till, so entries are
/// keyed by userId and stored as a small JSON map, not a single slot.
///
/// A device must go through one real online PIN login before it can ever
/// work offline — there is no way to pre-seed this cache remotely, which
/// is the correct, conservative default for a till.
class PosOfflineAuthCache {
  static const _storage = FlutterSecureStorage();
  static String _key(String deviceUid) => 'pos_off_$deviceUid';

  static String _digest(String deviceUid, String userId, String pin) =>
      sha256.convert(utf8.encode('$deviceUid:$userId:$pin')).toString();

  /// Called after every successful ONLINE PIN login.
  static Future<void> save({
    required String deviceUid,
    required String userId,
    required String pin,
    required UserSession session,
    required List<MenuModule> menu,
  }) async {
    final entries = await _readEntries(deviceUid);
    entries[userId] = {
      'digest':  _digest(deviceUid, userId, pin),
      'session': _encodeSession(session),
      'menu':    menu.map((m) => m.toJson()).toList(),
    };
    await _storage.write(key: _key(deviceUid), value: jsonEncode(entries));
  }

  /// Returns the matching cached session + menu, or null if this device has
  /// never cached this user (or any user) with this exact PIN. Never throws
  /// — a corrupt/missing cache is treated the same as "no offline fallback
  /// available", letting the caller fall back to its own error handling.
  static Future<({UserSession session, List<MenuModule> menu})?> tryLogin({
    required String deviceUid,
    required String pin,
  }) async {
    try {
      final entries = await _readEntries(deviceUid);
      for (final entry in entries.values) {
        final e = entry as Map<String, dynamic>;
        final userId = (e['session'] as Map<String, dynamic>)['userId'] as String;
        if (e['digest'] == _digest(deviceUid, userId, pin)) {
          final session = _decodeSession(e['session'] as Map<String, dynamic>);
          final menu = (e['menu'] as List).map((m) => MenuModule.fromJson(m as Map<String, dynamic>)).toList();
          return (session: session, menu: menu);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _readEntries(String deviceUid) async {
    final raw = await _storage.read(key: _key(deviceUid));
    if (raw == null) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Map<String, dynamic> _encodeSession(UserSession s) => {
        'userId':          s.userId,
        'clientId':        s.clientId,
        'clientNo':        s.clientNo,
        'companyId':       s.companyId,
        'companyName':     s.companyName,
        'locationId':      s.locationId,
        'fullName':        s.fullName,
        'username':        s.username,
        'posTerminalId':   s.posTerminalId,
        'posTerminalName': s.posTerminalName,
        'posDeviceId':     s.posDeviceId,
      };

  static UserSession _decodeSession(Map<String, dynamic> m) => UserSession(
        userId:          m['userId'] as String,
        clientId:        m['clientId'] as String,
        clientNo:        m['clientNo'] as String? ?? '',
        companyId:       m['companyId'] as String,
        companyName:     m['companyName'] as String? ?? '',
        locationId:      m['locationId'] as String?,
        fullName:        m['fullName'] as String,
        username:        m['username'] as String,
        offlineMode:     true,
        posTerminalId:   m['posTerminalId'] as String?,
        posTerminalName: m['posTerminalName'] as String?,
        posDeviceId:     m['posDeviceId'] as String?,
      );
}

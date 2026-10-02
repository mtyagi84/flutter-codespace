import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Everything this physical device remembers about itself, independent of
/// any user session — the one thing a till needs to boot straight to PIN
/// entry instead of asking "what company/terminal is this?" every time.
///
/// See docs/pos/06_access_security.md §4: device identity (`deviceUid`) is
/// generated once and is permanent; the "which terminal is this bound to"
/// context is cached here purely as a UX shortcut after the FIRST successful
/// PIN login — [fn_pos_pin_login] itself is still what's authoritative every
/// time (it re-resolves the binding from `ric_pos_devices` server-side), so
/// a stale/cleared cache here never grants access on its own, it only saves
/// the device from showing the setup screen again.
class PosDeviceStorage {
  PosDeviceStorage._();
  static const _storage = FlutterSecureStorage();

  static const _kDeviceUid = 'pos_device_uid';
  static const _kTerminalId = 'pos_cached_terminal_id';
  static const _kTerminalName = 'pos_cached_terminal_name';
  static const _kCompanyName = 'pos_cached_company_name';
  static const _kPinLength = 'pos_cached_pin_length';

  /// This device's own stable identifier. Generated once, on first launch of
  /// the POS surface, and never changes afterwards — this IS the identity
  /// `ric_pos_devices.device_uid` is keyed on, so regenerating it would make
  /// the server treat it as a brand-new, unbound device.
  static Future<String> deviceUid() async {
    final existing = await _storage.read(key: _kDeviceUid);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await _storage.write(key: _kDeviceUid, value: generated);
    return generated;
  }

  /// Cached only for display on the PIN screen ("Till 1 — Front Counter") so
  /// it doesn't look blank before the first network round trip completes —
  /// never used for any access decision.
  static Future<void> cacheTerminalContext({
    required String terminalId,
    required String terminalName,
    required String companyName,
  }) async {
    await _storage.write(key: _kTerminalId, value: terminalId);
    await _storage.write(key: _kTerminalName, value: terminalName);
    await _storage.write(key: _kCompanyName, value: companyName);
  }

  static Future<String?> cachedTerminalId() => _storage.read(key: _kTerminalId);
  static Future<String?> cachedTerminalName() => _storage.read(key: _kTerminalName);
  static Future<String?> cachedCompanyName() => _storage.read(key: _kCompanyName);

  /// The company's `ric_companies.pos_pin_length` policy, cached at setup
  /// time so the PIN pad shows the right number of dots from the very first
  /// login — never hardcoded to 4. `fn_pos_pin_login` itself is still the
  /// real authority on whether a PIN is correct regardless of this value;
  /// this only controls how many dots the pad displays before submitting.
  static Future<void> cachePinLength(int length) =>
      _storage.write(key: _kPinLength, value: length.toString());

  static Future<int> cachedPinLength({int fallback = 4}) async {
    final raw = await _storage.read(key: _kPinLength);
    return int.tryParse(raw ?? '') ?? fallback;
  }

  /// Used only by the "this isn't my till" escape hatch on the PIN screen —
  /// forgets the cached display context so the setup screen shows again.
  /// Does NOT unbind the device server-side (an admin does that from
  /// POS Setup) and does NOT generate a new device_uid.
  static Future<void> forgetCachedTerminal() async {
    await _storage.delete(key: _kTerminalId);
    await _storage.delete(key: _kTerminalName);
    await _storage.delete(key: _kCompanyName);
  }
}

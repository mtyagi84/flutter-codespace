import '../../../core/network/dio_client.dart';

/// Thin wrapper over the two pre-auth RPCs a POS till calls before any JWT
/// exists — `fn_pos_register_device`/`fn_pos_pin_login`
/// (backend/migrations/205_pos_foundation.sql). Deliberately NOT a full
/// repository/interface pair like every other module's data layer — this is
/// two stateless calls with no offline/caching concerns of their own (the
/// device identity itself lives in PosDeviceStorage, not here), so the extra
/// abstraction layers would be ceremony, not value.
class PosAuthRemoteDs {
  /// Registers (or re-touches) this device's row server-side. Safe to call
  /// on every app start — `fn_pos_register_device` is a plain upsert keyed
  /// on device_uid. Does NOT bind the device to a terminal; that's a
  /// separate, explicit admin action from the POS Setup screen.
  Future<void> registerDevice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String deviceUid,
    required String deviceName,
    required String platform,
  }) async {
    await DioClient.instance.post('/rpc/fn_pos_register_device', data: {
      'p_client_id': clientId,
      'p_company_id': companyId,
      'p_location_id': locationId,
      'p_device_uid': deviceUid,
      'p_device_name': deviceName,
      'p_platform': platform,
    });
  }

  /// Returns the raw JSON body `fn_pos_pin_login` returns on success
  /// (same shape as `fn_login`'s own response, plus `pos_terminal_id`/
  /// `pos_terminal_name`/`pos_device_id`). Throws DioException on any
  /// failure (DEVICE_NOT_REGISTERED/DEVICE_NOT_BOUND/DEVICE_BLOCKED/
  /// PIN_LOCKED/INVALID_PIN) — the caller maps these to a cashier-facing
  /// message, same convention as every other RPC call in this app.
  Future<Map<String, dynamic>> pinLogin({
    required String deviceUid,
    required String pin,
  }) async {
    final res = await DioClient.instance.post('/rpc/fn_pos_pin_login', data: {
      'p_device_uid': deviceUid,
      'p_pin': pin,
    });
    return res.data as Map<String, dynamic>;
  }
}

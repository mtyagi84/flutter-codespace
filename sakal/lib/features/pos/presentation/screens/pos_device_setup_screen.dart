import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../data/pos_auth_remote_ds.dart';
import '../../data/pos_device_storage.dart';
import '../widgets/pos_keyboard.dart';

/// Shown the FIRST time the POS surface runs on a device with no cached
/// terminal binding — never on a device that's already been set up (that
/// device goes straight to PosPinLoginScreen). This is the one place a real
/// username/password is ever typed on a till, and only because binding a
/// brand-new device to a terminal is an admin action, not a cashier one —
/// see docs/pos/06_access_security.md §4.
///
/// Deliberately a single self-contained flow (not the shared LoginScreen
/// widget) — reusing that screen's own GoRouter-redirect wiring here would
/// risk sending this admin into the regular back-office shell instead of
/// back to the POS setup step once they're authenticated.
class PosDeviceSetupScreen extends StatefulWidget {
  const PosDeviceSetupScreen({super.key});

  @override
  State<PosDeviceSetupScreen> createState() => _PosDeviceSetupScreenState();
}

enum _Step { intro, adminLogin, pickTerminal }

class _PosDeviceSetupScreenState extends State<PosDeviceSetupScreen> {
  final _ds = PosAuthRemoteDs();
  _Step _step = _Step.intro;
  String? _deviceUid;
  bool _busy = false;
  String? _error;

  // Admin login fields
  bool _loginByEmail = true;
  String _email = '';
  String _clientNo = '';
  String _username = '';
  String _password = '';

  // Post-login context
  String? _clientId;
  String? _companyId;
  String? _companyName;
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _terminals = [];
  String? _selectedLocationId;
  String? _selectedTerminalId;
  String _newTerminalCode = '';
  String _newTerminalName = '';
  bool _creatingNew = false;

  @override
  void dispose() {
    // Defensive cleanup for the admin token stashed in _adminLogin, in
    // case this screen is abandoned (back navigation, browser close)
    // before _finishSetup's own cleanup ever runs — this screen must
    // never leave a lingering admin session behind on the till either way.
    const FlutterSecureStorage().delete(key: AppConstants.keyAccessToken);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    PosDeviceStorage.deviceUid().then((uid) => mounted ? setState(() => _deviceUid = uid) : null);
    // Real gap found live 2026-10-16: this screen always asked for a bare
    // Client No. with no memory of a prior back-office login on the SAME
    // browser/device, even though LocalStorage.clientNo already caches it
    // after any such login — and it never offered the email+password path
    // the main app's own LoginScreen has had since the registration/login
    // overhaul. Pre-fill + default to Client ID mode when a cached value
    // exists (saves retyping); default to email mode otherwise, matching
    // LoginScreen's own default for a genuinely fresh device/browser.
    final cachedClientNo = LocalStorage.clientNo;
    if (cachedClientNo != null && cachedClientNo.isNotEmpty) {
      _clientNo = cachedClientNo;
      _loginByEmail = false;
    }
  }

  Future<void> _adminLogin() async {
    setState(() { _busy = true; _error = null; });
    try {
      final Response res;
      if (_loginByEmail) {
        res = await DioClient.instance.post('/rpc/fn_login_by_email', data: {
          'p_email': _email.trim(),
          'p_password': _password,
        });
      } else {
        res = await DioClient.instance.post('/rpc/fn_login', data: {
          'p_client_no': _clientNo.trim().toUpperCase(),
          'p_username': _username.trim(),
          'p_password': _password,
        });
      }
      final d = res.data as Map<String, dynamic>;
      // Admin tokens here are used only to fetch/create the terminal list
      // for setup — this screen never sets sessionProvider or routes into
      // the back-office shell with this login.
      _clientId = d['client_id'] as String;
      _companyId = d['company_id'] as String;
      _companyName = d['company_name'] as String? ?? '';

      // Real bug found live 2026-10-11 (via a genuinely fresh browser
      // profile with no prior session — e.g. first-ever setup of a real
      // new till): DioClient's own interceptor only ever attaches a JWT it
      // finds in secure storage, and fn_login's response token was never
      // written there — every request after this one (starting with the
      // very next line) silently fell back to the anon key and got 401
      // Unauthorized from RLS. This never surfaced in prior manual testing
      // only because that same browser already had a stale admin JWT
      // cached from an earlier, unrelated back-office login, which
      // happened to satisfy these calls by coincidence. Stored here (and
      // explicitly cleared again once setup finishes, in _finishSetup) so
      // this screen's own requests actually authenticate, without turning
      // this one-time admin login into a lingering session on the till.
      final token = d['access_token'] as String?;
      if (token != null) {
        await const FlutterSecureStorage().write(key: AppConstants.keyAccessToken, value: token);
      }

      final locRes = await DioClient.instance.get('/ric_locations', queryParameters: {
        'client_id': 'eq.$_clientId',
        'company_id': 'eq.$_companyId',
        'is_active': 'eq.true',
        'select': 'id,location_name',
      });
      _locations = (locRes.data as List).cast<Map<String, dynamic>>();

      if (!mounted) return;
      setState(() => _step = _Step.pickTerminal);
    } catch (e, st) {
      AppLogger.error('PosDeviceSetupAdminLogin', e, st);
      if (mounted) setState(() => _error = _friendlyError(ErrorPresenter.format(e, action: 'sign in')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// fn_login is a shared, pre-auth, generic function with no USING DETAIL
  /// on any of its exceptions (see login_screen.dart's own identical
  /// method) — friendliness for its bare codes is handled client-side here,
  /// not by adding DETAIL text to fn_login itself.
  String _friendlyError(String raw) {
    if (raw.contains('INVALID_CREDENTIALS')) return 'Invalid username or password.';
    if (raw.contains('ACCOUNT_INACTIVE')) return 'This account has been deactivated. Contact your administrator.';
    if (raw.contains('ACCOUNT_LOCKED')) return 'Account locked after too many failed attempts. Try again in 30 minutes.';
    if (raw.contains('TRIAL_EXPIRED')) return 'Your trial has expired. Please contact the SAKAL team.';
    if (raw.contains('LICENSE_EXPIRED')) return 'Your license has expired. Please contact the SAKAL team.';
    return 'Sign in failed. Please try again.';
  }

  Future<void> _onLocationChanged(String? locationId) async {
    setState(() { _selectedLocationId = locationId; _selectedTerminalId = null; _terminals = []; });
    if (locationId == null) return;
    final res = await DioClient.instance.get('/ric_pos_terminals', queryParameters: {
      'client_id': 'eq.$_clientId',
      'company_id': 'eq.$_companyId',
      'location_id': 'eq.$locationId',
      'is_active': 'eq.true',
      'select': 'id,terminal_code,terminal_name',
    });
    if (mounted) setState(() => _terminals = (res.data as List).cast<Map<String, dynamic>>());
  }

  Future<void> _finishSetup() async {
    setState(() { _busy = true; _error = null; });
    try {
      String terminalId;
      String terminalName;

      if (_creatingNew) {
        // Real bug found live 2026-10-15 (client SK-32130), partially fixed
        // then, fully root-caused 2026-10-16 (client SK-87749): the original
        // fix only checked the in-memory `_terminals` list (stale once this
        // SAME attempt's own terminal creation succeeds but a LATER step —
        // registerDevice/fn_bind_pos_device/the device-id lookup — fails,
        // e.g. on a slow connection). A retry then re-ran this exact INSERT
        // with the same code and hit the real `uq_pos_terminal_code`
        // constraint for real — "the till was already there in POS Settings"
        // was the giveaway: creation had actually succeeded the first time.
        // Fix: re-query LIVE (not the stale list) for a terminal with this
        // exact code at this location right before creating, and REUSE it
        // if found instead of ever re-inserting — makes a retry after any
        // partial failure self-healing by construction, no stale-cache
        // class of bug possible, and still blocks a genuinely different
        // user picking an already-taken code (same friendly message, now
        // just backed by a live check instead of a stale one).
        final code = _newTerminalCode.trim();
        final existingRes = await DioClient.instance.get('/ric_pos_terminals', queryParameters: {
          'client_id': 'eq.$_clientId',
          'company_id': 'eq.$_companyId',
          'location_id': 'eq.$_selectedLocationId',
          'terminal_code': 'eq.$code',
          'select': 'id,terminal_name',
        });
        final existingRows = (existingRes.data as List).cast<Map<String, dynamic>>();
        if (existingRows.isNotEmpty) {
          final existing = existingRows.first;
          final existingId = existing['id'] as String;
          // A genuine conflict is another DEVICE already bound to this
          // terminal — never this own retry's own just-created, still-
          // unbound row. Query bindings rather than is_active, since a
          // freshly-created terminal from a prior partial attempt on THIS
          // session is active by default but correctly has no device bound
          // to it yet.
          final boundRes = await DioClient.instance.get('/ric_pos_devices', queryParameters: {
            'client_id': 'eq.$_clientId',
            'company_id': 'eq.$_companyId',
            'bound_terminal_id': 'eq.$existingId',
            'select': 'id',
          });
          final alreadyBoundElsewhere = (boundRes.data as List).isNotEmpty;
          if (alreadyBoundElsewhere) {
            setState(() => _error = 'Till code "$code" already exists and is in use at this location — pick "Existing Till" instead, or choose a different code.');
            return;
          }
          // Unbound — either a brand-new code nobody's claimed yet, or this
          // same session's own prior partial attempt. Reuse it either way.
          terminalId = existingId;
          terminalName = _newTerminalName.trim();
        } else {
          final createRes = await DioClient.instance.post('/ric_pos_terminals', data: {
            'id': const Uuid().v4(),
            'client_id': _clientId,
            'company_id': _companyId,
            'location_id': _selectedLocationId,
            'terminal_code': code,
            'terminal_name': _newTerminalName.trim(),
          });
          final row = (createRes.data as List).first as Map<String, dynamic>;
          terminalId = row['id'] as String;
          terminalName = _newTerminalName.trim();
        }
      } else {
        terminalId = _selectedTerminalId!;
        terminalName = _terminals.firstWhere((t) => t['id'] == terminalId)['terminal_name'] as String;
      }

      await _ds.registerDevice(
        clientId: _clientId!,
        companyId: _companyId!,
        locationId: _selectedLocationId!,
        deviceUid: _deviceUid!,
        deviceName: 'POS Till',
        platform: defaultTargetPlatformName(),
      );

      final devRes = await DioClient.instance.get('/ric_pos_devices', queryParameters: {
        'client_id': 'eq.$_clientId', 'company_id': 'eq.$_companyId', 'device_uid': 'eq.$_deviceUid', 'select': 'id',
      });
      final deviceId = ((devRes.data as List).first as Map<String, dynamic>)['id'] as String;

      await DioClient.instance.post('/rpc/fn_bind_pos_device', data: {
        'p_device_id': deviceId,
        'p_terminal_id': terminalId,
      });

      await PosDeviceStorage.cacheTerminalContext(
        terminalId: terminalId,
        terminalName: terminalName,
        companyName: _companyName ?? '',
      );

      // Clear the temporary admin token stashed in _adminLogin — setup is
      // done, and this till must boot straight to PIN entry from here on,
      // never carry a lingering admin session.
      await const FlutterSecureStorage().delete(key: AppConstants.keyAccessToken);

      if (!mounted) return;
      context.go(RouteNames.posLogin);
    } catch (e, st) {
      AppLogger.error('PosDeviceSetupFinish', e, st);
      if (mounted) setState(() => _error = ErrorPresenter.format(e, action: 'set up this till'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Till Setup'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        // Real gap found live 2026-10-16: nothing on this screen ever gave
        // a way out of the flow at all — this device has no session/shell
        // chrome of its own yet, so there's no sidebar/back-arrow target
        // other than the regular app's own entry point. Always available,
        // on every step, independent of the in-flow "Back to Sign-In"/
        // "Cancel" buttons (those retry within the flow; this exits it).
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Exit setup',
          onPressed: () async {
            await const FlutterSecureStorage().delete(key: AppConstants.keyAccessToken);
            if (context.mounted) context.go(RouteNames.landing);
          },
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: switch (_step) {
              _Step.intro => _buildIntro(),
              _Step.adminLogin => _buildAdminLogin(),
              _Step.pickTerminal => _buildPickTerminal(),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildIntro() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('This device isn\'t set up yet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 8),
          const Text(
            'An administrator needs to assign this device to a till, once. '
            'After that, every cashier signs in here with just their PIN — '
            'no password is ever needed at this screen again.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13.5, height: 1.5),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.devices_outlined, size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text(_deviceUid ?? 'Generating…', style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'))),
            ]),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: () => setState(() => _step = _Step.adminLogin), child: const Text('Sign in as Administrator')),
        ]),
      ),
    );
  }

  Widget _buildAdminLogin() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Administrator Sign-In', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          const Text('One-time only, to assign this till.', style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
          const SizedBox(height: 16),
          if (_loginByEmail) ...[
            PosKeyboardField(label: 'Email', value: _email, onChanged: (v) => setState(() => _email = v)),
          ] else ...[
            PosKeyboardField(label: 'Client No.', value: _clientNo, onChanged: (v) => setState(() => _clientNo = v)),
            const SizedBox(height: 10),
            PosKeyboardField(label: 'Username', value: _username, onChanged: (v) => setState(() => _username = v)),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _loginByEmail = !_loginByEmail),
              child: Text(_loginByEmail ? 'Sign in with Client ID instead' : 'Sign in with Email instead'),
            ),
          ),
          const SizedBox(height: 4),
          PosKeyboardField(label: 'Password', value: _password, obscureText: true, onChanged: (v) => setState(() => _password = v)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12.5))),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _adminLogin, child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Continue')),
          const SizedBox(height: 8),
          TextButton(onPressed: () => setState(() { _step = _Step.intro; _error = null; }), child: const Text('Cancel')),
        ]),
      ),
    );
  }

  Widget _buildPickTerminal() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Assign This Device', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _selectedLocationId,
            decoration: const InputDecoration(labelText: 'Store / Location', border: OutlineInputBorder()),
            items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String))).toList(),
            onChanged: _onLocationChanged,
          ),
          const SizedBox(height: 14),
          if (_selectedLocationId != null) ...[
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Existing Till')), ButtonSegment(value: true, label: Text('New Till'))],
              selected: {_creatingNew},
              onSelectionChanged: (s) => setState(() => _creatingNew = s.first),
            ),
            const SizedBox(height: 14),
            if (!_creatingNew)
              DropdownButtonFormField<String>(
                initialValue: _selectedTerminalId,
                decoration: const InputDecoration(labelText: 'Till', border: OutlineInputBorder()),
                items: _terminals.map((t) => DropdownMenuItem(value: t['id'] as String, child: Text('${t['terminal_code']} — ${t['terminal_name']}'))).toList(),
                onChanged: (v) => setState(() => _selectedTerminalId = v),
              )
            else ...[
              PosKeyboardField(label: 'Till Code (e.g. T1)', value: _newTerminalCode, onChanged: (v) => setState(() => _newTerminalCode = v)),
              const SizedBox(height: 10),
              PosKeyboardField(label: 'Till Name (e.g. Front Counter)', value: _newTerminalName, onChanged: (v) => setState(() => _newTerminalName = v)),
            ],
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12.5))),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: (_busy || !_canFinish()) ? null : _finishSetup,
            child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Assign & Finish Setup'),
          ),
          const SizedBox(height: 8),
          // Real gap found live 2026-10-16: a failure on this step left the
          // user stuck with no way out of the flow at all — this screen has
          // no other navigation chrome (no AppBar back arrow destination,
          // no sidebar, since a brand-new till has no session yet).
          TextButton(
            onPressed: _busy ? null : () {
              setState(() { _step = _Step.adminLogin; _error = null; });
            },
            child: const Text('Back to Sign-In'),
          ),
        ]),
      ),
    );
  }

  bool _canFinish() {
    if (_selectedLocationId == null) return false;
    if (_creatingNew) return _newTerminalCode.trim().isNotEmpty && _newTerminalName.trim().isNotEmpty;
    return _selectedTerminalId != null;
  }
}

/// Maps onto ric_pos_devices.platform's own CHECK constraint
/// ('WEB','ANDROID','WINDOWS','IOS') — shown back on the admin Devices list
/// for reference only, never used for any access decision.
String defaultTargetPlatformName() {
  if (kIsWeb) return 'WEB';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android: return 'ANDROID';
    case TargetPlatform.windows: return 'WINDOWS';
    case TargetPlatform.iOS: return 'IOS';
    default: return 'WINDOWS';
  }
}

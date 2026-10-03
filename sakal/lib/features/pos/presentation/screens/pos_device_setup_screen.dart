import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
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
  void initState() {
    super.initState();
    PosDeviceStorage.deviceUid().then((uid) => mounted ? setState(() => _deviceUid = uid) : null);
  }

  Future<void> _adminLogin() async {
    setState(() { _busy = true; _error = null; });
    try {
      final res = await DioClient.instance.post('/rpc/fn_login', data: {
        'p_client_no': _clientNo.trim().toUpperCase(),
        'p_username': _username.trim(),
        'p_password': _password,
      });
      final d = res.data as Map<String, dynamic>;
      // Admin tokens here are used only to fetch/create the terminal list
      // for setup — this screen never sets sessionProvider or routes into
      // the back-office shell with this login.
      _clientId = d['client_id'] as String;
      _companyId = d['company_id'] as String;
      _companyName = d['company_name'] as String? ?? '';

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
        final createRes = await DioClient.instance.post('/ric_pos_terminals', data: {
          'id': const Uuid().v4(),
          'client_id': _clientId,
          'company_id': _companyId,
          'location_id': _selectedLocationId,
          'terminal_code': _newTerminalCode.trim(),
          'terminal_name': _newTerminalName.trim(),
        });
        final row = (createRes.data as List).first as Map<String, dynamic>;
        terminalId = row['id'] as String;
        terminalName = _newTerminalName.trim();
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
      appBar: AppBar(title: const Text('Till Setup'), backgroundColor: AppColors.primary, foregroundColor: Colors.white),
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
          PosKeyboardField(label: 'Client No.', value: _clientNo, onChanged: (v) => setState(() => _clientNo = v)),
          const SizedBox(height: 10),
          PosKeyboardField(label: 'Username', value: _username, onChanged: (v) => setState(() => _username = v)),
          const SizedBox(height: 10),
          PosKeyboardField(label: 'Password', value: _password, obscureText: true, onChanged: (v) => setState(() => _password = v)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12.5))),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _adminLogin, child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Continue')),
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

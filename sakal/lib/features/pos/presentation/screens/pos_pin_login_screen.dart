import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../data/pos_auth_remote_ds.dart';
import '../../data/pos_device_storage.dart';
import '../widgets/pos_pin_pad.dart';

/// The till's everyday sign-in — PIN only, no username/password field
/// anywhere on this screen. See docs/pos/06_access_security.md §4 for the
/// full design: a device must already be bound to a terminal (see
/// PosDeviceSetupScreen) before this screen can do anything useful, and the
/// candidate set fn_pos_pin_login matches against is always scoped to this
/// one terminal server-side — nothing about that is decided here.
///
/// screenName intentionally does NOT use ScreenPermissionMixin — this screen
/// runs BEFORE any session/JWT exists, so there is no permission to check
/// yet (identical reasoning to the regular LoginScreen).
class PosPinLoginScreen extends ConsumerStatefulWidget {
  const PosPinLoginScreen({super.key});

  @override
  ConsumerState<PosPinLoginScreen> createState() => _PosPinLoginScreenState();
}

class _PosPinLoginScreenState extends ConsumerState<PosPinLoginScreen> {
  final _ds = PosAuthRemoteDs();
  final _pinPadKey = GlobalKey<PosPinPadState>();

  bool _loading = true;
  bool _submitting = false;
  String? _error;
  String? _terminalName;
  String? _companyName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final terminalId = await PosDeviceStorage.cachedTerminalId();
    if (terminalId == null) {
      if (mounted) context.go(RouteNames.posDeviceSetup);
      return;
    }
    _terminalName = await PosDeviceStorage.cachedTerminalName();
    _companyName = await PosDeviceStorage.cachedCompanyName();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _onPinSubmitted(String pin) async {
    if (_submitting) return;
    setState(() { _submitting = true; _error = null; });

    try {
      final deviceUid = await PosDeviceStorage.deviceUid();
      final d = await _ds.pinLogin(deviceUid: deviceUid, pin: pin);

      final token = d['access_token'] as String?;
      if (token != null) {
        try {
          await const FlutterSecureStorage().write(key: AppConstants.keyAccessToken, value: token);
        } catch (_) {
          // Same tolerated Web Crypto failure the regular LoginScreen already accepts.
        }
      }

      // Re-cache the display context with whatever the server just
      // confirmed — keeps it correct even if an admin renamed the terminal
      // or moved the device since the last login.
      await PosDeviceStorage.cacheTerminalContext(
        terminalId: d['pos_terminal_id'] as String,
        terminalName: d['pos_terminal_name'] as String? ?? '',
        companyName: d['company_name'] as String? ?? '',
      );

      final menuRes = await DioClient.instance.post('/rpc/fn_get_user_menu', data: {
        'p_user_id': d['user_id'],
        'p_client_id': d['client_id'],
        'p_company_id': d['company_id'],
      });
      final menuList = (menuRes.data as List<dynamic>)
          .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
          .toList();

      if (!mounted) return;

      final session = UserSession(
        userId: d['user_id'] as String,
        clientId: d['client_id'] as String,
        clientNo: '', // not returned by fn_pos_pin_login — the till never types/shows a Client No. at all
        companyId: d['company_id'] as String,
        companyName: d['company_name'] as String? ?? '',
        locationId: d['location_id'] as String?,
        fullName: d['full_name'] as String,
        username: d['username'] as String,
        posTerminalId: d['pos_terminal_id'] as String?,
        posTerminalName: d['pos_terminal_name'] as String?,
        posDeviceId: d['pos_device_id'] as String?,
      );

      ref.read(sessionProvider.notifier).state = session;
      ref.read(menuProvider.notifier).state = menuList;

      if (!mounted) return;
      context.go(RouteNames.posSale);
    } catch (e, st) {
      AppLogger.error('PosPinLogin', e, st);
      _pinPadKey.currentState?.clear();
      if (mounted) {
        setState(() => _error = _friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _friendlyError(Object e) {
    final raw = ErrorPresenter.format(e, action: 'sign in');
    if (raw.contains('DEVICE_NOT_REGISTERED')) return 'This device isn\'t registered. Ask a manager to set it up.';
    if (raw.contains('DEVICE_BLOCKED')) return 'This till has been blocked. Contact your administrator.';
    if (raw.contains('DEVICE_NOT_BOUND')) return 'This device isn\'t assigned to a till yet. Ask a manager to set it up.';
    if (raw.contains('PIN_LOCKED')) return 'Too many incorrect PINs. Try again in a few minutes, or ask a manager to unlock this till.';
    if (raw.contains('INVALID_PIN')) return 'Incorrect PIN. Try again.';
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.primaryDark],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: _loading ? const _LoadingCard() : _buildCard(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: AppColors.secondary, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: const Text('S', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.primaryDark, fontSize: 16)),
            ),
            const SizedBox(width: 10),
            const Text('SAKAL POS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_companyName ?? ''} · ${_terminalName ?? ''}',
          style: const TextStyle(color: Color(0xFFB9C6E6), fontSize: 12.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 22),
        Card(
          elevation: 12,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
            child: Column(
              children: [
                const Text('Enter your PIN', style: TextStyle(fontFamily: null, fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 16),
                PosPinPad(key: _pinPadKey, enabled: !_submitting, onSubmitted: _onPinSubmitted),
                if (_submitting) ...[
                  const SizedBox(height: 14),
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12.5), textAlign: TextAlign.center),
                ],
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _submitting ? null : _showForgotPinSheet,
                  child: const Text('Forgot your PIN? Ask a manager to reset it', style: TextStyle(fontSize: 12.5)),
                ),
                const Divider(height: 24),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Device', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    Text(kIsWeb ? 'This browser' : 'This device', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 10),
                const Text('🔒 No password is ever used at this till', style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showForgotPinSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Ask a manager', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              'A manager can reset your PIN from POS Setup without needing a password at this till.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
}

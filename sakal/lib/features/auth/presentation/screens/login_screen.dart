import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/services/offline_session_cache.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _clientNoCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure     = true;
  bool _loading     = false;
  bool _workOffline = false;
  bool _hasCache    = false;
  String? _error;

  bool get _clientSaved => LocalStorage.clientNo != null;

  @override
  void initState() {
    super.initState();
    _checkCache();
  }

  Future<void> _checkCache() async {
    final has = await OfflineSessionCache.hasCachedCredentials();
    if (mounted) setState(() => _hasCache = has);
  }

  @override
  void dispose() {
    _clientNoCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _workOffline ? await _submitOffline() : await _submitOnline();
  }

  // ── Online path ────────────────────────────────────────────────
  Future<void> _submitOnline() async {
    setState(() { _loading = true; _error = null; });

    final clientNo = _clientSaved
        ? LocalStorage.clientNo!
        : _clientNoCtrl.text.trim().toUpperCase();

    try {
      final loginRes = await DioClient.instance.post('/rpc/fn_login', data: {
        'p_client_no': clientNo,
        'p_username':  _usernameCtrl.text.trim(),
        'p_password':  _passwordCtrl.text,
      });
      final d = loginRes.data as Map<String, dynamic>;

      final token = d['access_token'] as String?;

      // Store JWT immediately so all subsequent requests run as 'authenticated' role.
      // Must happen before fn_get_user_menu call.
      if (token != null) {
        try {
          await const FlutterSecureStorage().write(
            key:   AppConstants.keyAccessToken,
            value: token,
          );
        } catch (_) {
          // Web Crypto failure — token not persisted; user will get 401 on next request
        }
      }

      if (!_clientSaved) {
        await LocalStorage.saveClientSession(
          clientNo: d['client_no'] as String,
          clientId: d['client_id'] as String,
        );
      }

      final menuRes = await DioClient.instance.post('/rpc/fn_get_user_menu', data: {
        'p_user_id':    d['user_id'],
        'p_client_id':  d['client_id'],
        'p_company_id': d['company_id'],
      });
      final menuList = (menuRes.data as List<dynamic>)
          .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
          .toList();

      if (!mounted) return;

      final session = UserSession(
        userId:      d['user_id'] as String,
        clientId:    d['client_id'] as String,
        clientNo:    d['client_no'] as String,
        companyId:   d['company_id'] as String,
        companyName: d['company_name'] as String? ?? '',
        fullName:    d['full_name'] as String,
        username:    d['username'] as String,
        locationId:  d['location_id'] as String?,
      );

      // Cache credentials for future offline login
      await OfflineSessionCache.save(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        session:  session,
        menu:     menuList,
      );

      ref.read(sessionProvider.notifier).state = session;
      ref.read(menuProvider.notifier).state    = menuList;

      // Route to sync screen if pending offline documents exist.
      // On Flutter Web the SQLite WASM runtime is not loaded — skip the check.
      int pending = 0;
      if (!kIsWeb) {
        try {
          pending = await ref.read(syncEngineProvider).pendingCount();
        } catch (_) {}
      }
      if (!mounted) return;
      context.go(pending > 0 ? RouteNames.sync : RouteNames.dashboard);
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? '';
      setState(() => _error = _friendlyError(msg));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Offline path ───────────────────────────────────────────────
  Future<void> _submitOffline() async {
    setState(() { _loading = true; _error = null; });

    try {
      final result = await OfflineSessionCache.tryLogin(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
      );

      if (!mounted) return;

      if (result == null) {
        setState(() => _error =
            'Offline login failed. Check your credentials or sign in online first.');
        return;
      }

      ref.read(sessionProvider.notifier).state = UserSession(
        userId:      result.session.userId,
        clientId:    result.session.clientId,
        clientNo:    result.session.clientNo,
        companyId:   result.session.companyId,
        companyName: result.session.companyName,
        locationId:  result.session.locationId,
        fullName:    result.session.fullName,
        username:    result.session.username,
        offlineMode: true,
      );
      ref.read(menuProvider.notifier).state = result.menu;
      context.go(RouteNames.dashboard);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('INVALID_CREDENTIALS')) return 'Invalid username or password.';
    if (raw.contains('ACCOUNT_INACTIVE'))    return 'Your account has been deactivated. Contact your administrator.';
    if (raw.contains('ACCOUNT_LOCKED'))      return 'Account locked after too many failed attempts. Try again in 30 minutes.';
    if (raw.contains('TRIAL_EXPIRED'))       return 'Your trial has expired. Please contact the SAKAL team.';
    if (raw.contains('LICENSE_EXPIRED'))     return 'Your license has expired. Please contact the SAKAL team.';
    return 'Sign in failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _Logo(),
                const SizedBox(height: 40),
                _buildCard(),
                const SizedBox(height: 24),
                Text(
                  '${AppConfig.companyName}  ·  v${AppConfig.appVersion}',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.45), fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sign In',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text(
                _workOffline
                    ? 'Using cached credentials — no internet needed'
                    : 'Enter your credentials to continue',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 28),

              // Client ID — show pill if saved, input if not
              if (_clientSaved) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.business_outlined,
                          size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text('Client: ${LocalStorage.clientNo}',
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ] else ...[
                TextFormField(
                  controller: _clientNoCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Client ID',
                    hintText: 'e.g. SK-12345',
                    prefixIcon: Icon(Icons.business_outlined),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Client ID is required' : null,
                ),
                const SizedBox(height: 16),
              ],

              // Username
              TextFormField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                textInputAction: TextInputAction.next,
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Username is required' : null,
              ),
              const SizedBox(height: 16),

              // Password
              TextFormField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Password is required' : null,
              ),

              // Work Offline toggle — only on native (mobile/desktop); web is always online
              if (!kIsWeb && _clientSaved && _hasCache) ...[
                const SizedBox(height: 16),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _workOffline = !_workOffline),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _workOffline
                          ? const Color(0xFFE65100).withOpacity(0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _workOffline
                            ? const Color(0xFFE65100).withOpacity(0.5)
                            : AppColors.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _workOffline
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 18,
                          color: _workOffline
                              ? const Color(0xFFE65100)
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Work Offline',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _workOffline
                                      ? const Color(0xFFE65100)
                                      : AppColors.textPrimary,
                                ),
                              ),
                              const Text(
                                'No internet connection required',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.wifi_off_rounded,
                            size: 16,
                            color: _workOffline
                                ? const Color(0xFFE65100)
                                : AppColors.textSecondary.withOpacity(0.4)),
                      ],
                    ),
                  ),
                ),
              ],

              // Error banner
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.negative.withOpacity(0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline,
                          color: AppColors.negative, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.negative))),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: _workOffline
                      ? ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE65100))
                      : null,
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : Text(_workOffline ? 'Sign In Offline' : 'Sign In'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          alignment: Alignment.center,
          child: const Text('S',
              style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary)),
        ),
        const SizedBox(height: 16),
        const Text(AppConfig.appName,
            style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 3)),
        const SizedBox(height: 6),
        Text(AppConfig.appTagline,
            style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.65),
                letterSpacing: 0.5)),
      ],
    );
  }
}

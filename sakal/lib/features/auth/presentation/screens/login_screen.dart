import 'dart:async';
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
import '../../../../core/router/app_router.dart' show setPendingPostLoginRoute;
import '../../../../core/router/route_names.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/services/offline_session_cache.dart';
import '../../../../core/sync/master_data_sync_service.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  // Hidden for now, per direct user request — the "S" mark + "SAKAL ERP" +
  // tagline block will come back once the real logo/branding is ready.
  // Flip to `true` to restore it; the widget itself (_Logo) is untouched.
  static const bool _showBranding = false;

  final _formKey      = GlobalKey<FormState>();
  final _clientNoCtrl = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure     = true;
  bool _loading     = false;
  bool _workOffline = false;
  bool _hasCache    = false;
  String? _error;

  // Additive email-based login (migration 226) — default, no Client ID
  // needed. The existing Client ID + Username + Password path stays fully
  // available via the toggle below; never removed. Offline login always
  // uses Username (OfflineSessionCache is keyed by it, and there's no
  // server to resolve an email against with no connectivity anyway) — see
  // the Work Offline toggle's own onTap, which forces this false whenever
  // offline mode is turned on.
  bool _loginByEmail = true;

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
    _emailCtrl.dispose();
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

    try {
      final Response loginRes;
      if (_loginByEmail) {
        loginRes = await DioClient.instance.post('/rpc/fn_login_by_email', data: {
          'p_email':    _emailCtrl.text.trim(),
          'p_password': _passwordCtrl.text,
        });
      } else {
        final clientNo = _clientSaved
            ? LocalStorage.clientNo!
            : _clientNoCtrl.text.trim().toUpperCase();
        loginRes = await DioClient.instance.post('/rpc/fn_login', data: {
          'p_client_no': clientNo,
          'p_username':  _usernameCtrl.text.trim(),
          'p_password':  _passwordCtrl.text,
        });
      }
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
        userId:           d['user_id']           as String,
        clientId:         d['client_id']         as String,
        clientNo:         d['client_no']         as String,
        companyId:        d['company_id']        as String,
        companyName:      d['company_name']      as String? ?? '',
        fullName:         d['full_name']         as String,
        username:         d['username']          as String,
        locationId:       d['location_id']       as String?,
        enableBarcode:    d['enable_barcode']    as bool? ?? false,
        enablePartNumber: d['enable_part_number'] as bool? ?? false,
        qtyEntryMode:     d['qty_entry_mode']     as String? ?? 'PACK_AND_LOOSE',
        quickInvoiceDispatchStock: d['quick_invoice_dispatch_stock'] as bool? ?? true,
        quickInvoiceCollectCash:   d['quick_invoice_collect_cash']   as bool? ?? true,
        numberFormat:     d['number_format']      as String? ?? 'INTERNATIONAL',
      );

      // Cache credentials for future offline login — always the REAL
      // username from the login response, never the (possibly empty, on
      // the email-login path) _usernameCtrl, since offline re-login is
      // always username-based regardless of which path logged in online.
      await OfflineSessionCache.save(
        username: d['username'] as String,
        password: _passwordCtrl.text,
        session:  session,
        menu:     menuList,
      );

      // Route to sync screen if pending offline documents exist.
      // On Flutter Web the SQLite WASM runtime is not loaded — skip the check.
      int pending = 0;
      if (!kIsWeb) {
        try {
          pending = await ref.read(syncEngineProvider).pendingCount();
        } catch (_) {}
      }
      if (!mounted) return;

      // Decide the post-login destination BEFORE assigning sessionProvider's
      // state below — see setPendingPostLoginRoute's own doc comment
      // (app_router.dart) for why: ref.listen(sessionProvider) in app.dart
      // fires synchronously within the same call stack as that assignment,
      // re-evaluating GoRouter's redirect immediately. An explicit
      // context.go() called AFTER the assignment (even deferred to a
      // post-frame callback) lost that race every time, live, 2026-10-15 —
      // GoRouter's own default-to-/dashboard navigation ran first and
      // disposed this screen before the deferred call ever got to run
      // against a State that was already unmounted. Setting this flag first
      // means the SAME redirect pass that would otherwise send a logged-in
      // user to /dashboard sees the override instead — no second navigation
      // racing against the first.
      //
      // First-login override (migration 225): a brand-new company's very
      // first login lands on Company Setup instead, with a one-time
      // informational popup there pointing at the handful of settings worth
      // reviewing before transacting — never shown again once fn_login has
      // returned `is_first_login: true` exactly once (the DB flag is claimed
      // atomically inside fn_login itself, not tracked client-side). Checked
      // ahead of the pending-sync redirect: a company this new realistically
      // has nothing queued offline yet.
      if (d['is_first_login'] == true) {
        setPendingPostLoginRoute(RouteNames.company, firstLogin: true);
      } else if (pending > 0) {
        setPendingPostLoginRoute(RouteNames.sync);
      }

      ref.read(sessionProvider.notifier).state = session;
      ref.read(menuProvider.notifier).state    = menuList;
      ref.read(userPreferencesProvider.notifier).state = await fetchPrintMode(session);

      // Background master-data refresh for devices with offline mode
      // enabled — non-blocking (never gates reaching Dashboard/Sync), per
      // the offline-design memory's own reasoning against a second
      // blocking full-screen step for a read-only cache warm-up. See
      // core/sync/master_data_sync_service.dart.
      if (!kIsWeb && LocalStorage.deviceOfflineEnabled) {
        unawaited(runBackgroundMasterDataSync(ref, session));
      }
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
        userId:           result.session.userId,
        clientId:         result.session.clientId,
        clientNo:         result.session.clientNo,
        companyId:        result.session.companyId,
        companyName:      result.session.companyName,
        locationId:       result.session.locationId,
        fullName:         result.session.fullName,
        username:         result.session.username,
        offlineMode:      true,
        enableBarcode:    result.session.enableBarcode,
        enablePartNumber: result.session.enablePartNumber,
        qtyEntryMode:     result.session.qtyEntryMode,
        quickInvoiceDispatchStock: result.session.quickInvoiceDispatchStock,
        quickInvoiceCollectCash:   result.session.quickInvoiceCollectCash,
        numberFormat:     result.session.numberFormat,
      );
      ref.read(menuProvider.notifier).state = result.menu;
      // No explicit navigation needed — setting sessionProvider above
      // already triggers GoRouter's redirect to /dashboard on its own (see
      // the same note in _submit() above).
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
                // Hidden for now (2026-09-22, user-requested) — not removed,
                // will come back once the real logo/branding is ready.
                // Flip back to `true` to restore it.
                if (_showBranding) ...[
                  const _Logo(),
                  const SizedBox(height: 40),
                ],
                _buildCard(),
                const SizedBox(height: 24),
                Text(
                  '${AppConfig.companyName}  ·  v${AppConfig.appVersion}',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
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

              // Email + Password is the default online sign-in path
              // (migration 226, additive) — no Client ID needed. Offline
              // mode always uses the existing Client ID + Username path
              // instead (OfflineSessionCache is keyed by username, and
              // there's no server to resolve an email against with no
              // connectivity), so this branch is skipped whenever
              // `_workOffline` is true, regardless of `_loginByEmail`.
              if (!_workOffline && _loginByEmail) ...[
                TextFormField(
                  key: const Key('login_email'),
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.alternate_email),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (v) => (v == null || v.isEmpty) ? 'Email is required' : null,
                ),
                const SizedBox(height: 16),
              ] else ...[
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
                    key: const Key('login_client_no'),
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
                  key: const Key('login_username'),
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
              ],

              if (!_workOffline) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _loginByEmail = !_loginByEmail),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: Text(
                      _loginByEmail ? 'Sign in with Client ID instead' : 'Sign in with Email instead',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // Password
              TextFormField(
                key: const Key('login_password'),
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
                  onTap: () => setState(() {
                    _workOffline = !_workOffline;
                    // Offline login is always Username-based (see the
                    // Email-field branch's own doc comment above) — force
                    // the toggle back whenever offline mode turns on.
                    if (_workOffline) _loginByEmail = false;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _workOffline
                          ? const Color(0xFFE65100).withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _workOffline
                            ? const Color(0xFFE65100).withValues(alpha: 0.5)
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
                                : AppColors.textSecondary.withValues(alpha: 0.4)),
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
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.negative.withValues(alpha: 0.3)),
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
                  key: const Key('btn_login'),
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
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(
                    child: Text(
                      "Don't have a registered business?",
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go(RouteNames.register),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('Register', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.help_outline, size: 16),
                    color: AppColors.textSecondary,
                    tooltip: 'What is registration?',
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: _showRegistrationHelp,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRegistrationHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Registering your business'),
        content: const Text(
          'Registration creates a brand-new, private account for your business — '
          'your own company, your first store/office location, and an '
          'administrator login — all in a few minutes. You\'ll get a Client ID '
          'at the end, which identifies your business whenever you (or your '
          'team) sign in. Use it if you\'re setting up SAKAL for your business '
          'for the first time; if someone else already registered it, ask them '
          'for your sign-in details instead.',
          style: TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.go(RouteNames.register);
            },
            child: const Text('Register Now'),
          ),
        ],
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
                color: Colors.white.withValues(alpha: 0.65),
                letterSpacing: 0.5)),
      ],
    );
  }
}

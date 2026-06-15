import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/theme/app_colors.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _clientNoCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure  = true;
  bool _loading  = false;
  String? _error;

  // If client_no is already saved on device, we don't show the input field
  bool get _clientSaved => LocalStorage.clientNo != null;

  @override
  void dispose() {
    _clientNoCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });

    final clientNo = _clientSaved
        ? LocalStorage.clientNo!
        : _clientNoCtrl.text.trim().toUpperCase();

    try {
      final res = await DioClient.instance.post('/rpc/fn_login', data: {
        'p_client_no': clientNo,
        'p_username':  _usernameCtrl.text.trim(),
        'p_password':  _passwordCtrl.text,
      });
      final data = res.data as Map<String, dynamic>;

      // Save session if not already saved (first login on this device)
      if (!_clientSaved) {
        await LocalStorage.saveClientSession(
          clientNo: data['client_no'] as String,
          clientId: data['client_id'] as String,
        );
      }

      if (mounted) context.go(RouteNames.dashboard);
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? '';
      setState(() => _error = _friendlyError(msg));
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
                _Logo(),
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
              const Text('Enter your credentials to continue',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 28),

              // Client ID — shown only if not saved locally
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

              // Error
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
              ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Sign In'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
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

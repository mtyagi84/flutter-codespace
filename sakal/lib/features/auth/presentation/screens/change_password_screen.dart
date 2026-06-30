import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState
    extends ConsumerState<ChangePasswordScreen> {
  final _formKey     = GlobalKey<FormState>();
  final _currentCtrl = TextEditingController();
  final _newCtrl     = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool    _obscureCurrent = true;
  bool    _obscureNew     = true;
  bool    _obscureConfirm = true;
  bool    _loading        = false;
  String? _error;
  bool    _success        = false;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; _success = false; });
    try {
      await DioClient.instance.post('/rpc/fn_change_password', data: {
        'p_user_id':          session.userId,
        'p_current_password': _currentCtrl.text,
        'p_new_password':     _newCtrl.text,
      });
      if (mounted) {
        setState(() { _loading = false; _success = true; });
        _currentCtrl.clear();
        _newCtrl.clear();
        _confirmCtrl.clear();
      }
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Change failed';
      if (mounted) {
        setState(() { _loading = false; _error = _friendly(msg); });
      }
    }
  }

  String _friendly(String raw) {
    if (raw.contains('WRONG_PASSWORD') || raw.contains('INVALID_CREDENTIALS')) {
      return 'Current password is incorrect.';
    }
    if (raw.contains('SAME_PASSWORD')) {
      return 'New password must differ from the current one.';
    }
    if (raw.contains('TOO_SHORT') || raw.contains('WEAK')) {
      return 'Password is too weak. Use at least 8 characters.';
    }
    return 'Password change failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ───────────────────────────────────────────────
              const Text('Change Password',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text('Update your account password.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 24),

              // ── Card ─────────────────────────────────────────────────
              Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [

                        // Success banner
                        if (_success) ...[
                          _Banner(
                            color: AppColors.positive,
                            icon: Icons.check_circle_outline,
                            message: 'Password changed successfully.',
                          ),
                          const SizedBox(height: 20),
                        ],

                        // Current password
                        TextFormField(
                          controller: _currentCtrl,
                          obscureText: _obscureCurrent,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: 'Current Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: _VisibilityToggle(
                              obscure: _obscureCurrent,
                              onToggle: () => setState(
                                  () => _obscureCurrent = !_obscureCurrent),
                            ),
                          ),
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Required' : null,
                        ),
                        const SizedBox(height: 20),

                        // New password
                        TextFormField(
                          controller: _newCtrl,
                          obscureText: _obscureNew,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: 'New Password',
                            prefixIcon: const Icon(Icons.lock_reset_outlined),
                            suffixIcon: _VisibilityToggle(
                              obscure: _obscureNew,
                              onToggle: () =>
                                  setState(() => _obscureNew = !_obscureNew),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Required';
                            if (v.length < 8) return 'Minimum 8 characters';
                            if (!v.contains(RegExp(r'[A-Z]'))) {
                              return 'Include at least one uppercase letter';
                            }
                            if (!v.contains(RegExp(r'[0-9]'))) {
                              return 'Include at least one number';
                            }
                            return null;
                          },
                        ),

                        // Password strength bar — live, no extra setState
                        const SizedBox(height: 8),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _newCtrl,
                          builder: (_, value, __) =>
                              _StrengthBar(password: value.text),
                        ),
                        const SizedBox(height: 20),

                        // Confirm new password
                        TextFormField(
                          controller: _confirmCtrl,
                          obscureText: _obscureConfirm,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: 'Confirm New Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: _VisibilityToggle(
                              obscure: _obscureConfirm,
                              onToggle: () => setState(
                                  () => _obscureConfirm = !_obscureConfirm),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Required';
                            if (v != _newCtrl.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),

                        // Error banner
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _Banner(
                            color: AppColors.negative,
                            icon: Icons.error_outline,
                            message: _error!,
                          ),
                        ],

                        const SizedBox(height: 28),

                        // Submit
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2))
                                : const Text('Change Password'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () => context.go(RouteNames.dashboard),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Password strength bar ──────────────────────────────────────────────────

class _StrengthBar extends StatelessWidget {
  final String password;
  const _StrengthBar({required this.password});

  int get _score {
    if (password.isEmpty) return 0;
    int s = 0;
    if (password.length >= 8) s++;
    if (password.contains(RegExp(r'[A-Z]'))) s++;
    if (password.contains(RegExp(r'[0-9]'))) s++;
    if (password.contains(RegExp(r'[^A-Za-z0-9]'))) s++;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final s = _score;
    const colors = [
      AppColors.negative,   // 1 — Weak
      Color(0xFFE65100),    // 2 — Fair  (deep orange)
      Color(0xFFF9A825),    // 3 — Good  (amber)
      AppColors.positive,   // 4 — Strong
    ];
    const labels = ['Weak', 'Fair', 'Good', 'Strong'];
    final barColor  = s == 0 ? const Color(0xFFE0E0E0) : colors[s - 1];
    final label     = s == 0 ? '' : labels[s - 1];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(4, (i) => Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
              decoration: BoxDecoration(
                color: i < s ? barColor : const Color(0xFFE0E0E0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          )),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Strength: $label',
            style: TextStyle(
                fontSize: 11,
                color: barColor,
                fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

// ── Small reusable widgets ─────────────────────────────────────────────────

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  const _Banner({required this.color, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 13, color: color)),
          ),
        ],
      ),
    );
  }
}

class _VisibilityToggle extends StatelessWidget {
  final bool obscure;
  final VoidCallback onToggle;
  const _VisibilityToggle({required this.obscure, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(obscure
          ? Icons.visibility_outlined
          : Icons.visibility_off_outlined),
      onPressed: onToggle,
    );
  }
}

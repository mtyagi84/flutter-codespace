import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/local_storage.dart';
import '../../../../core/theme/app_colors.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  int _step = 0;
  bool _loading = false;
  String? _error;
  String? _clientNo;

  // Step 0 — Business Info
  final _key0 = GlobalKey<FormState>();
  final _businessNameCtrl = TextEditingController();
  final _countryCtrl      = TextEditingController();
  final _contactNameCtrl  = TextEditingController();
  final _emailCtrl        = TextEditingController();
  final _phoneCtrl        = TextEditingController();

  // Step 1 — Company
  final _key1 = GlobalKey<FormState>();
  final _companyNameCtrl  = TextEditingController();
  final _companyShortCtrl = TextEditingController();
  String _baseCurrency  = 'USD';
  String _localCurrency = 'CDF';

  // Step 2 — Location
  final _key2 = GlobalKey<FormState>();
  final _locationNameCtrl  = TextEditingController();
  final _locationShortCtrl = TextEditingController();
  String _locationType = 'STORE';

  // Step 3 — Admin User
  final _key3 = GlobalKey<FormState>();
  final _adminNameCtrl = TextEditingController();
  final _usernameCtrl  = TextEditingController();
  final _passwordCtrl  = TextEditingController();
  final _confirmCtrl   = TextEditingController();
  bool _obscurePass    = true;
  bool _obscureConfirm = true;

  static const _currencies = ['USD', 'EUR', 'GBP', 'ZAR', 'CDF', 'ZMW', 'NGN', 'KES'];
  static const _locationTypes = ['STORE', 'WAREHOUSE', 'OFFICE'];

  @override
  void dispose() {
    _businessNameCtrl.dispose(); _countryCtrl.dispose();
    _contactNameCtrl.dispose();  _emailCtrl.dispose();
    _phoneCtrl.dispose();        _companyNameCtrl.dispose();
    _companyShortCtrl.dispose(); _locationNameCtrl.dispose();
    _locationShortCtrl.dispose(); _adminNameCtrl.dispose();
    _usernameCtrl.dispose();     _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool _validateStep() {
    final keys = [_key0, _key1, _key2, _key3];
    if (_step >= keys.length) return true;
    return keys[_step].currentState!.validate();
  }

  void _next() {
    setState(() => _error = null);
    if (!_validateStep()) return;
    if (_step == 3) {
      _submit();
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    setState(() { _step--; _error = null; });
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      final res = await DioClient.instance.post('/rpc/fn_register_client', data: {
        'p_business_name':  _businessNameCtrl.text.trim(),
        'p_country':        _countryCtrl.text.trim(),
        'p_contact_name':   _contactNameCtrl.text.trim(),
        'p_email':          _emailCtrl.text.trim(),
        'p_phone':          _phoneCtrl.text.trim(),
        'p_company_name':   _companyNameCtrl.text.trim(),
        'p_company_short':  _companyShortCtrl.text.trim(),
        'p_base_currency':  _baseCurrency,
        'p_local_currency': _localCurrency,
        'p_location_name':  _locationNameCtrl.text.trim(),
        'p_location_short': _locationShortCtrl.text.trim(),
        'p_location_type':  _locationType,
        'p_admin_name':     _adminNameCtrl.text.trim(),
        'p_username':       _usernameCtrl.text.trim(),
        'p_password':       _passwordCtrl.text,
      });
      final data = res.data as Map<String, dynamic>;
      await LocalStorage.saveClientSession(
        clientNo: data['client_no'] as String,
        clientId: data['client_id'] as String,
      );
      setState(() { _clientNo = data['client_no'] as String; _step = 4; });
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? '';
      setState(() => _error = msg.contains('EMAIL_EXISTS')
          ? 'This email is already registered. Please sign in instead.'
          : 'Registration failed. Please check your details and try again.');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _step < 4
          ? AppBar(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              title: const Text('Register Your Business',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              leading: _step > 0
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _back,
                    )
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => context.go(RouteNames.landing),
                    ),
            )
          : null,
      body: _step == 4 ? _buildSuccess() : _buildForm(),
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        _StepIndicator(current: _step, total: 4),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_error != null)
                      _ErrorBanner(message: _error!),
                    _buildStepContent(),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _next,
                        child: _loading
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text(_step == 3 ? 'Complete Registration' : 'Continue',
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case 0: return _buildStep0();
      case 1: return _buildStep1();
      case 2: return _buildStep2();
      case 3: return _buildStep3();
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildStep0() {
    return Form(
      key: _key0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepTitle('About Your Business'),
          _field(_businessNameCtrl, 'Business / Trading Name', required: true),
          _field(_countryCtrl, 'Country', required: true),
          _field(_contactNameCtrl, 'Contact Person Name', required: true),
          _field(_emailCtrl, 'Email Address',
              required: true,
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                if (v == null || v.isEmpty) return 'Email is required';
                if (!v.contains('@') || !v.contains('.')) return 'Enter a valid email';
                return null;
              }),
          _field(_phoneCtrl, 'Phone Number', keyboardType: TextInputType.phone),
        ],
      ),
    );
  }

  Widget _buildStep1() {
    return Form(
      key: _key1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepTitle('Company Details'),
          _field(_companyNameCtrl, 'Company Name', required: true),
          _field(_companyShortCtrl, 'Short Name (max 8 chars)',
              required: true,
              validator: (v) {
                if (v == null || v.isEmpty) return 'Short name is required';
                if (v.length > 8) return 'Max 8 characters';
                return null;
              }),
          const SizedBox(height: 8),
          _dropdownField(
            label: 'Base Currency (books kept in)',
            value: _baseCurrency,
            items: _currencies,
            onChanged: (v) => setState(() => _baseCurrency = v!),
          ),
          const SizedBox(height: 16),
          _dropdownField(
            label: 'Local Currency (regional)',
            value: _localCurrency,
            items: _currencies,
            onChanged: (v) => setState(() => _localCurrency = v!),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return Form(
      key: _key2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepTitle('Your First Location'),
          _field(_locationNameCtrl, 'Location Name (e.g. Main Store)', required: true),
          _field(_locationShortCtrl, 'Short Name (max 8 chars)',
              required: true,
              validator: (v) {
                if (v == null || v.isEmpty) return 'Short name is required';
                if (v.length > 8) return 'Max 8 characters';
                return null;
              }),
          const SizedBox(height: 8),
          _dropdownField(
            label: 'Location Type',
            value: _locationType,
            items: _locationTypes,
            onChanged: (v) => setState(() => _locationType = v!),
          ),
        ],
      ),
    );
  }

  Widget _buildStep3() {
    return Form(
      key: _key3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepTitle('Administrator Account'),
          _field(_adminNameCtrl, 'Full Name', required: true),
          _field(_usernameCtrl, 'Username',
              required: true,
              validator: (v) {
                if (v == null || v.isEmpty) return 'Username is required';
                if (v.contains(' ')) return 'No spaces allowed';
                if (v.length < 3) return 'At least 3 characters';
                return null;
              }),
          TextFormField(
            controller: _passwordCtrl,
            obscureText: _obscurePass,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(_obscurePass
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscurePass = !_obscurePass),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Password is required';
              if (v.length < 6) return 'At least 6 characters';
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirmCtrl,
            obscureText: _obscureConfirm,
            decoration: InputDecoration(
              labelText: 'Confirm Password',
              suffixIcon: IconButton(
                icon: Icon(_obscureConfirm
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),
            ),
            validator: (v) {
              if (v != _passwordCtrl.text) return 'Passwords do not match';
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 72, color: Colors.white),
                  const SizedBox(height: 24),
                  const Text(
                    'Registration Complete!',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your 30-day free trial has started.',
                    style: TextStyle(
                        fontSize: 14, color: Colors.white.withOpacity(0.7)),
                  ),
                  const SizedBox(height: 40),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        const Text('Your Client ID',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 8),
                        Text(
                          _clientNo ?? '',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: _clientNo ?? ''));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Client ID copied'),
                                  duration: Duration(seconds: 2)),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy to Clipboard'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.secondary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.secondary, width: 1),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: AppColors.secondary, size: 18),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Save this Client ID. Share it with your team — '
                            'they will need it to sign in.',
                            style: TextStyle(
                                fontSize: 13, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () => context.go(RouteNames.login),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.secondary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Go to Sign In',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Text(title,
          style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary)),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool required = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label),
        validator: validator ??
            (required
                ? (v) => (v == null || v.isEmpty) ? '$label is required' : null
                : null),
      ),
    );
  }

  Widget _dropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      decoration: InputDecoration(labelText: label),
      items: items
          .map((e) => DropdownMenuItem(value: e, child: Text(e)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

class _StepIndicator extends StatelessWidget {
  final int current;
  final int total;

  const _StepIndicator({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final labels = ['Business', 'Company', 'Location', 'Admin'];
    return Container(
      color: AppColors.primary,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      child: Row(
        children: List.generate(total, (i) {
          final done    = i < current;
          final active  = i == current;
          return Expanded(
            child: Row(
              children: [
                Column(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: done
                          ? AppColors.positive
                          : active
                              ? Colors.white
                              : Colors.white24,
                      child: done
                          ? const Icon(Icons.check, size: 14, color: Colors.white)
                          : Text('${i + 1}',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: active
                                      ? AppColors.primary
                                      : Colors.white54)),
                    ),
                    const SizedBox(height: 4),
                    Text(labels[i],
                        style: TextStyle(
                            fontSize: 10,
                            color: active || done
                                ? Colors.white
                                : Colors.white38)),
                  ],
                ),
                if (i < total - 1)
                  Expanded(
                    child: Container(
                      height: 1.5,
                      margin: const EdgeInsets.only(bottom: 20),
                      color: done ? AppColors.positive : Colors.white24,
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.negative.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.negative.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message,
                  style: const TextStyle(
                      color: AppColors.negative, fontSize: 13))),
        ],
      ),
    );
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

class AccountingSetupScreen extends ConsumerStatefulWidget {
  const AccountingSetupScreen({super.key});

  @override
  ConsumerState<AccountingSetupScreen> createState() =>
      _AccountingSetupScreenState();
}

class _AccountingSetupScreenState
    extends ConsumerState<AccountingSetupScreen> {
  Map<String, dynamic>? _setup;
  bool _loading  = true;
  bool _saving   = false;
  String? _error;
  String? _saveError;

  // Form state
  String _std           = 'OHADA';
  int    _fyStartMonth  = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  // ── Data ─────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final res = await DioClient.instance.get(
        '/rim_accounting_setup',
        queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'select':     '*',
          'limit':      '1',
        },
      );
      final rows = List<Map<String, dynamic>>.from(res.data as List);
      if (mounted) {
        setState(() {
          _setup   = rows.isEmpty ? null : rows.first;
          _loading = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load accounting setup.'; });
    }
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _saveError = null; });
    try {
      // 1 — Save accounting setup
      await DioClient.instance.post(
        '/rim_accounting_setup',
        data: {
          'client_id':      session.clientId,
          'company_id':     session.companyId,
          'accounting_std': _std,
          'fy_start_month': _fyStartMonth,
          'fy_start_day':   1,
          'created_by':     session.userId,
          'updated_by':     session.userId,
        },
        options: Options(headers: {
          'Prefer': 'resolution=ignore-duplicates',
        }),
      );

      // 2 — Seed Chart of Accounts
      await DioClient.instance.post(
        '/rpc/fn_seed_chart_of_accounts',
        data: {
          'p_client_id':  session.clientId,
          'p_company_id': session.companyId,
          'p_std':        _std,
        },
      );

      // 3 — Create first financial year
      await _createFirstFY(session.clientId, session.companyId, session.userId);

      await _load();
    } on DioException catch (e) {
      if (mounted) {
        setState(() { _saveError = e.response?.data?['message'] ?? 'Save failed.'; });
      }
    } finally {
      if (mounted) setState(() { _saving = false; });
    }
  }

  Future<void> _createFirstFY(
      String clientId, String companyId, String userId) async {
    final now   = DateTime.now();
    final start = _fyStartForYear(now.year, _fyStartMonth);
    final end   = DateTime(start.year + 1, start.month, start.day)
        .subtract(const Duration(days: 1));
    final name  = _fyName(start, end);

    await DioClient.instance.post(
      '/rim_financial_years',
      data: {
        'client_id':      clientId,
        'company_id':     companyId,
        'fy_name':        name,
        'fy_start_date':  '${start.year}-${_pad(start.month)}-${_pad(start.day)}',
        'fy_end_date':    '${end.year}-${_pad(end.month)}-${_pad(end.day)}',
        'is_active':      true,
        'is_closed':      false,
        'created_by':     userId,
        'updated_by':     userId,
      },
      options: Options(headers: {'Prefer': 'resolution=ignore-duplicates'}),
    );
  }

  DateTime _fyStartForYear(int year, int startMonth) {
    final now = DateTime.now();
    final candidate = DateTime(year, startMonth, 1);
    // If the FY start month is ahead of current month, use previous year's start
    if (candidate.isAfter(now)) return DateTime(year - 1, startMonth, 1);
    return candidate;
  }

  String _fyName(DateTime start, DateTime end) {
    if (start.year == end.year) return 'FY ${start.year}';
    return 'FY ${start.year}-${(end.year % 100).toString().padLeft(2, '0')}';
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.negative)))
              : _setup != null && _setup!['is_coa_seeded'] == true
                  ? _lockedView()
                  : _setupForm(),
    );
  }

  // ── Locked (read-only after seeding) ─────────────────────────────────────

  Widget _lockedView() {
    final std       = _setup!['accounting_std'] as String;
    final month     = _setup!['fy_start_month'] as int;
    final endMonth  = month == 1 ? 12 : month - 1;
    return Center(
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.lock_outline, size: 20, color: AppColors.positive),
              SizedBox(width: 8),
              Text('Accounting Setup',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
            ]),
            const SizedBox(height: 4),
            const Text('Locked — cannot be changed after Chart of Accounts is seeded.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 28),
            _infoRow('Accounting Standard', std == 'OHADA'
                ? 'OHADA / SYSCOHADA (DRC & Francophone Africa)'
                : 'Indian Accounting Standards'),
            const SizedBox(height: 16),
            _infoRow('Financial Year', '${_months[month - 1]} 1  →  ${_months[endMonth - 1]} ${endMonth == 2 ? 28 : [4,6,9,11].contains(endMonth) ? 30 : 31}'),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(children: [
                Icon(Icons.check_circle_outline, size: 18, color: AppColors.positive),
                SizedBox(width: 8),
                Text('Chart of Accounts seeded successfully.',
                    style: TextStyle(fontSize: 13, color: AppColors.positive)),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary,
          fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontSize: 15, color: AppColors.textPrimary,
          fontWeight: FontWeight.w600)),
    ],
  );

  // ── Setup form ────────────────────────────────────────────────────────────

  Widget _setupForm() {
    final endMonth = _fyStartMonth == 1 ? 12 : _fyStartMonth - 1;
    final endDay   = [4, 6, 9, 11].contains(endMonth) ? 30 : endMonth == 2 ? 28 : 31;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Accounting Setup',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text(
                'This is a one-time setup. Accounting standard cannot be changed '
                'after the Chart of Accounts is seeded.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 32),

              // Accounting Standard
              const Text('Accounting Standard *',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 10),
              RadioGroup<String>(
                groupValue: _std,
                onChanged: (v) { if (v != null) setState(() => _std = v); },
                child: Column(
                  children: [
                    _stdCard('OHADA', 'OHADA / SYSCOHADA',
                        'For DRC and Francophone Africa. Class-based numeric accounts (1xxx–9xxx).',
                        Icons.public),
                    const SizedBox(height: 10),
                    _stdCard('INDIAN', 'Indian Accounting Standards',
                        'Assets / Liabilities / Equity / Revenue / Expense structure.',
                        Icons.account_balance_outlined),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // FY Start Month
              const Text('Financial Year Start Month *',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _fyStartMonth,
                decoration: const InputDecoration(isDense: true),
                items: List.generate(12, (i) => DropdownMenuItem(
                  value: i + 1,
                  child: Text('${_months[i]}  (${i + 1})'),
                )),
                onChanged: (v) => setState(() => _fyStartMonth = v!),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.info_outline, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    'Your FY: ${_months[_fyStartMonth - 1]} 1  →  ${_months[endMonth - 1]} $endDay',
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ]),
              ),

              if (_saveError != null) ...[
                const SizedBox(height: 16),
                Text(_saveError!,
                    style: const TextStyle(color: AppColors.negative, fontSize: 13)),
              ],

              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2,
                              color: Colors.white))
                      : const Text('Save & Seed Chart of Accounts'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stdCard(String value, String title, String subtitle, IconData icon) {
    final selected = _std == value;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _std = value),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          color: selected ? const Color(0xFFEAF0FB) : AppColors.surface,
        ),
        child: Row(children: [
          Radio<String>(
            value: value,
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 22, color: selected ? AppColors.primary : AppColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: selected ? AppColors.primary : AppColors.textPrimary)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ]),
          ),
        ]),
      ),
    );
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

/// One row per Bank-nature rim_accounts row set up for reconciliation. No
/// repository/model layer for this screen, same convention as
/// sales_executive_master_screen.dart.
class BankAccount {
  final String id;
  final String accountId;
  final String accountCode;
  final String accountName;
  final String bankName;
  final String? accountNumber;
  final String? branchName;
  final String? ifscSwiftCode;
  final String? defaultFormatId;
  final String? defaultFormatName;
  final bool isActive;

  const BankAccount({
    required this.id,
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.bankName,
    required this.accountNumber,
    required this.branchName,
    required this.ifscSwiftCode,
    required this.defaultFormatId,
    required this.defaultFormatName,
    required this.isActive,
  });

  factory BankAccount.fromJson(Map<String, dynamic> j) {
    final account = j['account'] as Map<String, dynamic>?;
    final format = j['default_format'] as Map<String, dynamic>?;
    return BankAccount(
      id:                j['id'] as String? ?? '',
      accountId:         j['account_id'] as String? ?? '',
      accountCode:       account?['account_code'] as String? ?? '',
      accountName:       account?['account_name'] as String? ?? '',
      bankName:          j['bank_name'] as String? ?? '',
      accountNumber:     j['account_number'] as String?,
      branchName:        j['branch_name'] as String?,
      ifscSwiftCode:     j['ifsc_swift_code'] as String?,
      defaultFormatId:   j['default_format_id'] as String?,
      defaultFormatName: format?['format_name'] as String?,
      isActive:          j['is_active'] as bool? ?? true,
    );
  }
}

/// Bank Accounts (migration 174) — links a Bank-nature rim_accounts row to
/// its real bank details (bank name/account number/branch/IFSC-SWIFT) and
/// a default Bank Statement Format, so the Upload & Review screen knows
/// which account this is and can pre-select its parsing format.
class BankAccountsScreen extends ConsumerStatefulWidget {
  const BankAccountsScreen({super.key});

  @override
  ConsumerState<BankAccountsScreen> createState() => _BankAccountsScreenState();
}

class _BankAccountsScreenState extends ConsumerState<BankAccountsScreen>
    with ScreenPermissionMixin<BankAccountsScreen>, ScreenHeaderMixin<BankAccountsScreen> {
  @override String get screenName => RouteNames.bankAccounts;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Bank Accounts',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Bank Account'),
                    onPressed: () => _showEntryDialog(),
                  ),
                ),
              ]
            : const [],
      );

  List<BankAccount> _rows = [];
  List<Map<String, dynamic>> _bankNatureAccounts = [];
  List<Map<String, dynamic>> _formats = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_bank_accounts', queryParameters: {
          'client_id': 'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select': '*,account:rim_accounts!account_id(account_code,account_name),'
              'default_format:rim_bank_statement_formats!default_format_id(format_name)',
          'order': 'bank_name.asc',
        }),
        DioClient.instance.get('/rim_accounts', queryParameters: {
          'client_id': 'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'account_nature': 'eq.Bank',
          'posting_allowed': 'eq.true',
          'is_deleted': 'eq.false',
          'select': 'id,account_code,account_name',
          'order': 'account_name.asc',
        }),
        DioClient.instance.get('/rim_bank_statement_formats', queryParameters: {
          'client_id': 'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_active': 'eq.true', 'is_deleted': 'eq.false',
          'select': 'id,format_name',
          'order': 'format_name.asc',
        }),
      ]);
      if (mounted) {
        setState(() {
          _rows = (results[0].data as List).map((j) => BankAccount.fromJson(j as Map<String, dynamic>)).toList();
          _bankNatureAccounts = List<Map<String, dynamic>>.from(results[1].data as List);
          _formats = List<Map<String, dynamic>>.from(results[2].data as List);
          _loading = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load bank accounts.'; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<void> _save(Map<String, dynamic> payload, {String? id}) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (id == null) {
        await DioClient.instance.post('/rim_bank_accounts', data: {...payload, 'created_by': session.userId});
      } else {
        await DioClient.instance.patch('/rim_bank_accounts',
            queryParameters: {'id': 'eq.$id'}, data: {...payload, 'updated_by': session.userId});
      }
      await _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] ?? 'Save failed. This account may already be set up.');
    }
  }

  Future<void> _toggleActive(BankAccount row) async {
    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.patch('/rim_bank_accounts',
          queryParameters: {'id': 'eq.${row.id}'},
          data: {'is_active': !row.isActive, 'updated_by': session.userId});
      await _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] ?? 'Update failed.');
    }
  }

  Future<void> _showEntryDialog({BankAccount? existing}) async {
    String? accountId = existing?.accountId;
    final bankNameCtrl = TextEditingController(text: existing?.bankName ?? '');
    final acctNoCtrl = TextEditingController(text: existing?.accountNumber ?? '');
    final branchCtrl = TextEditingController(text: existing?.branchName ?? '');
    final ifscCtrl = TextEditingController(text: existing?.ifscSwiftCode ?? '');
    String? defaultFormatId = existing?.defaultFormatId;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New Bank Account' : 'Edit Bank Account'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButtonFormField<String?>(
                  initialValue: accountId,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Chart of Accounts — Bank Ledger *'),
                  items: _bankNatureAccounts
                      .map((a) => DropdownMenuItem(value: a['id'] as String, child: Text('[${a['account_code']}] ${a['account_name']}', overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: existing == null ? (v) => setDialogState(() => accountId = v) : null,
                ),
                const SizedBox(height: 10),
                TextField(controller: bankNameCtrl, decoration: const InputDecoration(labelText: 'Bank Name *')),
                const SizedBox(height: 10),
                TextField(controller: acctNoCtrl, decoration: const InputDecoration(labelText: 'Account Number')),
                const SizedBox(height: 10),
                TextField(controller: branchCtrl, decoration: const InputDecoration(labelText: 'Branch')),
                const SizedBox(height: 10),
                TextField(controller: ifscCtrl, decoration: const InputDecoration(labelText: 'IFSC / SWIFT Code')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: defaultFormatId,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Default Statement Format'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— Choose on upload —')),
                    ..._formats.map((f) => DropdownMenuItem(value: f['id'] as String, child: Text(f['format_name'] as String, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setDialogState(() => defaultFormatId = v),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved == true && accountId != null && bankNameCtrl.text.trim().isNotEmpty) {
      final session = ref.read(sessionProvider)!;
      await _save({
        'client_id': session.clientId,
        'company_id': session.companyId,
        'account_id': accountId,
        'bank_name': bankNameCtrl.text.trim(),
        'account_number': acctNoCtrl.text.trim().isEmpty ? null : acctNoCtrl.text.trim(),
        'branch_name': branchCtrl.text.trim().isEmpty ? null : branchCtrl.text.trim(),
        'ifsc_swift_code': ifscCtrl.text.trim().isEmpty ? null : ifscCtrl.text.trim(),
        'default_format_id': defaultFormatId,
      }, id: existing?.id);
    } else if (saved == true) {
      _showError('Select a Bank ledger account and enter the Bank Name.');
    }
    bankNameCtrl.dispose();
    acctNoCtrl.dispose();
    branchCtrl.dispose();
    ifscCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: SakalAdaptiveList<BankAccount>(
        loading: _loading,
        error: _error,
        rows: _rows,
        columns: const [
          SakalListColumn('Ledger Account', flex: 3),
          SakalListColumn('Bank Name', flex: 3),
          SakalListColumn('Account Number', flex: 2),
          SakalListColumn('Default Format', flex: 2),
          SakalListColumn('Status', flex: 2),
          SakalListColumn('', flex: 2),
        ],
        rowBuilder: _buildRow,
        cardBuilder: _buildCard,
        emptyState: _emptyState(),
      ),
    );
  }

  Widget _statusBadge(bool isActive) {
    final color = isActive ? AppColors.positive : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isActive ? 'Active' : 'Inactive', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(BankAccount r, int index) {
    return InkWell(
      onTap: canEdit ? () => _showEntryDialog(existing: r) : null,
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text('[${r.accountCode}] ${r.accountName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.bankName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.accountNumber ?? '—', style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.defaultFormatName ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _statusBadge(r.isActive))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(alignment: WrapAlignment.start, spacing: 0, runSpacing: 0, children: [
                if (canEdit) IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showEntryDialog(existing: r), tooltip: 'Edit'),
                if (canEdit) IconButton(
                    icon: Icon(r.isActive ? Icons.block : Icons.check_circle_outline, size: 16, color: r.isActive ? AppColors.negative : AppColors.positive),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _toggleActive(r), tooltip: r.isActive ? 'Deactivate' : 'Activate'),
              ]))),
        ]),
      ),
    );
  }

  Widget _buildCard(BankAccount r) {
    return InkWell(
      onTap: canEdit ? () => _showEntryDialog(existing: r) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.bankName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r.isActive),
          ]),
          const SizedBox(height: 4),
          Text('[${r.accountCode}] ${r.accountName}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (r.accountNumber != null) ...[
            const SizedBox(height: 4),
            Text('A/c: ${r.accountNumber}', style: const TextStyle(fontSize: 12)),
          ],
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.account_balance_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No bank accounts found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Link a Bank ledger account to its real bank details to enable reconciliation.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

class _StatementRow {
  final String statementNo;
  final String statementDate;
  final String periodFrom;
  final String periodTo;
  final String bankName;
  final String accountLabel;
  final String status;

  const _StatementRow({
    required this.statementNo, required this.statementDate,
    required this.periodFrom, required this.periodTo,
    required this.bankName, required this.accountLabel, required this.status,
  });

  factory _StatementRow.fromJson(Map<String, dynamic> j) {
    final bankAccount = j['bank_account'] as Map<String, dynamic>?;
    final account = bankAccount?['account'] as Map<String, dynamic>?;
    return _StatementRow(
      statementNo: j['statement_no'] as String? ?? '',
      statementDate: j['statement_date'] as String? ?? '',
      periodFrom: j['period_from'] as String? ?? '',
      periodTo: j['period_to'] as String? ?? '',
      bankName: bankAccount?['bank_name'] as String? ?? '',
      accountLabel: account == null ? '' : '[${account['account_code']}] ${account['account_name']}',
      status: j['status'] as String? ?? 'DRAFT',
    );
  }
}

/// Bank Statement list — see docs/screens/bank_statement_upload_review.md.
class BankStatementListScreen extends ConsumerStatefulWidget {
  const BankStatementListScreen({super.key});

  @override
  ConsumerState<BankStatementListScreen> createState() => _BankStatementListScreenState();
}

class _BankStatementListScreenState extends ConsumerState<BankStatementListScreen>
    with ScreenPermissionMixin<BankStatementListScreen>, ScreenHeaderMixin<BankStatementListScreen> {
  @override String get screenName => RouteNames.bankStatements;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Bank Statements',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('New Statement'), onPressed: _openNew),
                ),
              ]
            : const [],
      );

  List<_StatementRow> _rows = [];
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
      final res = await DioClient.instance.get('/rih_bank_statement_headers', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select': '*,bank_account:rim_bank_accounts!bank_account_id(bank_name,account:rim_accounts!account_id(account_code,account_name))',
        'order': 'statement_date.desc',
        'limit': '200',
      });
      if (mounted) {
        setState(() {
          _rows = (res.data as List).map((j) => _StatementRow.fromJson(j as Map<String, dynamic>)).toList();
          _loading = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('BankStatementListLoad', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load bank statements'); });
    }
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.bankStatementEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(_StatementRow r) async {
    await context.push(RouteNames.bankStatementEntry, extra: {'statementNo': r.statementNo, 'statementDate': r.statementDate});
    if (mounted) _load();
  }

  Widget _statusBadge(String status) {
    final color = status == 'APPROVED' ? AppColors.positive : AppColors.badgeDraft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    return SakalAdaptiveList<_StatementRow>(
      loading: _loading,
      error: _error,
      rows: _rows,
      columns: const [
        SakalListColumn('Statement No', flex: 2),
        SakalListColumn('Period', flex: 2),
        SakalListColumn('Bank / Account', flex: 3),
        SakalListColumn('Status', flex: 2),
        SakalListColumn('', flex: 1),
      ],
      rowBuilder: _buildRow,
      cardBuilder: _buildCard,
      emptyState: _emptyState(),
    );
  }

  Widget _buildRow(_StatementRow r, int index) {
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r.statementNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${r.periodFrom} → ${r.periodTo}', style: const TextStyle(fontSize: 12)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${r.bankName} — ${r.accountLabel}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _statusBadge(r.status))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary, onPressed: () => _openEdit(r), tooltip: 'Open'))),
        ]),
      ),
    );
  }

  Widget _buildCard(_StatementRow r) {
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.statementNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r.status),
          ]),
          const SizedBox(height: 4),
          Text('${r.bankName} — ${r.accountLabel}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${r.periodFrom} → ${r.periodTo}', style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No bank statements found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Upload a bank statement to start reconciling.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

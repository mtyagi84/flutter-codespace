import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../providers/expense_voucher_providers.dart';

class ExpenseVoucherListScreen extends ConsumerStatefulWidget {
  const ExpenseVoucherListScreen({super.key});

  @override
  ConsumerState<ExpenseVoucherListScreen> createState() => _ExpenseVoucherListScreenState();
}

class _ExpenseVoucherListScreenState extends ConsumerState<ExpenseVoucherListScreen>
    with ScreenPermissionMixin<ExpenseVoucherListScreen> {
  @override
  String get screenName => RouteNames.expenseVoucherList;

  List<Map<String, dynamic>> _vouchers = [];
  Set<String> _pendingIds = {};
  bool _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _searchText = _searchCtrl.text.trim().toLowerCase()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ref.read(expenseVoucherRepositoryProvider).listVouchers(
              clientId: session.clientId, companyId: session.companyId,
              status: _filterStatus, limit: 200,
            ),
        ref.read(syncEngineProvider).pendingDocumentIds('EXPENSE_VOUCHER'),
      ]);
      if (mounted) {
        setState(() {
          _vouchers = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load expense vouchers: $e';
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _vouchers;
    return _vouchers.where((v) {
      final supplier = v['supplier'] as Map<String, dynamic>?;
      return (v['trans_no'] as String? ?? '').toLowerCase().contains(_searchText) ||
          (v['bill_no'] as String? ?? '').toLowerCase().contains(_searchText) ||
          (supplier?['account_name'] as String? ?? '').toLowerCase().contains(_searchText);
    }).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.expenseVoucherEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> v) async {
    await context.push(RouteNames.expenseVoucherEntry, extra: {'transNo': v['trans_no']});
    if (mounted) _load();
  }

  String _displayDate(String? iso) {
    if (iso == null) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  Widget _statusBadge(String status) {
    final isPosted = status == 'APPROVED';
    final color = isPosted ? AppColors.positive : AppColors.badgeDraft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isPosted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(child: Text('Expense Voucher', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary))),
            if (canAdd) FilledButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('New Expense Voucher'), onPressed: _openNew),
          ]),
        ),
        const Divider(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 160,
              child: SakalFieldCard(
                label: 'Status', editable: true,
                child: DropdownButtonFormField<String?>(
                  initialValue: _filterStatus,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: SakalFieldCard.bareDecoration,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All Status')),
                    DropdownMenuItem(value: 'DRAFT', child: Text('Draft')),
                    DropdownMenuItem(value: 'APPROVED', child: Text('Posted')),
                  ],
                  onChanged: (v) { setState(() => _filterStatus = v); _load(); },
                ),
              ),
            ),
            SizedBox(
              width: 280,
              child: SakalFieldCard(
                label: 'Search', editable: true,
                child: TextField(
                  controller: _searchCtrl,
                  decoration: SakalFieldCard.bareDecoration.copyWith(
                    hintText: 'Search voucher no / bill no / supplier…',
                    suffixIcon: _searchText.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear, padding: EdgeInsets.zero, constraints: const BoxConstraints()) : null,
                  ),
                ),
              ),
            ),
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary),
          ]),
        ),
        Expanded(
          child: SakalAdaptiveList<Map<String, dynamic>>(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Voucher No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Supplier', flex: 3),
              SakalListColumn('Bill No', flex: 2),
              SakalListColumn('Status', flex: 2),
              SakalListColumn('', flex: 1),
            ],
            rowBuilder: _buildRow,
            cardBuilder: _buildCard,
            emptyState: _emptyState(),
          ),
        ),
        if (!_loading)
          Padding(padding: const EdgeInsets.fromLTRB(24, 6, 24, 12), child: Text('${rows.length} voucher(s)', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
      ],
    );
  }

  Widget _buildRow(Map<String, dynamic> v, int index) {
    final transNo = v['trans_no'] as String? ?? '';
    final supplier = v['supplier'] as Map<String, dynamic>?;
    final supplierName = supplier != null ? '[${supplier['account_code']}] ${supplier['account_name']}' : '—';
    return InkWell(
      onTap: () => _openEdit(v),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), child: Text(transNo, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(_displayDate(v['trans_date'] as String?), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(supplierName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(v['bill_no'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
            _statusBadge(v['status'] as String? ?? 'DRAFT'),
            if (_pendingIds.contains(transNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary, onPressed: () => _openEdit(v), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> v) {
    final transNo = v['trans_no'] as String? ?? '';
    final supplier = v['supplier'] as Map<String, dynamic>?;
    final supplierName = supplier != null ? '[${supplier['account_code']}] ${supplier['account_name']}' : '—';
    return InkWell(
      onTap: () => _openEdit(v),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(transNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(v['status'] as String? ?? 'DRAFT'),
            if (_pendingIds.contains(transNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text(supplierName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('${_displayDate(v['trans_date'] as String?)} · Bill ${v['bill_no'] ?? '—'}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.textDisabled),
          SizedBox(height: 16),
          Text('No expense vouchers found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          SizedBox(height: 8),
          Text('Record a service bill (electricity, water, internet, ...) in the period it belongs to, and settle it with the supplier later.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ]),
      );
}

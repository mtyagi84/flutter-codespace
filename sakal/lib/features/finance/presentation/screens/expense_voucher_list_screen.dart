import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/paged_list_controller.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../data/models/expense_voucher_model.dart';
import '../providers/expense_voucher_providers.dart';

/// Reference implementation for scroll-triggered pagination — see
/// CLAUDE.md's "Pagination" mandatory pattern. Search is server-side
/// (debounced 350ms) rather than a client-side filter over loaded rows,
/// since a client-side filter would silently miss anything not yet paged in.
class ExpenseVoucherListScreen extends ConsumerStatefulWidget {
  const ExpenseVoucherListScreen({super.key});

  @override
  ConsumerState<ExpenseVoucherListScreen> createState() => _ExpenseVoucherListScreenState();
}

class _ExpenseVoucherListScreenState extends ConsumerState<ExpenseVoucherListScreen>
    with ScreenPermissionMixin<ExpenseVoucherListScreen> {
  @override
  String get screenName => RouteNames.expenseVoucherList;

  late final PagedListController<ExpenseVoucherHeader> _controller;
  UserSession _session() => ref.read(sessionProvider)!;
  Set<String> _pendingIds = {};
  bool _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _controller = PagedListController<ExpenseVoucherHeader>(
      fetchPage: ({required limit, required offset}) => ref.read(expenseVoucherRepositoryProvider).listVouchers(
            clientId: _session().clientId, companyId: _session().companyId,
            status: _filterStatus, search: _searchText.isEmpty ? null : _searchText,
            limit: limit, offset: offset,
          ),
    );
    _searchCtrl.addListener(() {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        setState(() => _searchText = _searchCtrl.text.trim());
        _load();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Started before awaiting loadFirstPage() so both run concurrently,
      // without mixing a Future<void> into a single Future.wait list (an
      // awkward type-inference corner in Dart).
      final pendingIdsFuture = ref.read(syncEngineProvider).pendingDocumentIds('EXPENSE_VOUCHER');
      await _controller.loadFirstPage();
      final pendingIds = await pendingIdsFuture;
      if (mounted) {
        setState(() {
          _pendingIds = pendingIds;
          _loading = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('ExpenseVoucherListLoad', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = ErrorPresenter.format(e, action: 'load expense vouchers');
        });
      }
    }
  }

  Future<void> _loadMore() async {
    try {
      await _controller.loadMore();
      if (mounted) setState(() {});
    } catch (e, st) {
      AppLogger.error('ExpenseVoucherListLoadMore', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorPresenter.format(e, action: 'load more vouchers')), backgroundColor: AppColors.negative),
        );
      }
    }
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.expenseVoucherEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(ExpenseVoucherHeader v) async {
    await context.push(RouteNames.expenseVoucherEntry, extra: {'transNo': v.transNo});
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
    final rows = _controller.items;
    final isMobile = Responsive.isMobile(context);

    final statusField = SakalFieldCard(
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
    );
    final searchField = SakalFieldCard(
      label: 'Search', editable: true,
      child: TextField(
        controller: _searchCtrl,
        decoration: SakalFieldCard.bareDecoration.copyWith(
          hintText: 'Search voucher no / bill no / supplier…',
          suffixIcon: _searchText.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear, padding: EdgeInsets.zero, constraints: const BoxConstraints()) : null,
        ),
      ),
    );
    final refreshButton = IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary);

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
          // A Wrap here doesn't stretch a field to fill leftover row space
          // (see sakal_field_row.dart's own doc comment for this exact
          // gap) — Status alone on its own mobile row would leave a large
          // empty gap to its right. Plain Row/Column instead.
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  statusField,
                  const SizedBox(height: 8),
                  Row(children: [Expanded(child: searchField), const SizedBox(width: 6), refreshButton]),
                ])
              : Row(children: [
                  SizedBox(width: 160, child: statusField),
                  const SizedBox(width: 12),
                  Expanded(child: searchField),
                  const SizedBox(width: 6),
                  refreshButton,
                ]),
        ),
        Expanded(
          child: SakalAdaptiveList<ExpenseVoucherHeader>(
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
            onLoadMore: _loadMore,
            hasMore: _controller.hasMore,
            loadingMore: _controller.isLoadingMore,
          ),
        ),
        if (!_loading)
          Padding(padding: const EdgeInsets.fromLTRB(24, 6, 24, 12), child: Text('${rows.length}${_controller.hasMore ? '+' : ''} voucher(s)', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
      ],
    );
  }

  Widget _buildRow(ExpenseVoucherHeader v, int index) {
    final transNo = v.transNo;
    final supplierName = v.supplierCode.isNotEmpty ? '[${v.supplierCode}] ${v.supplierName}' : '—';
    return InkWell(
      onTap: () => _openEdit(v),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), child: Text(transNo, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(_displayDate(v.transDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(supplierName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(v.billNo.isNotEmpty ? v.billNo : '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
            _statusBadge(v.status),
            if (_pendingIds.contains(transNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary, onPressed: () => _openEdit(v), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(ExpenseVoucherHeader v) {
    final transNo = v.transNo;
    final supplierName = v.supplierCode.isNotEmpty ? '[${v.supplierCode}] ${v.supplierName}' : '—';
    return InkWell(
      onTap: () => _openEdit(v),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(transNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(v.status),
            if (_pendingIds.contains(transNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text(supplierName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('${_displayDate(v.transDate)} · Bill ${v.billNo.isNotEmpty ? v.billNo : '—'}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
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

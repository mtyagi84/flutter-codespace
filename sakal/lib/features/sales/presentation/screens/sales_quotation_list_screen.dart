import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../data/models/sales_quotation_header.dart';
import '../providers/sales_quotation_providers.dart';

class SalesQuotationListScreen extends ConsumerStatefulWidget {
  const SalesQuotationListScreen({super.key});

  @override
  ConsumerState<SalesQuotationListScreen> createState() => _SalesQuotationListScreenState();
}

class _SalesQuotationListScreenState extends ConsumerState<SalesQuotationListScreen>
    with ScreenPermissionMixin<SalesQuotationListScreen>, ScreenHeaderMixin<SalesQuotationListScreen> {
  @override String get screenName => RouteNames.salesQuotations;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Sales Quotation',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Quotation'),
                    onPressed: _openNew,
                  ),
                ),
              ]
            : const [],
      );

  List<SalesQuotationHeader> _rows = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {
    'DRAFT':                AppColors.badgeDraft,
    'APPROVED':             AppColors.positive,
    'SENT':                 AppColors.secondary,
    'ACCEPTED':             AppColors.positive,
    'REJECTED':             AppColors.negative,
    'PARTIALLY_CONVERTED':  AppColors.secondary,
    'CONVERTED':            AppColors.textSecondary,
  };

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
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        ref.read(salesQuotationRepositoryProvider).listQuotations(
          clientId: session.clientId, companyId: session.companyId, status: _filterStatus,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('SALES_QUOTATION'),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<SalesQuotationHeader>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load quotations: $e'; });
    }
  }

  List<SalesQuotationHeader> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) =>
        r.quotationNo.toLowerCase().contains(_searchText) ||
        r.partyName.toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.salesQuotationEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(SalesQuotationHeader r) async {
    await context.push(RouteNames.salesQuotationEntry,
        extra: {'quotationNo': r.quotationNo, 'quotationDate': r.quotationDate});
    if (mounted) _load();
  }

  bool _isExpired(SalesQuotationHeader r) {
    final status = r.status;
    if (status != 'SENT' && status != 'ACCEPTED') return false;
    final validUntil = DateTime.tryParse(r.validUntilDate ?? '');
    return validUntil != null && validUntil.isBefore(DateTime.now());
  }

  String _displayDate(String? iso) {
    if (iso == null) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _statusLabel(String s) => switch (s) {
    'DRAFT' => 'Draft',
    'APPROVED' => 'Approved',
    'SENT' => 'Sent',
    'ACCEPTED' => 'Accepted',
    'REJECTED' => 'Rejected',
    'PARTIALLY_CONVERTED' => 'Partially Converted',
    'CONVERTED' => 'Converted',
    _ => s,
  };

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final rows = _filtered;
    final isMobile = Responsive.isMobile(context);

    final statusField = SakalFieldCard(
      label: 'Status', editable: true,
      child: DropdownButtonFormField<String?>(
        initialValue: _filterStatus,
        isExpanded: true, isDense: true, itemHeight: null,
        decoration: SakalFieldCard.bareDecoration,
        style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
        items: [
          const DropdownMenuItem(value: null, child: Text('All Status')),
          ..._statusColors.keys.map((s) => DropdownMenuItem(value: s, child: Text(_statusLabel(s)))),
        ],
        onChanged: (v) { setState(() => _filterStatus = v); _load(); },
      ),
    );
    final searchField = SakalFieldCard(
      label: 'Search', editable: true,
      child: TextField(
        controller: _searchCtrl,
        style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
        decoration: SakalFieldCard.bareDecoration.copyWith(
          hintText: 'Quotation no / customer…',
          hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
          suffixIcon: _searchText.isNotEmpty
              ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear, padding: EdgeInsets.zero, constraints: const BoxConstraints())
              : null,
        ),
      ),
    );
    final refreshButton = IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary);

    // Title + New Quotation button live in the shared TopBar via
    // ScreenHeaderMixin (see CLAUDE.md's "Screen header" pattern) — not
    // rendered here as body content.
    refreshScreenHeader();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
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
          child: SakalAdaptiveList(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Quotation No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Customer', flex: 3),
              SakalListColumn('Valid Until', flex: 2),
              SakalListColumn('Status', flex: 2),
              SakalListColumn('Grand Total', flex: 2),
              SakalListColumn('', flex: 1),
            ],
            rowBuilder: _buildRow,
            cardBuilder: _buildCard,
            emptyState: _emptyState(),
          ),
        ),
        if (!_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
            child: Text(
              _searchText.isNotEmpty ? '${rows.length} of ${_rows.length} quotation(s)' : '${rows.length} quotation(s)',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _statusBadge(SalesQuotationHeader r) {
    final status = _isExpired(r) ? 'EXPIRED' : r.status;
    final color = status == 'EXPIRED' ? AppColors.negative : (_statusColors[status] ?? AppColors.textSecondary);
    final label = status == 'EXPIRED' ? 'Expired' : _statusLabel(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(SalesQuotationHeader r, int index) {
    final isProspect = r.customerType == 'PROSPECT';
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r.quotationNo, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r.quotationDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Flexible(child: Text(r.partyName.isEmpty ? '—' : r.partyName,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                if (isProspect) const Padding(padding: EdgeInsets.only(left: 6),
                    child: Text('Prospect', style: TextStyle(fontSize: 10, color: AppColors.secondary, fontWeight: FontWeight.w600))),
              ]))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r.validUntilDate),
                  style: TextStyle(fontSize: 13, color: _isExpired(r) ? AppColors.negative : AppColors.textPrimary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                _statusBadge(r),
                if (_pendingIds.contains(r.quotationNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
              ]))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${r.currencyId} ${AppNumberFormat.amount(r.grandTotal, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(SalesQuotationHeader r) {
    final isProspect = r.customerType == 'PROSPECT';
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.quotationNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r),
            if (_pendingIds.contains(r.quotationNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Flexible(child: Text(r.partyName.isEmpty ? '—' : r.partyName,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
            if (isProspect) const Padding(padding: EdgeInsets.only(left: 6),
                child: Text('Prospect', style: TextStyle(fontSize: 10, color: AppColors.secondary, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 4),
          Text('${_displayDate(r.quotationDate)} · Valid until ${_displayDate(r.validUntilDate)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${r.currencyId} ${AppNumberFormat.amount(r.grandTotal, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.request_quote_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No quotations found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a Sales Quotation to get started.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

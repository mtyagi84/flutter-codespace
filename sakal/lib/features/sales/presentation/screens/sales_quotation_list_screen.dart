import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../providers/sales_quotation_providers.dart';

class SalesQuotationListScreen extends ConsumerStatefulWidget {
  const SalesQuotationListScreen({super.key});

  @override
  ConsumerState<SalesQuotationListScreen> createState() => _SalesQuotationListScreenState();
}

class _SalesQuotationListScreenState extends ConsumerState<SalesQuotationListScreen>
    with ScreenPermissionMixin<SalesQuotationListScreen> {
  @override String get screenName => RouteNames.salesQuotations;

  List<Map<String, dynamic>> _rows = [];
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
          _rows       = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load quotations: $e'; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) =>
        (r['quotation_no'] as String? ?? '').toLowerCase().contains(_searchText) ||
        (r['party_name'] as String? ?? '').toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.salesQuotationEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> r) async {
    await context.push(RouteNames.salesQuotationEntry,
        extra: {'quotationNo': r['quotation_no'], 'quotationDate': r['quotation_date']});
    if (mounted) _load();
  }

  bool _isExpired(Map<String, dynamic> r) {
    final status = r['status'] as String;
    if (status != 'SENT' && status != 'ACCEPTED') return false;
    final validUntil = DateTime.tryParse(r['valid_until_date'] as String? ?? '');
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(
              child: Text('Sales Quotation',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Quotation'),
                onPressed: _openNew,
              ),
          ]),
        ),
        const Divider(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String?>(
              value: _filterStatus,
              hint: const Text('All Status', style: TextStyle(fontSize: 13)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Status', style: TextStyle(fontSize: 13))),
                ..._statusColors.keys.map((s) => DropdownMenuItem(value: s, child: Text(_statusLabel(s), style: const TextStyle(fontSize: 13)))),
              ],
              onChanged: (v) { setState(() => _filterStatus = v); _load(); },
            ),
            SizedBox(
              width: 260, height: 36,
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search quotation no / customer…',
                  hintStyle: const TextStyle(fontSize: 12),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                  suffixIcon: _searchText.isNotEmpty
                      ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear)
                      : null,
                ),
              ),
            ),
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary),
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

  Widget _statusBadge(Map<String, dynamic> r) {
    final status = _isExpired(r) ? 'EXPIRED' : r['status'] as String;
    final color = status == 'EXPIRED' ? AppColors.negative : (_statusColors[status] ?? AppColors.textSecondary);
    final label = status == 'EXPIRED' ? 'Expired' : _statusLabel(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(Map<String, dynamic> r, int index) {
    final currency = r['currency'] as Map<String, dynamic>?;
    final isProspect = r['customer_type'] == 'PROSPECT';
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r['quotation_no'] as String, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['quotation_date'] as String?), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Flexible(child: Text(r['party_name'] as String? ?? '—',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                if (isProspect) const Padding(padding: EdgeInsets.only(left: 6),
                    child: Text('Prospect', style: TextStyle(fontSize: 10, color: AppColors.secondary, fontWeight: FontWeight.w600))),
              ]))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['valid_until_date'] as String?),
                  style: TextStyle(fontSize: 13, color: _isExpired(r) ? AppColors.negative : AppColors.textPrimary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                _statusBadge(r),
                if (_pendingIds.contains(r['quotation_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
              ]))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${currency?['currency_id'] ?? ''} ${((r['grand_total'] as num?) ?? 0).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> r) {
    final currency = r['currency'] as Map<String, dynamic>?;
    final isProspect = r['customer_type'] == 'PROSPECT';
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r['quotation_no'] as String,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r),
            if (_pendingIds.contains(r['quotation_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Flexible(child: Text(r['party_name'] as String? ?? '—',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
            if (isProspect) const Padding(padding: EdgeInsets.only(left: 6),
                child: Text('Prospect', style: TextStyle(fontSize: 10, color: AppColors.secondary, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 4),
          Text('${_displayDate(r['quotation_date'] as String?)} · Valid until ${_displayDate(r['valid_until_date'] as String?)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${currency?['currency_id'] ?? ''} ${((r['grand_total'] as num?) ?? 0).toStringAsFixed(2)}',
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

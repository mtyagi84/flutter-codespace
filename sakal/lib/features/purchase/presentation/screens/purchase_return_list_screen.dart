import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../data/models/purchase_return_model.dart';
import '../providers/purchase_return_providers.dart';

class PurchaseReturnListScreen extends ConsumerStatefulWidget {
  const PurchaseReturnListScreen({super.key});

  @override
  ConsumerState<PurchaseReturnListScreen> createState() => _PurchaseReturnListScreenState();
}

class _PurchaseReturnListScreenState extends ConsumerState<PurchaseReturnListScreen>
    with ScreenPermissionMixin<PurchaseReturnListScreen> {
  @override String get screenName => RouteNames.purchaseReturns;

  List<PurchaseReturnModel> _returns = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {
    'DRAFT':    AppColors.badgeDraft,
    'APPROVED': AppColors.positive,
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
        ref.read(purchaseReturnRepositoryProvider).listPurchaseReturns(
          clientId:  session.clientId,
          companyId: session.companyId,
          status:    _filterStatus,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('PURCHASE_RETURN'),
      ]);
      if (mounted) {
        setState(() {
          _returns    = results[0] as List<PurchaseReturnModel>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load purchase returns: $e'; });
    }
  }

  List<PurchaseReturnModel> get _filtered {
    if (_searchText.isEmpty) return _returns;
    return _returns.where((p) =>
        p.returnNo.toLowerCase().contains(_searchText) ||
        (p.supplierName ?? '').toLowerCase().contains(_searchText) ||
        (p.reason ?? '').toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.purchaseReturnEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(PurchaseReturnModel p) async {
    await context.push(RouteNames.purchaseReturnEntry, extra: {'returnNo': p.returnNo, 'returnDate': p.returnDate});
    if (mounted) _load();
  }

  String _displayDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _statusLabel(String s) => switch (s) {
    'DRAFT' => 'Draft',
    'APPROVED' => 'Approved',
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
              child: Text('Purchase Return',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Purchase Return'),
                onPressed: _openNew,
              ),
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
                  style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Status')),
                    ..._statusColors.keys.map((s) => DropdownMenuItem(value: s, child: Text(_statusLabel(s)))),
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
                  style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                  decoration: SakalFieldCard.bareDecoration.copyWith(
                    hintText: 'Search return no / supplier / reason…',
                    hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
                    suffixIcon: _searchText.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear, padding: EdgeInsets.zero, constraints: const BoxConstraints())
                        : null,
                  ),
                ),
              ),
            ),
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary),
          ]),
        ),

        Expanded(
          child: SakalAdaptiveList<PurchaseReturnModel>(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Return No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Supplier', flex: 3),
              SakalListColumn('Reason', flex: 2),
              SakalListColumn('Total', flex: 2),
              SakalListColumn('Status', flex: 2),
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
              _searchText.isNotEmpty ? '${rows.length} of ${_returns.length} return(s)' : '${rows.length} return(s)',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _statusBadge(String status) {
    final color = _statusColors[status] ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(_statusLabel(status),
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(PurchaseReturnModel p, int index) {
    return InkWell(
      onTap: () => _openEdit(p),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(p.returnNo,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_displayDate(p.returnDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(p.supplierName != null ? '[${p.supplierCode}] ${p.supplierName}' : '—',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(p.reason ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('${p.returnCurrencyCode ?? ''} ${p.returnTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              _statusBadge(p.status),
              if (_pendingIds.contains(p.returnNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
            ]))),
          Expanded(flex: 1, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 14),
              color: AppColors.primary,
              onPressed: () => _openEdit(p),
              tooltip: 'Open',
              padding: EdgeInsets.zero,
            ),
          )),
        ]),
      ),
    );
  }

  Widget _buildCard(PurchaseReturnModel p) {
    return InkWell(
      onTap: () => _openEdit(p),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(p.returnNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(p.status),
            if (_pendingIds.contains(p.returnNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text('${p.reason ?? '—'} · ${_displayDate(p.returnDate)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(p.supplierName != null ? '[${p.supplierCode}] ${p.supplierName}' : '—',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text('${p.returnCurrencyCode ?? ''} ${p.returnTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.assignment_return_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No purchase returns found',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Raise a Purchase Return against an approved GRN to get started.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

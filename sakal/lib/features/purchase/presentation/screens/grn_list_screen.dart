import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../data/models/grn_model.dart';
import '../providers/grn_providers.dart';

class GrnListScreen extends ConsumerStatefulWidget {
  const GrnListScreen({super.key});

  @override
  ConsumerState<GrnListScreen> createState() => _GrnListScreenState();
}

class _GrnListScreenState extends ConsumerState<GrnListScreen>
    with ScreenPermissionMixin<GrnListScreen> {
  @override String get screenName => RouteNames.goodsReceipt;

  List<GrnModel> _grns = [];
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
        ref.read(grnRepositoryProvider).listGrns(
          clientId:  session.clientId,
          companyId: session.companyId,
          status:    _filterStatus,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('GRN'),
      ]);
      if (mounted) {
        setState(() {
          _grns       = results[0] as List<GrnModel>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load goods receipts: $e'; });
    }
  }

  List<GrnModel> get _filtered {
    if (_searchText.isEmpty) return _grns;
    return _grns.where((g) =>
        g.grnNo.toLowerCase().contains(_searchText) ||
        (g.supplierName ?? '').toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.grnEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(GrnModel g) async {
    await context.push(RouteNames.grnEntry, extra: {'grnNo': g.grnNo, 'grnDate': g.grnDate});
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
    final isMobile  = Responsive.isMobile(context);
    final rows = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(
              child: Text('Goods Receipt',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Goods Receipt'),
                onPressed: _openNew,
              ),
          ]),
        ),

        const Divider(height: 20),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String?>(
                value: _filterStatus,
                hint: const Text('All Status', style: TextStyle(fontSize: 13)),
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Status', style: TextStyle(fontSize: 13))),
                  ..._statusColors.keys.map((s) => DropdownMenuItem(
                      value: s, child: Text(_statusLabel(s), style: const TextStyle(fontSize: 13)))),
                ],
                onChanged: (v) { setState(() => _filterStatus = v); _load(); },
              ),
              SizedBox(
                width: 240,
                height: 36,
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search GRN no / supplier…',
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
              IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load,
                  tooltip: 'Refresh', color: AppColors.primary),
            ],
          ),
        ),

        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.negative)))
                  : rows.isEmpty
                      ? _emptyState()
                      : isMobile
                          ? ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              itemCount: rows.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (_, i) => _buildCard(rows[i]),
                            )
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                              child: Column(children: [
                                Container(
                                  decoration: const BoxDecoration(
                                    color: AppColors.primary,
                                    borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                                  ),
                                  child: Row(children: [
                                    _th('GRN No',    flex: 2),
                                    _th('Date',      flex: 2),
                                    _th('Mode',      flex: 1),
                                    _th('Supplier',  flex: 3),
                                    _th('Grand Total', flex: 2),
                                    _th('Status',    flex: 2),
                                    _th('',          flex: 1),
                                  ]),
                                ),
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: rows.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
                                    itemBuilder: (_, i) => _buildRow(rows[i], i),
                                  ),
                                ),
                              ]),
                            ),
        ),

        if (!_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
            child: Text(
              _searchText.isNotEmpty ? '${rows.length} of ${_grns.length} receipt(s)' : '${rows.length} receipt(s)',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _th(String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
    ),
  );

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

  Widget _buildRow(GrnModel g, int index) {
    return InkWell(
      onTap: () => _openEdit(g),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(g.grnNo,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary))),
              if (_pendingIds.contains(g.grnNo)) ...[
                const SizedBox(width: 6),
                const PendingSyncBadge.static(isPending: true),
              ],
            ]))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_displayDate(g.grnDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 1, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(g.receiptMode == 'AGAINST_PO' ? 'Against PO' : 'Direct',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)))),
          Expanded(flex: 3, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(g.supplierName != null ? '[${g.supplierCode}] ${g.supplierName}' : '—',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('${g.grnCurrencyCode ?? ''} ${g.grandTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _statusBadge(g.status))),
          Expanded(flex: 1, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 14),
              color: AppColors.primary,
              onPressed: () => _openEdit(g),
              tooltip: 'Open',
              padding: EdgeInsets.zero,
            ),
          )),
        ]),
      ),
    );
  }

  Widget _buildCard(GrnModel g) {
    return InkWell(
      onTap: () => _openEdit(g),
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
            Expanded(child: Text(g.grnNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            if (_pendingIds.contains(g.grnNo)) ...[
              const PendingSyncBadge.static(isPending: true),
              const SizedBox(width: 6),
            ],
            _statusBadge(g.status),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Text(g.receiptMode == 'AGAINST_PO' ? 'Against PO' : 'Direct',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(width: 8),
            const Text('·', style: TextStyle(color: AppColors.textDisabled)),
            const SizedBox(width: 8),
            Text(_displayDate(g.grnDate), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 4),
          Text(g.supplierName != null ? '[${g.supplierCode}] ${g.supplierName}' : '—',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text('${g.grnCurrencyCode ?? ''} ${g.grandTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.inventory_2_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No goods receipts found',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a new goods receipt to get started.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

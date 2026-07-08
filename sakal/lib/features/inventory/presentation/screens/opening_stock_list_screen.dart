import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../providers/opening_stock_providers.dart';

class OpeningStockListScreen extends ConsumerStatefulWidget {
  const OpeningStockListScreen({super.key});

  @override
  ConsumerState<OpeningStockListScreen> createState() => _OpeningStockListScreenState();
}

class _OpeningStockListScreenState extends ConsumerState<OpeningStockListScreen>
    with ScreenPermissionMixin<OpeningStockListScreen> {
  @override String get screenName => RouteNames.openingStock;

  List<Map<String, dynamic>> _rows = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {'DRAFT': AppColors.badgeDraft, 'APPROVED': AppColors.positive};

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
        ref.read(openingStockRepositoryProvider).listOpeningStocks(
          clientId: session.clientId, companyId: session.companyId, status: _filterStatus,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('OPENING_STOCK'),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load opening stock entries: $e'; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) => (r['opening_no'] as String? ?? '').toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.openingStockEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> r) async {
    await context.push(RouteNames.openingStockEntry, extra: {'openingNo': r['opening_no'], 'openingDate': r['opening_date']});
    if (mounted) _load();
  }

  String _displayDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

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
            const Expanded(child: Text('Opening Stock', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary))),
            if (canAdd)
              FilledButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('New Opening Stock'), onPressed: _openNew),
          ]),
        ),
        const Divider(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String?>(
              value: _filterStatus,
              hint: const Text('All Status', style: TextStyle(fontSize: 13)),
              isDense: true, underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Status', style: TextStyle(fontSize: 13))),
                const DropdownMenuItem(value: 'DRAFT', child: Text('Draft', style: TextStyle(fontSize: 13))),
                const DropdownMenuItem(value: 'APPROVED', child: Text('Approved', style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) { setState(() => _filterStatus = v); _load(); },
            ),
            SizedBox(
              width: 260, height: 36,
              child: TextField(
                controller: _searchCtrl, style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search opening no…', hintStyle: const TextStyle(fontSize: 12),
                  prefixIcon: const Icon(Icons.search, size: 16), isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                  suffixIcon: _searchText.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear) : null,
                ),
              ),
            ),
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary),
          ]),
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
                                  decoration: const BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
                                  child: Row(children: [
                                    _th('Opening No', flex: 2), _th('Date', flex: 2), _th('Location', flex: 3), _th('Status', flex: 2), _th('', flex: 1),
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
              _searchText.isNotEmpty
                  ? '${rows.length} of ${_rows.length} ${_rows.length == 1 ? 'entry' : 'entries'}'
                  : '${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _th(String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12))),
  );

  Widget _statusBadge(String status) {
    final color = _statusColors[status] ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(status == 'DRAFT' ? 'Draft' : 'Approved', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(Map<String, dynamic> r, int index) {
    final location = r['location'] as Map<String, dynamic>?;
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r['opening_no'] as String, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['opening_date'] as String), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(location?['location_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['opening_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> r) {
    final location = r['location'] as Map<String, dynamic>?;
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r['opening_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['opening_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text(_displayDate(r['opening_date'] as String), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(location?['location_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.inventory_2_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No opening stock entries found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create an Opening Stock entry to establish starting quantity and cost before go-live.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

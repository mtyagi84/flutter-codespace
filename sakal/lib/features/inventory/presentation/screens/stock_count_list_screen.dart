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
import '../providers/stock_count_providers.dart';

class StockCountListScreen extends ConsumerStatefulWidget {
  const StockCountListScreen({super.key});

  @override
  ConsumerState<StockCountListScreen> createState() => _StockCountListScreenState();
}

class _StockCountListScreenState extends ConsumerState<StockCountListScreen>
    with ScreenPermissionMixin<StockCountListScreen> {
  @override String get screenName => RouteNames.stockCount;

  List<Map<String, dynamic>> _rows = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {'DRAFT': AppColors.badgeDraft, 'SUBMITTED': AppColors.secondary, 'CONSOLIDATED': AppColors.positive};

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
        ref.read(stockCountRepositoryProvider).listStockCounts(
          clientId: session.clientId, companyId: session.companyId, status: _filterStatus,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('STOCK_COUNT'),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load stock counts: $e'; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) => (r['count_no'] as String? ?? '').toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.stockCountEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> r) async {
    await context.push(RouteNames.stockCountEntry, extra: {'countNo': r['count_no'], 'countDate': r['count_date']});
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
    final rows = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(child: Text('Stock Count', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary))),
            if (canAdd)
              FilledButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('New Stock Count'), onPressed: _openNew),
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
              items: const [
                DropdownMenuItem(value: null, child: Text('All Status', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'DRAFT', child: Text('Draft', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'SUBMITTED', child: Text('Submitted', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'CONSOLIDATED', child: Text('Consolidated', style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) { setState(() => _filterStatus = v); _load(); },
            ),
            SizedBox(
              width: 260, height: 36,
              child: TextField(
                controller: _searchCtrl, style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search count no…', hintStyle: const TextStyle(fontSize: 12),
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
          child: SakalAdaptiveList(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Count No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Location', flex: 3),
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
              _searchText.isNotEmpty
                  ? '${rows.length} of ${_rows.length} ${_rows.length == 1 ? 'count' : 'counts'}'
                  : '${rows.length} ${rows.length == 1 ? 'count' : 'counts'}',
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
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
              child: Text(r['count_no'] as String, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['count_date'] as String), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(location?['location_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['count_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
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
            Expanded(child: Text(r['count_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['count_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text(_displayDate(r['count_date'] as String), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(location?['location_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.checklist_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No stock counts found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Start a Stock Count to record a physical count for a location.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

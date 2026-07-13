import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../providers/price_master_providers.dart';

class PriceMasterListScreen extends ConsumerStatefulWidget {
  const PriceMasterListScreen({super.key});

  @override
  ConsumerState<PriceMasterListScreen> createState() => _PriceMasterListScreenState();
}

class _PriceMasterListScreenState extends ConsumerState<PriceMasterListScreen>
    with ScreenPermissionMixin<PriceMasterListScreen> {
  @override String get screenName => RouteNames.salesPriceMaster;

  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _locations = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  String? _filterPriceType;
  String? _filterLocationId;
  DateTime? _effFrom;
  DateTime? _effTo;
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
        ref.read(priceMasterRepositoryProvider).listBatches(
          clientId: session.clientId, companyId: session.companyId,
          status: _filterStatus, priceType: _filterPriceType, locationId: _filterLocationId,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('PRICE_MASTER'),
        ref.read(locationsProvider.future),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _locations  = results[2] as List<Map<String, dynamic>>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load price batches: $e'; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    var result = _rows;
    if (_searchText.isNotEmpty) {
      result = result.where((r) {
        final customer = r['customer'] as Map<String, dynamic>?;
        return (r['entry_no'] as String).toLowerCase().contains(_searchText) ||
            (customer?['account_name'] as String? ?? '').toLowerCase().contains(_searchText);
      }).toList();
    }
    if (_effFrom != null) {
      result = result.where((r) {
        final d = DateTime.tryParse(r['effective_date'] as String? ?? '');
        return d != null && !d.isBefore(_effFrom!);
      }).toList();
    }
    if (_effTo != null) {
      result = result.where((r) {
        final d = DateTime.tryParse(r['effective_date'] as String? ?? '');
        return d != null && !d.isAfter(_effTo!);
      }).toList();
    }
    return result;
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.salesPriceMasterEntry);
    if (mounted) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> r) async {
    await context.push(RouteNames.salesPriceMasterEntry,
        extra: {'entryNo': r['entry_no'], 'entryDate': r['entry_date']});
    if (mounted) _load();
  }

  bool _isFutureEffective(Map<String, dynamic> r) {
    final d = DateTime.tryParse(r['effective_date'] as String? ?? '');
    return d != null && d.isAfter(DateTime.now());
  }

  String _displayDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  Future<void> _pickEffFilterDate(DateTime? current, ValueChanged<DateTime?> onPicked) async {
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d != null) onPicked(d);
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
            const Expanded(
              child: Text('Sales Price Master',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Batch'),
                onPressed: _openNew,
              ),
          ]),
        ),
        const Divider(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String?>(
              value: _filterPriceType,
              hint: const Text('All Types', style: TextStyle(fontSize: 13)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: null, child: Text('All Types', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'GENERIC', child: Text('Generic', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'CUSTOMER', child: Text('Customer-Specific', style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) { setState(() => _filterPriceType = v); _load(); },
            ),
            DropdownButton<String?>(
              value: _filterStatus,
              hint: const Text('All Status', style: TextStyle(fontSize: 13)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: null, child: Text('All Status', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'DRAFT', child: Text('Draft', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'APPROVED', child: Text('Approved', style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) { setState(() => _filterStatus = v); _load(); },
            ),
            DropdownButton<String?>(
              value: _filterLocationId,
              hint: const Text('All Locations', style: TextStyle(fontSize: 13)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Locations', style: TextStyle(fontSize: 13))),
                ..._locations.map((l) => DropdownMenuItem(
                    value: l['id'] as String,
                    child: Text(l['location_name'] as String, style: const TextStyle(fontSize: 13)))),
              ],
              onChanged: (v) { setState(() => _filterLocationId = v); _load(); },
            ),
            InkWell(
              onTap: () => _pickEffFilterDate(_effFrom, (d) => setState(() => _effFrom = d)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(6)),
                child: Text(_effFrom != null ? 'Eff. From ${_displayDate(_fmtDate(_effFrom!))}' : 'Eff. From',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            InkWell(
              onTap: () => _pickEffFilterDate(_effTo, (d) => setState(() => _effTo = d)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(6)),
                child: Text(_effTo != null ? 'Eff. To ${_displayDate(_fmtDate(_effTo!))}' : 'Eff. To',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            if (_effFrom != null || _effTo != null)
              IconButton(icon: const Icon(Icons.clear, size: 16), tooltip: 'Clear date filter',
                  onPressed: () => setState(() { _effFrom = null; _effTo = null; })),
            SizedBox(
              width: 260, height: 36,
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search entry no / customer…',
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
              SakalListColumn('Entry No', flex: 2),
              SakalListColumn('Location', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Type', flex: 2),
              SakalListColumn('Customer', flex: 3),
              SakalListColumn('Currency', flex: 1),
              SakalListColumn('Effective Date', flex: 2),
              SakalListColumn('Status', flex: 2),
              SakalListColumn('Lines', flex: 1),
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
              _searchText.isNotEmpty || _effFrom != null || _effTo != null
                  ? '${rows.length} of ${_rows.length} batch(es)' : '${rows.length} batch(es)',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _statusBadge(String status) {
    final color = _statusColors[status] ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(status == 'DRAFT' ? 'Draft' : 'Approved', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _typeBadge(String priceType) {
    final isGeneric = priceType == 'GENERIC';
    final color = isGeneric ? AppColors.primary : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isGeneric ? 'Generic' : 'Customer', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(Map<String, dynamic> r, int index) {
    final customer = r['customer'] as Map<String, dynamic>?;
    final location = r['location'] as Map<String, dynamic>?;
    final currency = r['currency'] as Map<String, dynamic>?;
    final customerLabel = r['price_type'] == 'CUSTOMER' && customer != null
        ? '[${customer['account_code']}] ${customer['account_name']}' : '—';
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r['entry_no'] as String, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(location?['location_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['entry_date'] as String?), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _typeBadge(r['price_type'] as String? ?? 'GENERIC'))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(customerLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(currency?['currency_id'] as String? ?? '—', style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['effective_date'] as String?),
                  style: TextStyle(fontSize: 13, color: _isFutureEffective(r) ? AppColors.secondary : AppColors.textPrimary,
                      fontWeight: _isFutureEffective(r) ? FontWeight.w600 : FontWeight.w400)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                _statusBadge(r['status'] as String),
                if (_pendingIds.contains(r['entry_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
              ]))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${r['line_count'] ?? 0}', style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> r) {
    final customer = r['customer'] as Map<String, dynamic>?;
    final location = r['location'] as Map<String, dynamic>?;
    final currency = r['currency'] as Map<String, dynamic>?;
    final customerLabel = r['price_type'] == 'CUSTOMER' && customer != null
        ? '[${customer['account_code']}] ${customer['account_name']}' : 'Generic (all customers)';
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r['entry_no'] as String,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _typeBadge(r['price_type'] as String? ?? 'GENERIC'),
            const SizedBox(width: 6),
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['entry_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text('${location?['location_name'] as String? ?? '—'}  ·  ${currency?['currency_id'] as String? ?? '—'}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(customerLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text('${_displayDate(r['entry_date'] as String?)} · Effective ${_displayDate(r['effective_date'] as String?)}',
              style: TextStyle(fontSize: 12, color: _isFutureEffective(r) ? AppColors.secondary : AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${r['line_count'] ?? 0} line(s)', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.sell_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No price batches found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a Sales Price Master batch to get started.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

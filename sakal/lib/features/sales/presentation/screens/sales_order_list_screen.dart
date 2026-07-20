import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../providers/sales_order_providers.dart';

class SalesOrderListScreen extends ConsumerStatefulWidget {
  const SalesOrderListScreen({super.key});

  @override
  ConsumerState<SalesOrderListScreen> createState() => _SalesOrderListScreenState();
}

class _SalesOrderListScreenState extends ConsumerState<SalesOrderListScreen>
    with ScreenPermissionMixin<SalesOrderListScreen> {
  @override String get screenName => RouteNames.salesOrders;

  List<Map<String, dynamic>> _rows = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  String? _filterMode;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {
    'DRAFT':               AppColors.badgeDraft,
    'APPROVED':            AppColors.positive,
    'PARTIALLY_DELIVERED': AppColors.secondary,
    'DELIVERED':           AppColors.textSecondary,
    'CANCELLED':           AppColors.negative,
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
        ref.read(salesOrderRepositoryProvider).listOrders(
          clientId: session.clientId, companyId: session.companyId,
          status: _filterStatus, orderMode: _filterMode,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('SALES_ORDER'),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load orders: $e'; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) {
      final customer = r['customer'] as Map<String, dynamic>?;
      return (r['order_no'] as String? ?? '').toLowerCase().contains(_searchText) ||
          (customer?['account_name'] as String? ?? '').toLowerCase().contains(_searchText) ||
          (r['customer_po_ref'] as String? ?? '').toLowerCase().contains(_searchText);
    }).toList();
  }

  Future<void> _openEdit(Map<String, dynamic> r) async {
    await context.push(RouteNames.salesOrderEntry,
        extra: {'orderNo': r['order_no'], 'orderDate': r['order_date']});
    if (mounted) _load();
  }

  Future<void> _openNew() async {
    final mode = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('New Sales Order'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop('DIRECT'),
            child: const ListTile(
              leading: Icon(Icons.edit_note, color: AppColors.primary),
              title: Text('Direct Order'),
              subtitle: Text('No quotation — enter customer and lines directly'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop('AGAINST_QUOTATION'),
            child: const ListTile(
              leading: Icon(Icons.request_quote_outlined, color: AppColors.primary),
              title: Text('Against Quotation'),
              subtitle: Text('Convert an approved quotation into an order'),
            ),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    if (mode == 'DIRECT') {
      await context.push(RouteNames.salesOrderEntry, extra: {'newOrderMode': 'DIRECT'});
      if (mounted) _load();
      return;
    }

    final picked = await _pickQuotation();
    if (picked == null || !mounted) return;
    await context.push(RouteNames.salesOrderEntry, extra: {
      'newOrderMode': 'AGAINST_QUOTATION',
      'sourceQuotationNo':   picked['quotation_no'],
      'sourceQuotationDate': picked['quotation_date'],
    });
    if (mounted) _load();
  }

  Future<Map<String, dynamic>?> _pickQuotation() async {
    final session = ref.read(sessionProvider)!;
    List<Map<String, dynamic>> quotations = [];
    String? loadError;
    try {
      quotations = await ref.read(salesOrderRepositoryProvider).getConvertibleQuotations(
        clientId: session.clientId, companyId: session.companyId,
      );
    } catch (e) {
      loadError = '$e';
    }
    if (!mounted) return null;

    if (loadError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load quotations: $loadError'), backgroundColor: AppColors.negative),
      );
      return null;
    }
    if (quotations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No approved, unexpired quotations with remaining quantity are available to convert.'),
            backgroundColor: AppColors.secondary),
      );
      return null;
    }

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Select a Sales Quotation'),
        children: quotations.map((q) {
          final customer = q['customer'] as Map<String, dynamic>?;
          final isProspect = q['customer_type'] == 'PROSPECT';
          final party = isProspect ? (q['party_name'] as String? ?? '') : (customer?['account_name'] as String? ?? '');
          return SimpleDialogOption(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(q),
            child: ListTile(
              title: Text('${q['quotation_no']}'),
              subtitle: Text('$party${isProspect ? ' (Prospect)' : ''} · Valid until ${q['valid_until_date']}'),
              trailing: Text('${q['status']}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _displayDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _statusLabel(String s) => switch (s) {
    'DRAFT' => 'Draft',
    'APPROVED' => 'Approved',
    'PARTIALLY_DELIVERED' => 'Partially Delivered',
    'DELIVERED' => 'Delivered',
    'CANCELLED' => 'Cancelled',
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
              child: Text('Sales Order',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Order'),
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
                label: 'Mode', editable: true,
                child: DropdownButtonFormField<String?>(
                  initialValue: _filterMode,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: SakalFieldCard.bareDecoration,
                  style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All Modes')),
                    DropdownMenuItem(value: 'DIRECT', child: Text('Direct')),
                    DropdownMenuItem(value: 'AGAINST_QUOTATION', child: Text('Against Quotation')),
                  ],
                  onChanged: (v) { setState(() => _filterMode = v); _load(); },
                ),
              ),
            ),
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
                    hintText: 'Order no / customer / PO ref…',
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
          child: SakalAdaptiveList(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Order No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Mode', flex: 2),
              SakalListColumn('Customer', flex: 3),
              SakalListColumn('Quotation', flex: 2),
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
              _searchText.isNotEmpty ? '${rows.length} of ${_rows.length} order(s)' : '${rows.length} order(s)',
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
      child: Text(_statusLabel(status), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _modeBadge(String mode) {
    final isDirect = mode == 'DIRECT';
    final color = isDirect ? AppColors.primary : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isDirect ? 'Direct' : 'Against SQ', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(Map<String, dynamic> r, int index) {
    final customer = r['customer'] as Map<String, dynamic>?;
    final currency = r['currency'] as Map<String, dynamic>?;
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r['order_no'] as String, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r['order_date'] as String?), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _modeBadge(r['order_mode'] as String? ?? 'DIRECT'))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(customer?['account_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r['source_quotation_no'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                _statusBadge(r['status'] as String),
                if (_pendingIds.contains(r['order_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
              ]))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('${currency?['currency_id'] ?? ''} ${AppNumberFormat.amount((r['grand_total'] as num?) ?? 0, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> r) {
    final customer = r['customer'] as Map<String, dynamic>?;
    final currency = r['currency'] as Map<String, dynamic>?;
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r['order_no'] as String,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _modeBadge(r['order_mode'] as String? ?? 'DIRECT'),
            const SizedBox(width: 6),
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['order_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text(customer?['account_name'] as String? ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          if ((r['source_quotation_no'] as String?)?.isNotEmpty ?? false) ...[
            const SizedBox(height: 4),
            Text('From ${r['source_quotation_no']}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
          const SizedBox(height: 4),
          Text(_displayDate(r['order_date'] as String?), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${currency?['currency_id'] ?? ''} ${AppNumberFormat.amount((r['grand_total'] as num?) ?? 0, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.shopping_cart_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No sales orders found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a Sales Order to get started.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

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
import '../../data/models/sales_order_header.dart';
import '../providers/sales_order_providers.dart';

class SalesOrderListScreen extends ConsumerStatefulWidget {
  const SalesOrderListScreen({super.key});

  @override
  ConsumerState<SalesOrderListScreen> createState() => _SalesOrderListScreenState();
}

class _SalesOrderListScreenState extends ConsumerState<SalesOrderListScreen>
    with ScreenPermissionMixin<SalesOrderListScreen>, ScreenHeaderMixin<SalesOrderListScreen> {
  @override String get screenName => RouteNames.salesOrders;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Sales Order',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Order'),
                    onPressed: _openNew,
                  ),
                ),
              ]
            : const [],
      );

  List<SalesOrderHeader> _rows = [];
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

  // See ExpenseVoucherListScreen's identical fix — a screen covered by a
  // push stays mounted (never disposed/rebuilt) while covered, so relying
  // solely on the entry screen's own `await context.push(...) => _load()`
  // missed some real navigation paths back to this list. Overriding
  // didPopNext() (already subscribed via ScreenHeaderMixin) makes the
  // refresh unconditional on any return to this screen.
  @override
  void didPopNext() {
    super.didPopNext();
    _load();
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
          _rows       = results[0] as List<SalesOrderHeader>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load orders: $e'; });
    }
  }

  List<SalesOrderHeader> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) =>
        r.orderNo.toLowerCase().contains(_searchText) ||
        r.customerName.toLowerCase().contains(_searchText) ||
        r.customerPoRef.toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openEdit(SalesOrderHeader r) async {
    await context.push(RouteNames.salesOrderEntry,
        extra: {'orderNo': r.orderNo, 'orderDate': r.orderDate});
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
    // Title + New Order button live in the shared TopBar via
    // ScreenHeaderMixin (see CLAUDE.md's "Screen header" pattern) — not
    // rendered here as body content.
    refreshScreenHeader();
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final rows = _filtered;
    final isMobile = Responsive.isMobile(context);

    final modeField = SakalFieldCard(
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
    );
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
          hintText: 'Order no / customer / PO ref…',
          hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
          suffixIcon: _searchText.isNotEmpty
              ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear, padding: EdgeInsets.zero, constraints: const BoxConstraints())
              : null,
        ),
      ),
    );
    final refreshButton = IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [Expanded(child: modeField), const SizedBox(width: 8), Expanded(child: statusField)]),
                  const SizedBox(height: 8),
                  Row(children: [Expanded(child: searchField), const SizedBox(width: 6), refreshButton]),
                ])
              : Row(children: [
                  SizedBox(width: 160, child: modeField),
                  const SizedBox(width: 12),
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

  Widget _buildRow(SalesOrderHeader r, int index) {
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r.orderNo, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(r.orderDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _modeBadge(r.orderMode))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.customerName.isEmpty ? '—' : r.customerName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.sourceQuotationNo ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                _statusBadge(r.status),
                if (_pendingIds.contains(r.orderNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
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

  Widget _buildCard(SalesOrderHeader r) {
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.orderNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _modeBadge(r.orderMode),
            const SizedBox(width: 6),
            _statusBadge(r.status),
            if (_pendingIds.contains(r.orderNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
          ]),
          const SizedBox(height: 6),
          Text(r.customerName.isEmpty ? '—' : r.customerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          if (r.sourceQuotationNo?.isNotEmpty ?? false) ...[
            const SizedBox(height: 4),
            Text('From ${r.sourceQuotationNo}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
          const SizedBox(height: 4),
          Text(_displayDate(r.orderDate), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${r.currencyId} ${AppNumberFormat.amount(r.grandTotal, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
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

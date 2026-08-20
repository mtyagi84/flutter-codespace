import 'dart:async';

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
import '../../data/models/sales_invoice_header.dart';
import '../providers/sales_invoice_providers.dart';
import '../providers/sales_delivery_providers.dart';

/// Credit Sales Invoice's own dedicated list — a new, separate screen from
/// Quick Invoice's own SalesInvoiceListScreen (migration 146), sharing the
/// same underlying rih_sales_invoices table/repository, filtered to
/// sale_type='CREDIT' only. No Type filter here (unlike the Quick Invoice
/// list) since every row on this screen is already Credit by construction.
class CreditSalesInvoiceListScreen extends ConsumerStatefulWidget {
  const CreditSalesInvoiceListScreen({super.key});

  @override
  ConsumerState<CreditSalesInvoiceListScreen> createState() => _CreditSalesInvoiceListScreenState();
}

class _CreditSalesInvoiceListScreenState extends ConsumerState<CreditSalesInvoiceListScreen>
    with ScreenPermissionMixin<CreditSalesInvoiceListScreen>, ScreenHeaderMixin<CreditSalesInvoiceListScreen> {
  @override String get screenName => RouteNames.creditSalesInvoices;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Credit Sales Invoice',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Invoice'),
                    onPressed: _openNew,
                  ),
                ),
              ]
            : const [],
      );

  List<SalesInvoiceHeader> _rows = [];
  Set<String> _pendingIds = {};
  Map<String, String> _deliveryStatusByInvoice = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {
    'DRAFT':     AppColors.badgeDraft,
    'APPROVED':  AppColors.positive,
    'CANCELLED': AppColors.negative,
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
        ref.read(salesInvoiceRepositoryProvider).listInvoices(
          clientId: session.clientId, companyId: session.companyId,
          status: _filterStatus, saleType: 'CREDIT',
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('SALES_INVOICE'),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<SalesInvoiceHeader>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
      unawaited(_loadDeliveryStatuses(session));
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load invoices: $e'; });
    }
  }

  /// Read-only Pending/Partially Delivered/Delivered badge for DEFERRED-
  /// dispatch invoices, sourced from v_sales_invoice_delivery_status — every
  /// Credit Sales Invoice is DEFERRED by construction (migration 146), so
  /// this badge is always relevant here, unlike Quick Invoice where it only
  /// applies to companies configured for deferred dispatch.
  Future<void> _loadDeliveryStatuses(UserSession session) async {
    final invoiceNos = _rows.map((r) => r.invoiceNo).toList();
    if (invoiceNos.isEmpty) return;
    try {
      final rows = await ref.read(salesDeliveryRepositoryProvider).getDeliveryStatusForInvoices(
        clientId: session.clientId, companyId: session.companyId, invoiceNos: invoiceNos,
      );
      if (mounted) {
        setState(() => _deliveryStatusByInvoice = {
          for (final r in rows) r['invoice_no'] as String: r['delivery_status'] as String,
        });
      }
    } catch (_) { /* best-effort */ }
  }

  Widget? _deliveryStatusBadge(String? invoiceNo) {
    final status = _deliveryStatusByInvoice[invoiceNo];
    if (status == null) return null;
    final color = switch (status) {
      'DELIVERED' => AppColors.positive,
      'PARTIALLY_DELIVERED' => AppColors.primary,
      _ => AppColors.secondary, // PENDING
    };
    final label = switch (status) {
      'DELIVERED' => 'Delivered',
      'PARTIALLY_DELIVERED' => 'Partially Delivered',
      _ => 'Pending Delivery',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  List<SalesInvoiceHeader> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) =>
        r.invoiceNo.toLowerCase().contains(_searchText) ||
        r.customerName.toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _openEdit(SalesInvoiceHeader r) async {
    await context.push(RouteNames.creditSalesInvoiceEntry,
        extra: {'invoiceNo': r.invoiceNo, 'invoiceDate': r.invoiceDate});
    if (mounted) _load();
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.creditSalesInvoiceEntry, extra: {'newInvoiceMode': 'DIRECT'});
    if (mounted) _load();
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
    'CANCELLED' => 'Cancelled',
    _ => s,
  };

  @override
  Widget build(BuildContext context) {
    // Title + New Invoice button live in the shared TopBar via
    // ScreenHeaderMixin (see CLAUDE.md's "Screen header" pattern) — not
    // rendered here as body content.
    refreshScreenHeader();
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
          hintText: 'Invoice no / customer…',
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
                  Row(children: [Expanded(child: statusField), const SizedBox(width: 8), Expanded(child: searchField)]),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: refreshButton),
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
              SakalListColumn('Invoice No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Customer', flex: 3),
              SakalListColumn('Status', flex: 2),
              SakalListColumn('Grand Total', flex: 2, numeric: true),
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
              _searchText.isNotEmpty ? '${rows.length} of ${_rows.length} invoice(s)' : '${rows.length} invoice(s)',
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
      child: Text(_statusLabel(status), maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  // Row height is an explicit SizedBox, not padding-derived — the density
  // toggle asks for an exact 40.0/54.0px row height, not an approximation
  // via vertical padding. Horizontal cell padding also scales with density
  // (12.0 dense / 18.0 comfortable) per the same spec.
  Widget _buildRow(SalesInvoiceHeader r, int index) {
    final metrics = DensityMetrics.of(ref.watch(isCompactDensityProvider));
    final hPad = metrics.margin;
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        height: metrics.rowHeight,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text(r.invoiceNo, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text(_displayDate(r.invoiceDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 3, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text(r.customerName.isEmpty ? '—' : r.customerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Row(children: [
                _statusBadge(r.status),
                if (_pendingIds.contains(r.invoiceNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
                if (_deliveryStatusByInvoice[r.invoiceNo] != null) ...[const SizedBox(width: 6), _deliveryStatusBadge(r.invoiceNo)!],
              ]))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text('${r.currencyId} ${AppNumberFormat.amount(r.grandTotal, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)))),
          Expanded(flex: 1, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad * 2 / 3),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(SalesInvoiceHeader r) {
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.invoiceNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(r.status),
            if (_pendingIds.contains(r.invoiceNo)) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
            if (_deliveryStatusByInvoice[r.invoiceNo] != null) ...[const SizedBox(width: 6), _deliveryStatusBadge(r.invoiceNo)!],
          ]),
          const SizedBox(height: 6),
          Text(r.customerName.isEmpty ? '—' : r.customerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text(_displayDate(r.invoiceDate), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${r.currencyId} ${AppNumberFormat.amount(r.grandTotal, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No credit invoices found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a Credit Sales Invoice to get started.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

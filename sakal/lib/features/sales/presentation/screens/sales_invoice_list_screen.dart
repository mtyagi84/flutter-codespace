import 'dart:async';

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
import '../providers/sales_invoice_providers.dart';
import '../providers/sales_delivery_providers.dart';

class SalesInvoiceListScreen extends ConsumerStatefulWidget {
  const SalesInvoiceListScreen({super.key});

  @override
  ConsumerState<SalesInvoiceListScreen> createState() => _SalesInvoiceListScreenState();
}

class _SalesInvoiceListScreenState extends ConsumerState<SalesInvoiceListScreen>
    with ScreenPermissionMixin<SalesInvoiceListScreen> {
  @override String get screenName => RouteNames.salesInvoices;

  List<Map<String, dynamic>> _rows = [];
  Set<String> _pendingIds = {};
  Map<String, String> _deliveryStatusByInvoice = {};
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  String? _filterSaleType;
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
          status: _filterStatus, saleType: _filterSaleType,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('SALES_INVOICE'),
      ]);
      if (mounted) {
        setState(() {
          _rows       = results[0] as List<Map<String, dynamic>>;
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
  /// dispatch invoices, sourced from v_sales_invoice_delivery_status — no
  /// new invoice column, best-effort (a failed fetch just leaves the badge
  /// off, never blocks the list itself from rendering).
  Future<void> _loadDeliveryStatuses(UserSession session) async {
    final deferredInvoiceNos = _rows
        .where((r) => r['stock_dispatch_mode'] == 'DEFERRED')
        .map((r) => r['invoice_no'] as String)
        .toList();
    if (deferredInvoiceNos.isEmpty) return;
    try {
      final rows = await ref.read(salesDeliveryRepositoryProvider).getDeliveryStatusForInvoices(
        clientId: session.clientId, companyId: session.companyId, invoiceNos: deferredInvoiceNos,
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

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) {
      final customer = r['customer'] as Map<String, dynamic>?;
      return (r['invoice_no'] as String? ?? '').toLowerCase().contains(_searchText) ||
          (customer?['account_name'] as String? ?? '').toLowerCase().contains(_searchText) ||
          (r['party_name'] as String? ?? '').toLowerCase().contains(_searchText);
    }).toList();
  }

  Future<void> _openEdit(Map<String, dynamic> r) async {
    await context.push(RouteNames.salesInvoiceEntry,
        extra: {'invoiceNo': r['invoice_no'], 'invoiceDate': r['invoice_date']});
    if (mounted) _load();
  }

  // Mode selection (Direct/Against Quotation/Against Order) used to be an
  // upfront dialog here before the entry screen ever opened — moved onto
  // the entry screen itself as an inline, always-switchable selector
  // (matches the Cash/Credit toggle right next to it) so "New Invoice"
  // just opens the fast-entry screen directly, no forced choice first.
  Future<void> _openNew() async {
    await context.push(RouteNames.salesInvoiceEntry, extra: {'newInvoiceMode': 'DIRECT'});
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
              child: Text('Quick Invoice',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Invoice'),
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
                label: 'Type', editable: true,
                child: DropdownButtonFormField<String?>(
                  initialValue: _filterSaleType,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: SakalFieldCard.bareDecoration,
                  style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All Types')),
                    DropdownMenuItem(value: 'CASH', child: Text('Cash')),
                    DropdownMenuItem(value: 'CREDIT', child: Text('Credit')),
                  ],
                  onChanged: (v) { setState(() => _filterSaleType = v); _load(); },
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
                    hintText: 'Invoice no / customer…',
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
              SakalListColumn('Invoice No', flex: 2),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Type', flex: 2),
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

  // maxLines:1 + softWrap:false — a badge Container has no explicit width
  // (sizes to its own content, by design, a "chip" that hugs its text) but
  // a narrow flex-allotted column can still hand it less width than
  // "Credit" needs, and without this a Text defaults to wrapping onto a
  // second line inside the badge rather than the badge simply staying its
  // natural width — a real screenshot caught "Credit" wrapping into
  // "Credi"/"t". Widened the Type column's own flex share too (a belt-and-
  // suspenders fix, not a replacement for this one).
  Widget _saleTypeBadge(String saleType) {
    final isCash = saleType == 'CASH';
    final color = isCash ? AppColors.positive : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isCash ? 'Cash' : 'Credit', maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  // Row height is an explicit SizedBox, not padding-derived — the density
  // toggle asks for an exact 40.0/54.0px row height, not an approximation
  // via vertical padding. Horizontal cell padding also scales with density
  // (12.0 dense / 18.0 comfortable) per the same spec.
  Widget _buildRow(Map<String, dynamic> r, int index) {
    final customer = r['customer'] as Map<String, dynamic>?;
    final currency = r['currency'] as Map<String, dynamic>?;
    final partyName = customer?['account_name'] as String? ?? r['party_name'] as String? ?? '—';
    final metrics = DensityMetrics.of(ref.watch(isCompactDensityProvider));
    final hPad = metrics.margin;
    return InkWell(
      onTap: () => _openEdit(r),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        height: metrics.rowHeight,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text(r['invoice_no'] as String, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text(_displayDate(r['invoice_date'] as String?), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: _saleTypeBadge(r['sale_type'] as String? ?? 'CASH'))),
          Expanded(flex: 3, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text(partyName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Row(children: [
                _statusBadge(r['status'] as String),
                if (_pendingIds.contains(r['invoice_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
                if (_deliveryStatusByInvoice[r['invoice_no']] != null) ...[const SizedBox(width: 6), _deliveryStatusBadge(r['invoice_no'] as String?)!],
              ]))),
          Expanded(flex: 2, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad),
              child: Text('${currency?['currency_id'] ?? ''} ${AppNumberFormat.amount((r['grand_total'] as num?) ?? 0, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)))),
          Expanded(flex: 1, child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad * 2 / 3),
              child: IconButton(icon: const Icon(Icons.arrow_forward_ios, size: 14), color: AppColors.primary,
                  onPressed: () => _openEdit(r), tooltip: 'Open', padding: EdgeInsets.zero))),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> r) {
    final customer = r['customer'] as Map<String, dynamic>?;
    final currency = r['currency'] as Map<String, dynamic>?;
    final partyName = customer?['account_name'] as String? ?? r['party_name'] as String? ?? '—';
    return InkWell(
      onTap: () => _openEdit(r),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r['invoice_no'] as String,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _saleTypeBadge(r['sale_type'] as String? ?? 'CASH'),
            const SizedBox(width: 6),
            _statusBadge(r['status'] as String),
            if (_pendingIds.contains(r['invoice_no'])) ...[const SizedBox(width: 6), const PendingSyncBadge.static(isPending: true)],
            if (_deliveryStatusByInvoice[r['invoice_no']] != null) ...[const SizedBox(width: 6), _deliveryStatusBadge(r['invoice_no'] as String?)!],
          ]),
          const SizedBox(height: 6),
          Text(partyName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text(_displayDate(r['invoice_date'] as String?), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text('${currency?['currency_id'] ?? ''} ${AppNumberFormat.amount((r['grand_total'] as num?) ?? 0, ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL')}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.point_of_sale_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No invoices found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a Quick Invoice to get started.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

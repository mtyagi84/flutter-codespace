import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/datasources/purchase_order_remote_ds.dart';
import '../../data/models/purchase_order_model.dart';

MenuFeature? _findFeature(List<MenuModule> modules, String screenPath) {
  for (final mod in modules) {
    for (final grp in mod.groups) {
      for (final feat in grp.features) {
        if (feat.screenName == screenPath) return feat;
      }
    }
  }
  return null;
}

class PurchaseOrderListScreen extends ConsumerStatefulWidget {
  const PurchaseOrderListScreen({super.key});

  @override
  ConsumerState<PurchaseOrderListScreen> createState() => _PurchaseOrderListScreenState();
}

class _PurchaseOrderListScreenState extends ConsumerState<PurchaseOrderListScreen> {
  final _ds = PurchaseOrderRemoteDs();

  List<PurchaseOrderModel> _orders = [];
  bool    _loading = true;
  String? _error;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  static const _statusColors = {
    'DRAFT':              AppColors.badgeDraft,
    'APPROVED':           AppColors.positive,
    'PARTIALLY_RECEIVED': AppColors.secondary,
    'CLOSED':             AppColors.textSecondary,
    'CANCELLED':          AppColors.negative,
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
      final rows = await _ds.listOrders(
        clientId:  session.clientId,
        companyId: session.companyId,
        status:    _filterStatus,
      );
      if (mounted) setState(() { _orders = rows; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load purchase orders: $e'; });
    }
  }

  List<PurchaseOrderModel> get _filtered {
    if (_searchText.isEmpty) return _orders;
    return _orders.where((o) =>
        o.orderNo.toLowerCase().contains(_searchText) ||
        (o.supplierName ?? '').toLowerCase().contains(_searchText)).toList();
  }

  void _openNew() => context.push(RouteNames.purchaseOrderEntry);

  void _openEdit(PurchaseOrderModel o) => context.push(
      RouteNames.purchaseOrderEntry, extra: {'orderNo': o.orderNo, 'orderDate': o.orderDate});

  String _displayDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  String _statusLabel(String s) => switch (s) {
    'DRAFT' => 'Draft',
    'APPROVED' => 'Approved',
    'PARTIALLY_RECEIVED' => 'Partially Received',
    'CLOSED' => 'Closed',
    'CANCELLED' => 'Cancelled',
    _ => s,
  };

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final menus     = ref.watch(menuProvider);
    final feature   = _findFeature(menus, RouteNames.purchaseOrders);

    if (feature == null) {
      return const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lock_outline, size: 48, color: AppColors.textDisabled),
          SizedBox(height: 12),
          Text('You do not have access to this screen.', style: TextStyle(color: AppColors.textSecondary)),
        ]),
      );
    }

    final canAdd = !isOffline && feature.addAllowed;
    final rows   = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(
              child: Text('Purchase Orders',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            if (canAdd)
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Purchase Order'),
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
                    hintText: 'Search order no / supplier…',
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
                                    _th('Order No',  flex: 2),
                                    _th('Date',      flex: 2),
                                    _th('Type',      flex: 1),
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
              _searchText.isNotEmpty ? '${rows.length} of ${_orders.length} order(s)' : '${rows.length} order(s)',
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

  Widget _buildRow(PurchaseOrderModel o, int index) {
    return InkWell(
      onTap: () => _openEdit(o),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(o.orderNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_displayDate(o.orderDate), style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 1, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(o.poType == 'IMPORT' ? 'Import' : 'Local',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)))),
          Expanded(flex: 3, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(o.supplierName != null ? '[${o.supplierCode}] ${o.supplierName}' : '—',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('${o.poCurrencyCode ?? ''} ${o.grandTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)))),
          Expanded(flex: 2, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _statusBadge(o.status))),
          Expanded(flex: 1, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 14),
              color: AppColors.primary,
              onPressed: () => _openEdit(o),
              tooltip: 'Open',
              padding: EdgeInsets.zero,
            ),
          )),
        ]),
      ),
    );
  }

  Widget _buildCard(PurchaseOrderModel o) {
    return InkWell(
      onTap: () => _openEdit(o),
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
            Expanded(child: Text(o.orderNo,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(o.status),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Text(o.poType == 'IMPORT' ? 'Import' : 'Local',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(width: 8),
            const Text('·', style: TextStyle(color: AppColors.textDisabled)),
            const SizedBox(width: 8),
            Text(_displayDate(o.orderDate), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 4),
          Text(o.supplierName != null ? '[${o.supplierCode}] ${o.supplierName}' : '—',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text('${o.poCurrencyCode ?? ''} ${o.grandTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.shopping_cart_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No purchase orders found',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Create a new purchase order to get started.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

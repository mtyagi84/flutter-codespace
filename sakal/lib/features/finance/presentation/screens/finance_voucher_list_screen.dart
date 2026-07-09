import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../providers/finance_voucher_providers.dart';

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

class FinanceVoucherListScreen extends ConsumerStatefulWidget {
  const FinanceVoucherListScreen({super.key});

  @override
  ConsumerState<FinanceVoucherListScreen> createState() =>
      _FinanceVoucherListScreenState();
}

class _FinanceVoucherListScreenState
    extends ConsumerState<FinanceVoucherListScreen> {

  List<Map<String, dynamic>> _vouchers = [];
  Set<String> _pendingIds = {};
  bool    _loading = true;
  String? _error;

  // Filters
  String? _filterType;
  bool?   _filterPosted;
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate   = DateTime.now();
  final _searchCtrl  = TextEditingController();
  String _searchText = '';

  static const _types = ['CRV', 'BRV', 'CPV', 'BPV'];
  static const _typeLabels = {
    'CRV': 'Cash Receipt',
    'BRV': 'Bank Receipt',
    'CPV': 'Cash Payment',
    'BPV': 'Bank Payment',
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
        ref.read(financeVoucherRepositoryProvider).listHeaders(
          clientId:  session.clientId,
          companyId: session.companyId,
          locationId: session.locationId ?? '',
          fromDate:  _fmtDate(_fromDate),
          toDate:    _fmtDate(_toDate),
          voucherTypeCode: _filterType,
          isPosted:  _filterPosted,
        ),
        ref.read(syncEngineProvider).pendingDocumentIds('FINANCE_VOUCHER'),
      ]);
      if (mounted) {
        setState(() {
          _vouchers   = results[0] as List<Map<String, dynamic>>;
          _pendingIds = results[1] as Set<String>;
          _loading    = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load vouchers.'; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _vouchers;
    return _vouchers.where((v) {
      final no      = (v['trans_no'] as String? ?? '').toLowerCase();
      final remarks = (v['remarks'] as String? ?? '').toLowerCase();
      return no.contains(_searchText) || remarks.contains(_searchText);
    }).toList();
  }

  Future<void> _pickDate(DateTime current, ValueChanged<DateTime> onPicked) async {
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2099),
    );
    if (d != null) { onPicked(d); _load(); }
  }

  void _openNew(String voucherType) =>
      context.push(RouteNames.paymentReceipt, extra: {'voucherType': voucherType});

  void _openEdit(String transNo, String transDate) =>
      context.push(RouteNames.paymentReceipt,
          extra: {'transNo': transNo, 'transDate': transDate});

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final menus     = ref.watch(menuProvider);
    final feature   = _findFeature(menus, RouteNames.voucherList);

    if (feature == null) {
      return const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lock_outline, size: 48, color: AppColors.textDisabled),
          SizedBox(height: 12),
          Text('You do not have access to this screen.',
              style: TextStyle(color: AppColors.textSecondary)),
        ]),
      );
    }

    // Creating a new voucher is allowed offline (queued via SyncEngine) —
    // only Post/Approve requires being online.
    final canAdd = feature.addAllowed;
    final rows   = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        // ── Page header ───────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(
              child: Text('Payment & Receipt Vouchers',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
            ),
            if (canAdd) ...[
              const SizedBox(width: 8),
              _NewVoucherButton(isMobile: isMobile, onSelect: _openNew),
            ],
          ]),
        ),

        const Divider(height: 20),

        // ── Filter bar ────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [

              // Date range
              InkWell(
                onTap: () => _pickDate(_fromDate, (d) => setState(() => _fromDate = d)),
                borderRadius: BorderRadius.circular(20),
                child: _chip('From: ${_displayDate(_fmtDate(_fromDate))}'),
              ),
              InkWell(
                onTap: () => _pickDate(_toDate, (d) => setState(() => _toDate = d)),
                borderRadius: BorderRadius.circular(20),
                child: _chip('To: ${_displayDate(_fmtDate(_toDate))}'),
              ),

              // Type filter
              DropdownButton<String?>(
                value: _filterType,
                hint: const Text('All Types', style: TextStyle(fontSize: 13)),
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: null,
                      child: Text('All Types', style: TextStyle(fontSize: 13))),
                  ..._types.map((t) => DropdownMenuItem(
                    value: t,
                    child: Text('$t — ${_typeLabels[t]}',
                        style: const TextStyle(fontSize: 13)),
                  )),
                ],
                onChanged: (v) { setState(() => _filterType = v); _load(); },
              ),

              // Status filter
              DropdownButton<bool?>(
                value: _filterPosted,
                hint: const Text('All Status', style: TextStyle(fontSize: 13)),
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: null,
                      child: Text('All Status', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: false,
                      child: Text('Drafts',     style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: true,
                      child: Text('Posted',     style: TextStyle(fontSize: 13))),
                ],
                onChanged: (v) { setState(() => _filterPosted = v); _load(); },
              ),

              // Search
              SizedBox(
                width: 220,
                height: 36,
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search trans no / remarks…',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 16),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20)),
                    suffixIcon: _searchText.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 14),
                            onPressed: _searchCtrl.clear)
                        : null,
                  ),
                ),
              ),

              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _load,
                tooltip: 'Refresh',
                color: AppColors.primary,
              ),
            ],
          ),
        ),

        // ── Table (desktop/tablet) / Card list (mobile) ───────────────────────
        Expanded(
          child: SakalAdaptiveList<Map<String, dynamic>>(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Trans No', flex: 3),
              SakalListColumn('Date', flex: 2),
              SakalListColumn('Type', flex: 2),
              SakalListColumn('Mode', flex: 2),
              SakalListColumn('Settlement', flex: 2),
              SakalListColumn('Status', flex: 1),
              SakalListColumn('Remarks', flex: 3),
              SakalListColumn('', flex: 1),
            ],
            rowBuilder: _buildRow,
            cardBuilder: _buildCard,
            emptyState: _emptyState(),
          ),
        ),

        // ── Footer ────────────────────────────────────────────────────────────
        if (!_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
            child: Text(
              _searchText.isNotEmpty
                  ? '${rows.length} of ${_vouchers.length} voucher(s)'
                  : '${rows.length} voucher(s)',
              style: const TextStyle(fontSize: 12,
                  color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _chip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(20),
      color: AppColors.surfaceVariant,
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.calendar_today_outlined, size: 13,
          color: AppColors.primary),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ]),
  );

  Widget _buildRow(Map<String, dynamic> v, int index) {
    final isPosted  = v['is_posted']      as bool?   ?? false;
    final isOnAcct  = v['is_on_account']  as bool?   ?? false;
    final transNo   = (v['trans_no']       as String?) ?? '';
    final transDate = v['trans_date']     as String? ?? '';
    final vtype     = v['voucher_type_code'] as String? ?? '';

    return InkWell(
      onTap: () => _openEdit(transNo, transDate),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(transNo,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w500, color: AppColors.primary))),
                if (_pendingIds.contains(transNo)) ...[
                  const SizedBox(width: 6),
                  const PendingSyncBadge.static(isPending: true),
                ],
              ]),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_displayDate(transDate),
                  style: const TextStyle(fontSize: 13)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_typeLabels[vtype] ?? vtype,
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(v['payment_mode_code'] as String? ?? '—',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(isOnAcct ? 'On Account' : 'Against Bill',
                  style: TextStyle(fontSize: 11,
                      color: isOnAcct ? AppColors.info : AppColors.secondary)),
            ),
          ),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _statusBadge(isPosted),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(v['remarks'] as String? ?? '',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(
                icon: const Icon(Icons.arrow_forward_ios, size: 14),
                color: AppColors.primary,
                onPressed: () => _openEdit(transNo, transDate),
                tooltip: 'Open',
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> v) {
    final isPosted  = v['is_posted']         as bool?   ?? false;
    final isOnAcct  = v['is_on_account']     as bool?   ?? false;
    final transNo   = v['trans_no']          as String? ?? '';
    final transDate = v['trans_date']        as String? ?? '';
    final vtype     = v['voucher_type_code'] as String? ?? '';
    final mode      = v['payment_mode_code'] as String? ?? '';
    final remarks   = v['remarks']           as String? ?? '';

    return InkWell(
      onTap: () => _openEdit(transNo, transDate),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Row 1: trans no + status badge
          Row(children: [
            Expanded(
              child: Text(transNo,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600, color: AppColors.primary)),
            ),
            if (_pendingIds.contains(transNo)) ...[
              const PendingSyncBadge.static(isPending: true),
              const SizedBox(width: 6),
            ],
            _statusBadge(isPosted),
          ]),
          const SizedBox(height: 6),
          // Row 2: type label + date
          Row(children: [
            Text(_typeLabels[vtype] ?? vtype,
                style: const TextStyle(fontSize: 12,
                    color: AppColors.textSecondary)),
            const SizedBox(width: 8),
            const Text('·', style: TextStyle(color: AppColors.textDisabled)),
            const SizedBox(width: 8),
            Text(_displayDate(transDate),
                style: const TextStyle(fontSize: 12,
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 4),
          // Row 3: mode + settlement
          Row(children: [
            if (mode.isNotEmpty) ...[
              Text(mode,
                  style: const TextStyle(fontSize: 12,
                      color: AppColors.textSecondary)),
              const SizedBox(width: 8),
              const Text('·', style: TextStyle(color: AppColors.textDisabled)),
              const SizedBox(width: 8),
            ],
            Text(isOnAcct ? 'On Account' : 'Against Bill',
                style: TextStyle(fontSize: 12,
                    color: isOnAcct ? AppColors.info : AppColors.secondary,
                    fontWeight: FontWeight.w500)),
          ]),
          if (remarks.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(remarks,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11,
                    color: AppColors.textDisabled)),
          ],
        ]),
      ),
    );
  }

  Widget _statusBadge(bool posted) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: (posted ? AppColors.positive : AppColors.badgeDraft)
          .withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(
          color: (posted ? AppColors.positive : AppColors.badgeDraft)
              .withValues(alpha: 0.4)),
    ),
    child: Text(
      posted ? 'Posted' : 'Draft',
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: posted ? AppColors.positive : AppColors.badgeDraft,
      ),
    ),
  );

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.receipt_long_outlined, size: 48,
          color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No vouchers found',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Adjust the date range or create a new voucher.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

// ── New Voucher dropdown button ────────────────────────────────────────────────

class _NewVoucherButton extends StatelessWidget {
  final bool isMobile;
  final void Function(String) onSelect;

  const _NewVoucherButton({required this.isMobile, required this.onSelect});

  static const _types = ['CRV', 'BRV', 'CPV', 'BPV'];
  static const _labels = {
    'CRV': 'Cash Receipt',
    'BRV': 'Bank Receipt',
    'CPV': 'Cash Payment',
    'BPV': 'Bank Payment',
  };
  static const _icons = {
    'CRV': Icons.arrow_downward,
    'BRV': Icons.arrow_downward,
    'CPV': Icons.arrow_upward,
    'BPV': Icons.arrow_upward,
  };

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: _types.map((t) => MenuItemButton(
        leadingIcon: Icon(_icons[t], size: 16,
            color: t[1] == 'R' ? AppColors.positive : AppColors.secondary),
        onPressed: () => onSelect(t),
        child: Text(_labels[t]!),
      )).toList(),
      builder: (_, controller, __) => FilledButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: const Row(mainAxisSize: MainAxisSize.min, children: [
          Text('New Voucher'),
          SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 18),
        ]),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    );
  }
}

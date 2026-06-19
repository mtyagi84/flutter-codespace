import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/offline_banner.dart';

class FinanceVoucherListScreen extends ConsumerStatefulWidget {
  const FinanceVoucherListScreen({super.key});

  @override
  ConsumerState<FinanceVoucherListScreen> createState() =>
      _FinanceVoucherListScreenState();
}

class _FinanceVoucherListScreenState
    extends ConsumerState<FinanceVoucherListScreen> {

  List<Map<String, dynamic>> _vouchers = [];
  bool    _loading      = true;
  String? _error;

  // Filters
  String? _filterType;   // null = all
  bool?   _filterPosted; // null = all, true = posted, false = drafts
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate   = DateTime.now();

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final params = <String, dynamic>{
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'location_id':'eq.${session.locationId}',
        'is_deleted': 'eq.false',
        'trans_date': 'gte.${_fmtDate(_fromDate)}',
        'select':     'trans_no,trans_date,voucher_type_code,payment_mode_code,is_posted,remarks',
        'order':      'trans_date.desc,created_at.desc',
        'limit':      '200',
      };
      // trans_date to (lte)
      params['trans_date'] = 'gte.${_fmtDate(_fromDate)}';
      // Also add lte filter — PostgREST allows multiple same-key params via list
      if (_filterType != null) params['voucher_type_code'] = 'eq.$_filterType';
      if (_filterPosted != null) params['is_posted'] = 'eq.$_filterPosted';

      final res = await DioClient.instance.get('/rih_finance_headers',
          queryParameters: params);

      final all = List<Map<String, dynamic>>.from(res.data as List);
      // Client-side date filter for "to" date
      final filtered = all.where((v) {
        final d = DateTime.tryParse(v['trans_date'] as String? ?? '');
        return d != null && !d.isAfter(_toDate);
      }).toList();

      if (mounted) setState(() { _vouchers = filtered; _loading = false; });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load vouchers.'; });
    }
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

  void _openNew(String voucherType) {
    context.push(RouteNames.paymentReceipt,
        extra: {'voucherType': voucherType});
  }

  void _openEdit(String transNo) {
    context.push(RouteNames.paymentReceipt,
        extra: {'transNo': transNo});
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  String _displayDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2,'0')} ${m[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        // ── Page header ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Row(children: [
            const Expanded(
              child: Text('Payment & Receipt Vouchers',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
            ),
            if (!isOffline) ...[
              // New voucher shortcuts
              for (final t in _types) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.add, size: 14),
                  label: Text(_typeLabels[t]!, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _openNew(t),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.startsWith('C')
                        ? AppColors.primary : AppColors.primaryLight,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ],
          ]),
        ),

        const Divider(height: 20),

        // ── Filters ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Row(children: [

            // From date
            InkWell(
              onTap: () => _pickDate(_fromDate, (d) => setState(() => _fromDate = d)),
              child: _filterChip('From: ${_displayDate(_fmtDate(_fromDate))}'),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => _pickDate(_toDate, (d) => setState(() => _toDate = d)),
              child: _filterChip('To: ${_displayDate(_fmtDate(_toDate))}'),
            ),
            const SizedBox(width: 12),

            // Type filter
            DropdownButton<String?>(
              value: _filterType,
              hint: const Text('All Types', style: TextStyle(fontSize: 13)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Types', style: TextStyle(fontSize: 13))),
                ..._types.map((t) => DropdownMenuItem(
                  value: t,
                  child: Text('$t — ${_typeLabels[t]}', style: const TextStyle(fontSize: 13)),
                )),
              ],
              onChanged: (v) { setState(() => _filterType = v); _load(); },
            ),
            const SizedBox(width: 12),

            // Status filter
            DropdownButton<bool?>(
              value: _filterPosted,
              hint: const Text('All Status', style: TextStyle(fontSize: 13)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: null,  child: Text('All Status', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: false, child: Text('Drafts',     style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: true,  child: Text('Posted',     style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) { setState(() => _filterPosted = v); _load(); },
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _load,
              tooltip: 'Refresh',
              color: AppColors.primary,
            ),
          ]),
        ),

        // ── Table ─────────────────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!,
                        style: const TextStyle(color: AppColors.negative)))
                  : _vouchers.isEmpty
                      ? _emptyState()
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                          child: Column(children: [
                            // Table header
                            Container(
                              decoration: const BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                              ),
                              child: Row(children: [
                                _th('Trans No',      flex: 3),
                                _th('Date',          flex: 2),
                                _th('Type',          flex: 2),
                                _th('Mode',          flex: 2),
                                _th('Status',        flex: 1),
                                _th('Remarks',       flex: 3),
                                _th('',              flex: 1),
                              ]),
                            ),
                            Expanded(
                              child: ListView.separated(
                                itemCount: _vouchers.length,
                                separatorBuilder: (_, __) =>
                                    Divider(height: 1, color: AppColors.border),
                                itemBuilder: (_, i) => _buildRow(i),
                              ),
                            ),
                          ]),
                        ),
        ),

        // ── Footer count ──────────────────────────────────────────────────────
        if (!_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text('${_vouchers.length} voucher(s)',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ),
      ],
    );
  }

  Widget _filterChip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(20),
      color: AppColors.surfaceVariant,
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.calendar_today_outlined, size: 13, color: AppColors.primary),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ]),
  );

  Widget _th(String t, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(t, style: const TextStyle(color: Colors.white,
          fontWeight: FontWeight.w600, fontSize: 12)),
    ),
  );

  Widget _buildRow(int index) {
    final v       = _vouchers[index];
    final isPosted = v['is_posted'] as bool? ?? false;
    final transNo  = v['trans_no'] as String;
    final vtype    = v['voucher_type_code'] as String? ?? '';

    return InkWell(
      onTap: () => _openEdit(transNo),
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(transNo,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w500, color: AppColors.primary)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _displayDate(v['trans_date'] as String? ?? ''),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_typeLabels[vtype] ?? vtype,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
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
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: IconButton(
                icon: const Icon(Icons.arrow_forward_ios, size: 14),
                color: AppColors.primary,
                onPressed: () => _openEdit(transNo),
                tooltip: 'Open',
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _statusBadge(bool posted) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: posted
            ? AppColors.positive.withOpacity(0.1)
            : AppColors.badgeDraft.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: posted
              ? AppColors.positive.withOpacity(0.4)
              : AppColors.badgeDraft.withOpacity(0.4),
        ),
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
  }

  Widget _emptyState() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.textDisabled),
      const SizedBox(height: 16),
      const Text('No vouchers found',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              color: AppColors.textPrimary)),
      const SizedBox(height: 8),
      const Text('Adjust the date range or create a new voucher.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

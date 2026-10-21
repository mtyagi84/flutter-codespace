import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_invoice_providers.dart';
import '../widgets/pos_keyboard.dart';
import '../widgets/pos_session_guard.dart';

/// Held (DRAFT) sales for the CURRENT open shift — "holding" a sale is
/// nothing more than saving it as a DRAFT without approving
/// (see pos_new_sale_screen.dart's `_hold()`); this screen is just a
/// filtered list of `rih_sales_invoices` with `status='DRAFT'` and
/// `pos_shift_id` = this terminal's open shift, scoped the same way a real
/// till would only ever show its OWN parked baskets, not another till's.
///
/// Offline (migration-free fix, 2026-10-20): `_load()` reads the local
/// SalesInvoicesCache via the repository's own already-offline-aware
/// `listInvoices()` instead of a raw online-only DioClient call, so a sale
/// held while offline (`_hold()`'s existing SyncEngine-queued path) is
/// actually recoverable before the queue drains — not shift-scoped there
/// (the cache has no pos_shift_id column; an offline till only ever has its
/// own single local shift anyway).
class PosHoldSalesScreen extends ConsumerStatefulWidget {
  const PosHoldSalesScreen({super.key});

  @override
  ConsumerState<PosHoldSalesScreen> createState() => _PosHoldSalesScreenState();
}

class _PosHoldSalesScreenState extends ConsumerState<PosHoldSalesScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _held = [];
  String _searchQuery = '';

  List<Map<String, dynamic>> get _filtered {
    if (_searchQuery.isEmpty) return _held;
    final q = _searchQuery.toLowerCase();
    return _held.where((row) {
      final invoiceNo = (row['invoice_no'] as String? ?? '').toLowerCase();
      final customerName = ((row['customer'] as Map<String, dynamic>?)?['account_name'] as String? ?? row['party_name'] as String? ?? '').toLowerCase();
      return invoiceNo.contains(q) || customerName.contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    if (session.posTerminalId == null) {
      setState(() { _loading = false; _error = 'This isn\'t a POS till session. Sign out and sign back in from the POS Login screen.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });

    // Real gap fixed 2026-10-20: `_hold()` (pos_new_sale_screen.dart) has
    // always correctly queued a held sale offline via SyncEngine +
    // cacheInvoiceLocally — this screen just never had an offline read path
    // at all, so an offline-held basket was genuinely unrecoverable until
    // the sync queue drained. `listInvoices()` already branches on
    // `session.offlineMode` at the repository layer (reading
    // SalesInvoicesCache via SalesInvoiceLocalDs) — no new datasource code
    // needed, just routing through it here instead of a raw online-only
    // DioClient call. Deliberately NOT shift-scoped while offline (the
    // cache has no pos_shift_id column, and an offline till only ever has
    // its own single local shift context anyway — see the online branch
    // below for the real shift-scoped query, unchanged).
    if (session.offlineMode) {
      try {
        final ds = ref.read(salesInvoiceRepositoryProvider);
        final headers = await ds.listInvoices(
          clientId: session.clientId, companyId: session.companyId, status: 'DRAFT', limit: 200,
        );
        if (mounted) {
          setState(() {
            _held = headers.map((h) => {
                  'invoice_no': h.invoiceNo, 'invoice_date': h.invoiceDate, 'sale_type': h.saleType,
                  'party_name': h.partyName, 'grand_total': h.grandTotal,
                  'customer': {'account_name': h.customerName},
                }).toList();
            _loading = false;
          });
        }
      } catch (e, st) {
        AppLogger.error('PosHoldSalesLoad', e, st);
        if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load held sales'); });
      }
      return;
    }

    try {
      final shiftRes = await DioClient.instance.get('/rih_pos_shifts', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'terminal_id': 'eq.${session.posTerminalId}', 'status': 'eq.OPEN', 'is_deleted': 'eq.false',
        'select': 'id', 'limit': '1',
      });
      final shifts = shiftRes.data as List;
      if (shifts.isEmpty) {
        if (mounted) setState(() { _held = []; _loading = false; });
        return;
      }
      final shiftId = (shifts.first as Map<String, dynamic>)['id'] as String;

      final res = await DioClient.instance.get('/rih_sales_invoices', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'pos_shift_id': 'eq.$shiftId', 'status': 'eq.DRAFT', 'is_deleted': 'eq.false',
        'select': 'invoice_no,invoice_date,sale_type,party_name,grand_total,created_at,'
            'customer:rim_accounts!customer_id(account_name)',
        'order': 'created_at.desc',
      });
      if (mounted) setState(() { _held = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
    } catch (e, st) {
      AppLogger.error('PosHoldSalesLoad', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load held sales'); });
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final session = ref.read(sessionProvider)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Held Sale'),
        content: Text('Delete ${row['invoice_no']}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: AppColors.negative), onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await DioClient.instance.patch('/rih_sales_invoices', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}', 'invoice_no': 'eq.${row['invoice_no']}',
      }, data: {'is_deleted': true});
      _load();
    } catch (e, st) {
      AppLogger.error('PosHoldSalesDelete', e, st);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorPresenter.format(e, action: 'delete this held sale')), backgroundColor: AppColors.negative));
    }
  }

  void _resume(Map<String, dynamic> row) {
    context.go(RouteNames.posSale, extra: {'invoiceNo': row['invoice_no'], 'invoiceDate': row['invoice_date']});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Held Sales'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go(RouteNames.posSale)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? buildPosSessionGuardError(context, _error!, _load)
              : Column(children: [
                  if (_held.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: PosKeyboardField(
                        label: 'Search invoice no. or customer…',
                        value: _searchQuery,
                        onChanged: (v) => setState(() => _searchQuery = v),
                      ),
                    ),
                  Expanded(
                    child: _filtered.isEmpty
                        ? Center(child: Text(_held.isEmpty ? 'No baskets on hold.' : 'No match for "$_searchQuery".', style: const TextStyle(color: AppColors.textSecondary)))
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _filtered.length,
                            itemBuilder: (context, i) {
                              final row = _filtered[i];
                              final customerName = (row['customer'] as Map<String, dynamic>?)?['account_name'] as String? ?? row['party_name'] as String? ?? 'Walk-in';
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: ListTile(
                                  leading: const Icon(Icons.pause_circle_outline, color: AppColors.secondary),
                                  title: Text(row['invoice_no'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                                  subtitle: Text('$customerName · ${row['sale_type']}'),
                                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Text((row['grand_total'] as num).toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w800)),
                                    IconButton(icon: const Icon(Icons.delete_outline, color: AppColors.negative), onPressed: () => _delete(row)),
                                  ]),
                                  onTap: () => _resume(row),
                                ),
                              );
                            },
                          ),
                  ),
                ]),
    );
  }
}

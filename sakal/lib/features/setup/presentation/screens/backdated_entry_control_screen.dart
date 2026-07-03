import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

/// Per-transaction-type backdate window — an operational guardrail, distinct
/// from Period Close's compliance-grade lock. Missing/inactive row =
/// unlimited backdating (opt-in control, not opt-out).
/// See backend/migrations/035_period_close_backdated_control.sql.
class BackdatedEntryControlScreen extends ConsumerStatefulWidget {
  const BackdatedEntryControlScreen({super.key});

  @override
  ConsumerState<BackdatedEntryControlScreen> createState() => _BackdatedEntryControlScreenState();
}

class _TxnTypeRow {
  final String type;
  final String label;
  final TextEditingController daysCtrl = TextEditingController();
  bool allowFuture = false;
  String? existingId;

  _TxnTypeRow(this.type, this.label);
}

class _BackdatedEntryControlScreenState extends ConsumerState<BackdatedEntryControlScreen>
    with ScreenPermissionMixin<BackdatedEntryControlScreen> {
  @override String get screenName => RouteNames.backdatedEntryControl;

  static const _types = [
    ('GRN', 'Goods Receipt'),
    ('PURCHASE_INVOICE', 'Purchase Invoice'),
    ('SUPPLIER_PAYMENT', 'Supplier Payment'),
    ('SALES_INVOICE', 'Sales Invoice'),
    ('SALES_RETURN', 'Sales Return'),
    ('CASH_RECEIPT', 'Cash Receipt'),
    ('STOCK_TRANSFER', 'Stock Transfer'),
    ('STOCK_ADJUSTMENT', 'Stock Adjustment'),
    ('JOURNAL_ENTRY', 'Journal Entry'),
  ];

  late final List<_TxnTypeRow> _rows = _types.map((t) => _TxnTypeRow(t.$1, t.$2)).toList();

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.daysCtrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      List<Map<String, dynamic>> data;
      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        data = await local.getLookups(
            cacheKey: 'BACKDATED_ENTRY_CONTROL', clientId: session.clientId, companyId: session.companyId);
      } else {
        final res = await DioClient.instance.get('/ric_backdated_entry_control', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'select':     'id,transaction_type,max_backdate_days,allow_future_date',
        });
        data = List<Map<String, dynamic>>.from(res.data as List);
        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'BACKDATED_ENTRY_CONTROL', rows: data, idOf: (r) => r['id'] as String,
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }
      if (!mounted) return;
      final byType = {for (final r in data) r['transaction_type'] as String: r};
      for (final row in _rows) {
        final existing = byType[row.type];
        if (existing != null) {
          row.existingId = existing['id'] as String;
          row.daysCtrl.text = existing['max_backdate_days']?.toString() ?? '';
          row.allowFuture = existing['allow_future_date'] as bool? ?? false;
        }
      }
      setState(() => _loading = false);
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load backdated entry settings.'; });
    }
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _error = null; });
    try {
      for (final row in _rows) {
        final days = int.tryParse(row.daysCtrl.text.trim());
        final payload = {
          'client_id':          session.clientId,
          'company_id':         session.companyId,
          'transaction_type':   row.type,
          'max_backdate_days':  days,
          'allow_future_date':  row.allowFuture,
        };
        if (row.existingId != null) {
          await DioClient.instance.patch('/ric_backdated_entry_control',
              queryParameters: {'id': 'eq.${row.existingId}'},
              data: payload,
              options: Options(headers: {'Prefer': 'return=minimal'}));
        } else {
          await DioClient.instance.post('/ric_backdated_entry_control',
              data: payload,
              options: Options(headers: {'Prefer': 'return=minimal'}));
        }
      }
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backdated entry settings saved.'), backgroundColor: AppColors.positive));
      }
      _load();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed. Please try again.';
      if (mounted) setState(() { _saving = false; _error = msg; });
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Unexpected error: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline  = ref.watch(sessionProvider)?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Backdated Entry Control',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text(
                  'Per-screen guardrail for how far back a new entry can normally be dated. '
                  'Leave Max Days blank for unlimited. This is separate from Period Close — '
                  'a locked period always blocks posting regardless of this setting.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 20),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
                  ]),
                ),
                const SizedBox(height: 20),
              ],

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                    : Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: _rows.map((r) => _buildRow(r, offline, isMobile)).toList()),
                      ),
              ),

              if (canEdit && !offline) ...[
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 160,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(height: 18, width: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Save Changes'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(_TxnTypeRow row, bool offline, bool isMobile) {
    final locked = !canEdit || offline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Text(row.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        ),
        SizedBox(
          width: 130,
          child: TextFormField(
            controller: row.daysCtrl,
            enabled: !locked,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Max Days',
              hintText: 'Unlimited',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(
              value: row.allowFuture,
              onChanged: locked ? null : (v) => setState(() => row.allowFuture = v),
              thumbColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? Colors.white : Colors.grey.shade400),
              trackColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? AppColors.primary : AppColors.surfaceVariant),
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            ),
            const SizedBox(width: 8),
            const Text('Allow future date', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        ),
      ]),
    );
  }
}

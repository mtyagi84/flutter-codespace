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

/// Company-wide period locks — e.g. "GST filed for January, lock it."
/// Locking is a normal edit_allowed action; reopening requires
/// approve_allowed (mirrors PO/GRN's own approval gating) plus a mandatory
/// stored reason. See backend/migrations/035_period_close_backdated_control.sql.
class PeriodCloseScreen extends ConsumerStatefulWidget {
  const PeriodCloseScreen({super.key});

  @override
  ConsumerState<PeriodCloseScreen> createState() => _PeriodCloseScreenState();
}

class _PeriodCloseScreenState extends ConsumerState<PeriodCloseScreen>
    with ScreenPermissionMixin<PeriodCloseScreen> {
  @override String get screenName => RouteNames.periodClose;

  List<Map<String, dynamic>> _locks = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      List<Map<String, dynamic>> rows;
      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        rows = await local.getLookups(
            cacheKey: 'PERIOD_LOCKS', clientId: session.clientId, companyId: session.companyId);
      } else {
        final res = await DioClient.instance.get('/ric_period_locks', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'select':     'id,period_start_date,period_end_date,locked_at,reopened_at,reopen_reason,is_active',
          'order':      'period_start_date.desc',
        });
        rows = List<Map<String, dynamic>>.from(res.data as List);
        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'PERIOD_LOCKS', rows: rows, idOf: (r) => r['id'] as String,
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }
      if (!mounted) return;
      setState(() { _locks = rows; _loading = false; });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load period locks.'; });
    }
  }

  Future<void> _openLockDialog() async {
    final session = ref.read(sessionProvider)!;
    DateTime? from;
    DateTime? to;
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: const Text('Lock a Period'),
          content: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(from == null ? 'From date' : _fmt(from!)),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                onTap: () async {
                  final d = await showDatePicker(
                      context: dialogCtx, initialDate: DateTime.now(),
                      firstDate: DateTime(2020), lastDate: DateTime(2099));
                  if (d != null) setDialogState(() => from = d);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(to == null ? 'To date' : _fmt(to!)),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                onTap: () async {
                  final d = await showDatePicker(
                      context: dialogCtx, initialDate: from ?? DateTime.now(),
                      firstDate: DateTime(2020), lastDate: DateTime(2099));
                  if (d != null) setDialogState(() => to = d);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (from == null || to == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please pick both dates.'), backgroundColor: Colors.orange),
                  );
                  return;
                }
                if (to!.isBefore(from!)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('End date must be on or after the start date.'), backgroundColor: Colors.orange),
                  );
                  return;
                }
                try {
                  await DioClient.instance.post('/ric_period_locks', data: {
                    'client_id':         session.clientId,
                    'company_id':        session.companyId,
                    'period_start_date': _iso(from!),
                    'period_end_date':   _iso(to!),
                    'locked_by':         session.userId,
                  }, options: Options(headers: {'Prefer': 'return=minimal'}));
                  if (dialogCtx.mounted) Navigator.of(dialogCtx, rootNavigator: true).pop();
                  _load();
                } on DioException catch (e) {
                  final msg = e.response?.data?['message'] as String? ?? 'Could not lock period.';
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Unexpected error: $e'), backgroundColor: AppColors.negative));
                  }
                }
              },
              child: const Text('Lock Period'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReopenDialog(Map<String, dynamic> lock) async {
    final session = ref.read(sessionProvider)!;
    final reasonCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Reopen Period'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: reasonCtrl,
            maxLines: 3,
            decoration: InputDecoration(
              label: _req('Reason for reopening'),
              hintText: 'e.g. correction needed after GST re-filing',
            ),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'A reason is required to reopen a locked period.' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.negative),
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              try {
                await DioClient.instance.patch('/ric_period_locks',
                    queryParameters: {'id': 'eq.${lock['id']}'},
                    data: {
                      'is_active':     false,
                      'reopened_by':   session.userId,
                      'reopened_at':   DateTime.now().toUtc().toIso8601String(),
                      'reopen_reason': reasonCtrl.text.trim(),
                    },
                    options: Options(headers: {'Prefer': 'return=minimal'}));
                if (dialogCtx.mounted) Navigator.of(dialogCtx, rootNavigator: true).pop();
                _load();
              } on DioException catch (e) {
                final msg = e.response?.data?['message'] as String? ?? 'Could not reopen period.';
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Unexpected error: $e'), backgroundColor: AppColors.negative));
                }
              }
            },
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
  }

  static Widget _req(String text) => RichText(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
      children: const [
        TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  String _fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _iso(DateTime d) => _fmt(d);

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
              Row(children: [
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Period Close',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    SizedBox(height: 4),
                    Text(
                        'Lock a date range once it has been filed/reported — no transaction can post '
                        'against a locked period, company-wide, regardless of when it is entered.',
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ]),
                ),
                if (canEdit && !offline)
                  ElevatedButton.icon(
                    onPressed: _openLockDialog,
                    icon: const Icon(Icons.lock_outline, size: 16),
                    label: const Text('Lock Period'),
                  ),
              ]),
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
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                ),
                const SizedBox(height: 20),
              ],

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                    : _locks.isEmpty
                        ? const Padding(padding: EdgeInsets.all(24), child: Text('No periods locked yet.'))
                        : Column(children: _locks.map((l) => _buildLockTile(l, offline)).toList()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLockTile(Map<String, dynamic> lock, bool offline) {
    final active = lock['is_active'] as bool? ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.5)))),
      child: Row(children: [
        Icon(active ? Icons.lock_outline : Icons.lock_open_outlined, size: 18,
            color: active ? AppColors.negative : AppColors.textDisabled),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${lock['period_start_date']}  —  ${lock['period_end_date']}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            if (!active && lock['reopen_reason'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Reopened: ${lock['reopen_reason']}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (active ? AppColors.negative : AppColors.textDisabled).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(active ? 'LOCKED' : 'REOPENED',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: active ? AppColors.negative : AppColors.textDisabled)),
        ),
        if (active && canApprove && !offline) ...[
          const SizedBox(width: 12),
          TextButton(onPressed: () => _openReopenDialog(lock), child: const Text('Reopen')),
        ],
      ]),
    );
  }
}

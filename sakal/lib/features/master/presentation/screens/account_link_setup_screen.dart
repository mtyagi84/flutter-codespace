import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

/// Lists the seeded account-link types (Sales Account, Stock Account,
/// Purchase Accrual Account…) and the granularity each is currently
/// configured at. See backend/migrations/032_account_link_setup.sql.
class AccountLinkSetupScreen extends ConsumerStatefulWidget {
  const AccountLinkSetupScreen({super.key});

  @override
  ConsumerState<AccountLinkSetupScreen> createState() => _AccountLinkSetupScreenState();
}

class _AccountLinkSetupScreenState extends ConsumerState<AccountLinkSetupScreen>
    with ScreenPermissionMixin<AccountLinkSetupScreen> {
  @override String get screenName => RouteNames.accountLinkSetup;

  List<Map<String, dynamic>> _types = [];
  Map<String, String> _levelByType = {};   // link_type_id -> link_type
  Map<String, int>    _countByType = {};   // link_type_id -> configured default rows
  bool    _loading = true;
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
      List<Map<String, dynamic>> typeRows;
      List<Map<String, dynamic>> setupRows;
      List<Map<String, dynamic>> defaultRows;

      if (session.offlineMode && !kIsWeb) {
        final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
        // ACCOUNT_LINK_TYPES is a global (seeded) list — no client/company filter.
        typeRows    = await local.getLookups(cacheKey: 'ACCOUNT_LINK_TYPES');
        setupRows   = await local.getLookups(
            cacheKey: 'ACCOUNT_LINK_SETUP', clientId: session.clientId, companyId: session.companyId);
        defaultRows = await local.getLookups(
            cacheKey: 'ACCOUNT_LINK_DEFAULTS', clientId: session.clientId, companyId: session.companyId);
      } else {
        final results = await Future.wait([
          DioClient.instance.get('/rim_account_link_types', queryParameters: {
            'is_deleted': 'eq.false',
            'is_active':  'eq.true',
            'select':     'id,link_key,link_name,sort_order',
            'order':      'sort_order.asc',
          }),
          DioClient.instance.get('/rim_account_link_setup', queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'select':     'id,link_type_id,link_type',
          }),
          DioClient.instance.get('/rim_account_link_defaults', queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'is_deleted': 'eq.false',
            'select':     'id,link_type_id',
          }),
        ]);
        typeRows    = List<Map<String, dynamic>>.from(results[0].data as List);
        setupRows   = List<Map<String, dynamic>>.from(results[1].data as List);
        defaultRows = List<Map<String, dynamic>>.from(results[2].data as List);

        if (!kIsWeb) {
          final local = GenericLookupLocalDs(ref.read(appDatabaseProvider));
          unawaited(local.upsertLookups(
            cacheKey: 'ACCOUNT_LINK_TYPES', rows: typeRows, idOf: (r) => r['id'] as String,
          ));
          unawaited(local.upsertLookups(
            cacheKey: 'ACCOUNT_LINK_SETUP', rows: setupRows, idOf: (r) => r['id'] as String,
            clientId: session.clientId, companyId: session.companyId,
          ));
          unawaited(local.upsertLookups(
            cacheKey: 'ACCOUNT_LINK_DEFAULTS', rows: defaultRows, idOf: (r) => r['id'] as String,
            clientId: session.clientId, companyId: session.companyId,
          ));
        }
      }

      if (!mounted) return;
      final levelMap = <String, String>{
        for (final r in setupRows) r['link_type_id'] as String: r['link_type'] as String,
      };
      final countMap = <String, int>{};
      for (final r in defaultRows) {
        final id = r['link_type_id'] as String;
        countMap[id] = (countMap[id] ?? 0) + 1;
      }
      setState(() {
        _types       = typeRows;
        _levelByType = levelMap;
        _countByType = countMap;
        _loading     = false;
      });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load account link types.'; });
    }
  }

  String _levelLabel(String? level) => switch (level) {
    'COMPANY'  => 'Company-wide',
    'CATEGORY' => 'Category-wise',
    'LOCATION' => 'Location-wise',
    'ITEM'     => 'Item-wise',
    _          => 'Not configured',
  };

  Color _levelColor(String? level) =>
      level == null ? AppColors.textDisabled : AppColors.positive;

  void _openConfigure(Map<String, dynamic> type) {
    context.push(RouteNames.accountLinkConfigure, extra: {
      'linkTypeId': type['id'],
      'linkKey':    type['link_key'],
      'linkName':   type['link_name'],
    }).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Account Link Setup',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            SizedBox(height: 4),
            Text(
                'GL account determination — decide which account each posting type uses '
                '(company-wide, by category, by location, or per item).',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ]),
        ),
        const SizedBox(height: 16),

        if (offline) const OfflineBanner(),

        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Container(
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
          ),

        Expanded(
          child: SakalAdaptiveList<Map<String, dynamic>>(
            loading: _loading,
            error: null,
            rows: _types,
            columns: const [
              SakalListColumn('Account Type', flex: 3),
              SakalListColumn('Level', flex: 2),
              SakalListColumn('Configured', flex: 2),
              SakalListColumn('', flex: 1),
            ],
            rowBuilder: (t, i) => _buildRow(t, offline),
            cardBuilder: (t) => _buildMobileCard(t, offline),
            emptyState: const Center(child: Text('No account link types found.',
                style: TextStyle(color: AppColors.textSecondary))),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(Map<String, dynamic> type, bool offline) {
    final level  = _levelByType[type['id']];
    final count  = _countByType[type['id']] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 3, child: Text(type['link_name'] ?? '',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _levelColor(level).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_levelLabel(level),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _levelColor(level))),
              ),
            ),
          ),
          Expanded(flex: 2, child: Text(
              level == null ? '—' : (level == 'COMPANY' ? (count > 0 ? '1 account' : '—') : '$count assigned'),
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: (canEdit && !offline) ? () => _openConfigure(type) : null,
                child: const Text('Configure'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileCard(Map<String, dynamic> type, bool offline) {
    final level = _levelByType[type['id']];
    final count = _countByType[type['id']] ?? 0;
    final configuredText = level == null ? 'Not configured' : (level == 'COMPANY' ? (count > 0 ? '1 account' : '—') : '$count assigned');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(type['link_name'] ?? '',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _levelColor(level).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(_levelLabel(level),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _levelColor(level))),
          ),
        ]),
        const SizedBox(height: 6),
        Text(configuredText, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: (canEdit && !offline) ? () => _openConfigure(type) : null,
            child: const Text('Configure'),
          ),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

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
          'select':     'link_type_id,link_type',
        }),
        DioClient.instance.get('/rim_account_link_defaults', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     'link_type_id',
        }),
      ]);
      if (!mounted) return;
      final setupRows  = List<Map<String, dynamic>>.from(results[1].data as List);
      final defaultRows = List<Map<String, dynamic>>.from(results[2].data as List);
      final levelMap = <String, String>{
        for (final r in setupRows) r['link_type_id'] as String: r['link_type'] as String,
      };
      final countMap = <String, int>{};
      for (final r in defaultRows) {
        final id = r['link_type_id'] as String;
        countMap[id] = (countMap[id] ?? 0) + 1;
      }
      setState(() {
        _types       = List<Map<String, dynamic>>.from(results[0].data as List);
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
    final offline  = ref.watch(sessionProvider)?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Account Link Setup',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text(
                  'GL account determination — decide which account each posting type uses '
                  '(company-wide, by category, by location, or per item).',
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
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                ),
                const SizedBox(height: 20),
              ],

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                    : isMobile
                        ? Column(children: _types.map((t) => _buildMobileCard(t, offline)).toList())
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTableHeader(),
                              const Divider(height: 1),
                              ..._types.asMap().entries.map((e) => _buildRow(e.value, e.key.isEven)),
                            ],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeader() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: const BoxDecoration(
      color: AppColors.surfaceVariant,
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    child: const Row(children: [
      Expanded(flex: 3, child: _HCol('Account Type')),
      Expanded(flex: 2, child: _HCol('Level')),
      Expanded(flex: 2, child: _HCol('Configured')),
      SizedBox(width: 100, child: _HCol('Actions')),
    ]),
  );

  Widget _buildRow(Map<String, dynamic> type, bool isEven) {
    final level  = _levelByType[type['id']];
    final count  = _countByType[type['id']] ?? 0;
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return Container(
      color: isEven ? Colors.transparent : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 3, child: Text(type['link_name'] ?? '',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          Expanded(
            flex: 2,
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
          Expanded(flex: 2, child: Text(
              level == null ? '—' : (level == 'COMPANY' ? (count > 0 ? '1 account' : '—') : '$count assigned'),
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          SizedBox(
            width: 100,
            child: TextButton(
              onPressed: (canEdit && !offline) ? () => _openConfigure(type) : null,
              child: const Text('Configure'),
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

class _HCol extends StatelessWidget {
  final String text;
  const _HCol(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3));
}

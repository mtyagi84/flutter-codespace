import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/menu_models.dart';
import '../network/dio_client.dart';
import '../providers/session_provider.dart';
import '../router/route_names.dart';
import '../services/local_storage.dart';
import '../theme/app_colors.dart';
import '../utils/responsive.dart';
import '../widgets/sync_status_indicator.dart';

class TopBar extends ConsumerWidget implements PreferredSizeWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const TopBar({this.scaffoldKey, super.key});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session   = ref.watch(sessionProvider);
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final mobile    = Responsive.isMobile(context);

    return AppBar(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 1,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      leading: IconButton(
        icon: Icon(
          mobile ? Icons.menu : (collapsed ? Icons.menu : Icons.menu_open),
          color: AppColors.textSecondary,
        ),
        tooltip: mobile
            ? 'Open menu'
            : (collapsed ? 'Expand sidebar' : 'Collapse sidebar'),
        onPressed: mobile
            ? () => scaffoldKey?.currentState?.openDrawer()
            : () => ref.read(sidebarCollapsedProvider.notifier).state = !collapsed,
      ),
      title: Row(
        children: [
          const Icon(Icons.business_outlined,
              size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Text(
            session?.companyName ?? '',
            style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
      actions: [
        const SyncStatusIndicator(),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: PopupMenuButton<String>(
            offset: const Offset(0, 48),
            onSelected: (val) async {
              if (val == 'change_password') {
                context.go(RouteNames.changePassword);
              } else if (val == 'switch_company') {
                await _showSwitchCompanyDialog(context, ref, session!);
              } else if (val == 'logout') {
                ref.read(sessionProvider.notifier).state = null;
                ref.read(menuProvider.notifier).state    = [];
                await LocalStorage.clearSession();
                if (context.mounted) context.go(RouteNames.login);
              }
            },
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.primary,
                  child: Text(
                    session?.fullName.isNotEmpty == true
                        ? session!.fullName[0].toUpperCase()
                        : 'U',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  session?.fullName ?? '',
                  style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 16),
              ],
            ),
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session?.fullName ?? '',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                    Text('@${session?.username ?? ''}',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'switch_company',
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz,
                        size: 16, color: AppColors.textSecondary),
                    SizedBox(width: 10),
                    Text('Switch Company'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'change_password',
                child: Row(
                  children: [
                    Icon(Icons.lock_reset_outlined,
                        size: 16, color: AppColors.textSecondary),
                    SizedBox(width: 10),
                    Text('Change Password'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 16, color: AppColors.negative),
                    SizedBox(width: 10),
                    Text('Sign Out',
                        style: TextStyle(color: AppColors.negative)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showSwitchCompanyDialog(
    BuildContext context,
    WidgetRef ref,
    UserSession session,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SwitchCompanyDialog(session: session, ref: ref),
    );
  }
}

// ── Switch Company Dialog ───────────────────────────────────────

class _SwitchCompanyDialog extends StatefulWidget {
  final UserSession session;
  final WidgetRef ref;

  const _SwitchCompanyDialog({required this.session, required this.ref});

  @override
  State<_SwitchCompanyDialog> createState() => _SwitchCompanyDialogState();
}

class _SwitchCompanyDialogState extends State<_SwitchCompanyDialog> {
  List<Map<String, String>> _companies = [];
  bool _loading = true;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchCompanies();
  }

  Future<void> _fetchCompanies() async {
    try {
      final res = await DioClient.instance.post('/rpc/fn_get_user_companies',
          data: {
            'p_user_id':   widget.session.userId,
            'p_client_id': widget.session.clientId,
          });
      final list = (res.data as List<dynamic>)
          .map((e) => {
                'company_id':   (e as Map<String, dynamic>)['company_id'] as String,
                'company_name': e['company_name'] as String,
              })
          .toList();
      if (mounted) setState(() { _companies = list; _loading = false; });
    } on DioException {
      if (mounted) setState(() { _error = 'Could not load companies.'; _loading = false; });
    }
  }

  Future<void> _switchTo(String companyId, String companyName) async {
    if (companyId == widget.session.companyId) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _switching = true);
    try {
      final menuRes = await DioClient.instance.post('/rpc/fn_get_user_menu',
          data: {
            'p_user_id':    widget.session.userId,
            'p_client_id':  widget.session.clientId,
            'p_company_id': companyId,
          });
      final menuList = (menuRes.data as List<dynamic>)
          .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
          .toList();

      widget.ref.read(sessionProvider.notifier).state =
          widget.session.copyWith(
            companyId:   companyId,
            companyName: companyName,
          );
      widget.ref.read(menuProvider.notifier).state = menuList;

      if (mounted) {
        Navigator.of(context).pop();
        context.go(RouteNames.dashboard);
      }
    } on DioException {
      if (mounted) setState(() { _switching = false; _error = 'Switch failed. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Switch Company'),
      content: SizedBox(
        width: 340,
        child: _loading
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
                ? Text(_error!,
                    style: const TextStyle(color: AppColors.negative))
                : _switching
                    ? const SizedBox(
                        height: 80,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: _companies.map((co) {
                          final isCurrent =
                              co['company_id'] == widget.session.companyId;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.business,
                              color: isCurrent
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                            ),
                            title: Text(co['company_name']!),
                            trailing: isCurrent
                                ? const Icon(Icons.check,
                                    color: AppColors.positive, size: 18)
                                : null,
                            onTap: () =>
                                _switchTo(co['company_id']!, co['company_name']!),
                          );
                        }).toList(),
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/menu_models.dart';
import '../network/dio_client.dart';
import '../providers/session_provider.dart';
import '../router/route_names.dart';
import '../services/offline_session_cache.dart';
import '../theme/app_colors.dart';
import '../theme/theme_presets.dart';
import '../utils/responsive.dart';
import '../widgets/master_data_sync_indicator.dart';
import '../widgets/notification_bell.dart';
import '../widgets/sync_status_indicator.dart';
import 'screen_header.dart';

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
    final activePreset = ThemePresetConfig.all[ref.watch(themePresetProvider)]!;
    // Every entry/detail screen reached via context.push() (Sales Invoice
    // Entry from its list, GRN Entry from GRN List, ...) previously had NO
    // way back except the drawer/sidebar menu itself — user-requested
    // uniform Back button. GoRouter's own canPop() already tells us
    // exactly when there's somewhere to go back TO; when false (a
    // top-level, sidebar/drawer-navigated screen), the leading icon stays
    // the existing menu/collapse toggle unchanged.
    final canPop = context.canPop();
    // A screen using ScreenHeaderMixin registers its own title here — see
    // screen_header.dart. Null for every screen not yet migrated (the
    // large majority — this is an additive, opt-in mechanism, see the
    // "Screen header" mandatory pattern in CLAUDE.md), which keeps the
    // existing company-name/blank behavior below unchanged for them.
    final header = ref.watch(screenHeaderProvider);

    // Themed to match the sidebar (activePreset.primary) rather than pure
    // white, per explicit request — every child styled below assuming a
    // WHITE bar (dark icons/text) needed updating for contrast against a
    // now-dark one; AppBar's own foregroundColor cascades as a default but
    // several children set an explicit color that overrides it, so those
    // needed individual fixes too, not just the two top-level properties.
    return AppBar(
      backgroundColor: activePreset.primary,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      leading: canPop
          ? IconButton(
              icon: const Icon(Icons.arrow_back, color: AppColors.sidebarText),
              tooltip: 'Back',
              onPressed: () => context.pop(),
            )
          : IconButton(
              icon: Icon(
                mobile ? Icons.menu : (collapsed ? Icons.menu : Icons.menu_open),
                color: AppColors.sidebarText,
              ),
              tooltip: mobile
                  ? 'Open menu'
                  : (collapsed ? 'Expand sidebar' : 'Collapse sidebar'),
              onPressed: mobile
                  ? () => scaffoldKey?.currentState?.openDrawer()
                  : () => ref.read(sidebarCollapsedProvider.notifier).state = !collapsed,
            ),
      // On mobile, `actions` alone (2 status indicators + density toggle +
      // theme dropdown + the user popup, ~150-160px on its own) already
      // claims most of a narrow AppBar's width — a real overflow was
      // caught live on a 360px-wide screen because the company-name Text
      // here was a bare Row child with no Flexible/ellipsis, rendering at
      // its full natural width regardless of what was actually left.
      // Mobile therefore still shows only the registered screen title (or
      // nothing) — company name lives in the avatar menu instead (see
      // itemBuilder's disabled header item below), not competing for this
      // space at all. Desktop composites company name + screen title on
      // one line via _buildDesktopTitle, always visible regardless of
      // whether a screen has registered its own header.
      title: mobile
          ? (header != null ? _buildScreenTitle(context, header) : null)
          : _buildDesktopTitle(context, header, session),
      actions: [
        const MasterDataSyncIndicator(),
        const SyncStatusIndicator(),
        ...?header?.actions,
        const NotificationBell(),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: PopupMenuButton<String>(
            offset: const Offset(0, 48),
            onSelected: (val) async {
              if (val == 'change_password') {
                context.go(RouteNames.changePassword);
              } else if (val == 'offline_settings') {
                context.go(RouteNames.offlineSettings);
              } else if (val == 'app_logs') {
                context.go(RouteNames.appLogs);
              } else if (val == 'switch_company') {
                await _showSwitchCompanyDialog(context, ref, session!);
              } else if (val == 'density') {
                ref.read(isCompactDensityProvider.notifier).state = !ref.read(isCompactDensityProvider);
              } else if (val == 'open_theme') {
                await _showThemePicker(context, ref);
              } else if (val == 'logout') {
                // Setting sessionProvider to null already triggers
                // GoRouter's redirect (via sessionNotifier/refreshListenable
                // in app.dart/app_router.dart) to navigate to /login on its
                // own — an explicit context.go() here raced against that
                // redirect-driven navigation and could hit both targeting
                // the same destination concurrently, which is what caused a
                // real "Duplicate GlobalKey"/Element-reactivation crash on
                // a subsequent login. Let the redirect be the only thing
                // that navigates.
                ref.read(sessionProvider.notifier).state = null;
                ref.read(menuProvider.notifier).state    = [];
                await OfflineSessionCache.deactivate();
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 16,
                  // secondary, not primary — the avatar would otherwise be
                  // the exact same color as the now-dark bar behind it and
                  // effectively disappear.
                  backgroundColor: activePreset.secondary,
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
                // A longer name on a narrow screen is the same class of
                // overflow the company-name title just had — bounded +
                // ellipsis instead of an unconstrained Text, and hidden
                // outright on mobile (same reasoning as the title: the
                // AppBar has very little spare width there, and the
                // popup's own dropdown already shows the full name).
                if (!mobile)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      session?.fullName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down,
                    size: 18, color: AppColors.sidebarText),
                const SizedBox(width: 16),
              ],
            ),
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Mobile has no room for a persistent company-name
                    // element in the AppBar itself (see the `title:`
                    // comment above) — shown here instead, at the top of
                    // the one menu that's always one tap away on any
                    // screen, so it's still never more than a tap from
                    // being visible even on the narrowest layout.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.business_outlined, size: 12, color: AppColors.textSecondary),
                        const SizedBox(width: 4),
                        Text(session?.companyName ?? '',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 4),
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
              // Global, app-wide preferences — never a persistent
              // per-screen AppBar icon (see the "Screen header" mandatory
              // pattern in CLAUDE.md). Read via ref.read, not ref.watch —
              // this list is only (re)built each time the menu opens, not
              // reactively while it's showing, same as the rest of this
              // itemBuilder closure.
              PopupMenuItem(
                value: 'density',
                child: Row(children: [
                  Icon(
                    ref.read(isCompactDensityProvider) ? Icons.view_comfortable_outlined : Icons.view_compact_outlined,
                    size: 16, color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Text(ref.read(isCompactDensityProvider) ? 'Comfortable Rows' : 'Dense Rows'),
                ]),
              ),
              PopupMenuItem(
                value: 'open_theme',
                child: Row(children: [
                  Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(color: activePreset.primary, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Text('Theme: ${activePreset.label}'),
                  const Spacer(),
                  const Icon(Icons.chevron_right, size: 16, color: AppColors.textSecondary),
                ]),
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
              if (!kIsWeb)
                const PopupMenuItem(
                  value: 'offline_settings',
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off_outlined,
                          size: 16, color: AppColors.textSecondary),
                      SizedBox(width: 10),
                      Text('Offline Data'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'app_logs',
                child: Row(
                  children: [
                    Icon(Icons.article_outlined,
                        size: 16, color: AppColors.textSecondary),
                    SizedBox(width: 10),
                    Text('View Logs'),
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

  // Theme picker — collapsed to a single "Theme: <current>" row in the
  // avatar menu (per user request, initially collapsed rather than
  // showing all 4 presets inline every time the menu opens); tapping it
  // opens this small dialog with the actual choices. Same AlertDialog
  // pattern already used for Switch Company, deliberately not a nested/
  // expanding PopupMenuItem — PopupMenuButton's own items close the whole
  // menu on tap by default, and keeping one open to expand in place needs
  // meaningfully more custom state-management machinery than this.
  Future<void> _showThemePicker(BuildContext context, WidgetRef ref) async {
    final active = ref.read(themePresetProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose Theme'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ThemePreset.values.map((preset) {
              final config = ThemePresetConfig.all[preset]!;
              return ListTile(
                dense: true,
                leading: Container(
                  width: 16, height: 16,
                  decoration: BoxDecoration(color: config.primary, shape: BoxShape.circle),
                ),
                title: Text(config.label),
                trailing: preset == active ? const Icon(Icons.check, color: AppColors.positive) : null,
                onTap: () {
                  ref.read(themePresetProvider.notifier).state = preset;
                  Navigator.of(dialogContext).pop();
                },
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  // Screen-registered title (+ optional subtitle/status badge), used as-is
  // on mobile only (no room there for a composited company-name line — see
  // _buildDesktopTitle below for the desktop equivalent, which reuses
  // _buildSubtitleRow for its own second line instead of duplicating it).
  Widget _buildScreenTitle(BuildContext context, ScreenHeaderInfo header) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(header.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          if (_buildHelpIcon(context, header) case final icon?) icon,
        ]),
        if (_buildSubtitleRow(header) case final row?) row,
      ],
    );
  }

  // A screen's static "what this screen is for" description (helpText) —
  // shown as a small tappable icon next to the title instead of a
  // permanent subtitle line, since it never changes and shouldn't compete
  // for header space with real status info (see ScreenHeaderInfo.helpText's
  // own doc comment for the subtitle-vs-helpText distinction).
  Widget? _buildHelpIcon(BuildContext context, ScreenHeaderInfo header) {
    if (header.helpText == null) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(header.title),
            content: Text(header.helpText!),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
            ],
          ),
        ),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.help_outline, size: 15, color: AppColors.sidebarText),
        ),
      ),
    );
  }

  // The subtitle/badge/trailingBadge line beneath a screen's own title —
  // extracted so both _buildScreenTitle (mobile) and _buildDesktopTitle
  // (desktop) can render it identically without duplicating the layout.
  Widget? _buildSubtitleRow(ScreenHeaderInfo header) {
    if (header.subtitle == null && header.badgeText == null && header.trailingBadge == null) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (header.subtitle != null)
        Flexible(
          child: Text(header.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.sidebarText)),
        ),
      if (header.badgeText != null) ...[
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: (header.badgeColor ?? AppColors.positive).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(header.badgeText!,
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: header.badgeColor ?? AppColors.positive)),
        ),
      ],
      if (header.trailingBadge != null) ...[
        const SizedBox(width: 6),
        header.trailingBadge!,
      ],
    ]);
  }

  // Desktop title area: company name (tappable -> Dashboard) always shown,
  // optionally followed by " : <screen title>" when a screen has
  // registered one, with that screen's own subtitle/badge row beneath.
  // Real gap fixed 2026-08-11: company name previously vanished entirely
  // once ANY screen registered a header — a genuine safety concern in a
  // multi-company ERP, since a user had no persistent way to confirm which
  // company's books a transaction would post to. Mobile deliberately does
  // NOT get this treatment (see the `leading`/`actions` comment above) —
  // there is no spare width on a narrow AppBar for a third element
  // alongside the back/menu icon and the already-crowded actions row;
  // mobile users see the company name inside the avatar menu instead (see
  // itemBuilder's disabled header item below).
  Widget _buildDesktopTitle(BuildContext context, ScreenHeaderInfo? header, UserSession? session) {
    if (session == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          // Company name and screen title render at equal weight/size
          // (user-requested) — one continuous title line rather than a
          // label + a title, distinguished only by the separator between
          // them, not by different type styles.
          InkWell(
            onTap: () => context.go(RouteNames.dashboard),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(session.companyName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
          if (header != null) ...[
            const Text(' : ',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            Flexible(
              child: Text(header.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            if (_buildHelpIcon(context, header) case final icon?) icon,
          ],
        ]),
        if (header != null)
          if (_buildSubtitleRow(header) case final row?) row,
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
      // Fetch new menu and new company settings in parallel
      final results = await Future.wait([
        DioClient.instance.post('/rpc/fn_get_user_menu', data: {
          'p_user_id':    widget.session.userId,
          'p_client_id':  widget.session.clientId,
          'p_company_id': companyId,
        }),
        DioClient.instance.post('/rpc/fn_get_company_settings', data: {
          'p_company_id': companyId,
        }),
      ]);

      final menuList = (results[0].data as List<dynamic>)
          .map((e) => MenuModule.fromJson(e as Map<String, dynamic>))
          .toList();
      final settings = results[1].data as Map<String, dynamic>;

      widget.ref.read(sessionProvider.notifier).state =
          widget.session.copyWith(
            companyId:        companyId,
            companyName:      companyName,
            enableBarcode:    settings['enable_barcode']     as bool? ?? false,
            enablePartNumber: settings['enable_part_number'] as bool? ?? false,
            qtyEntryMode:     settings['qty_entry_mode']     as String? ?? 'PACK_AND_LOOSE',
            numberFormat:     settings['number_format']      as String? ?? 'INTERNATIONAL',
            quickInvoiceDispatchStock: settings['quick_invoice_dispatch_stock'] as bool? ?? true,
            quickInvoiceCollectCash:   settings['quick_invoice_collect_cash']   as bool? ?? true,
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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/layout/menu_feature_card.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/notification_provider.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/module_icons.dart';
import '../../../../core/utils/relative_time.dart';

/// One row from fn_dashboard_pending_actions (migration 157) — a document
/// type the CURRENT user can approve, with at least one DRAFT/pending doc.
class _PendingAction {
  final String documentType;
  final int pendingCount;
  final String route;
  _PendingAction({required this.documentType, required this.pendingCount, required this.route});

  factory _PendingAction.fromJson(Map<String, dynamic> json) => _PendingAction(
        documentType: json['document_type'] as String,
        pendingCount: (json['pending_count'] as num).toInt(),
        route: json['route'] as String,
      );
}

// Deliberately NOT using ScreenHeaderMixin — landing here right after login
// should show the company name in the shared TopBar (its own default
// fallback when no header is registered), not a plain "Dashboard" label.
// A ScreenHeaderMixin registration was tried here once and reverted after
// live testing showed it silently overrode that fallback — this rewrite
// preserves that same constraint.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  List<_PendingAction> _pendingActions = [];
  bool _loadingPending = true;
  final _favoriteSearchCtrl = TextEditingController();
  String _favoriteSearch = '';

  @override
  void initState() {
    super.initState();
    _loadPendingActions();
    _favoriteSearchCtrl.addListener(() => setState(() => _favoriteSearch = _favoriteSearchCtrl.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _favoriteSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPendingActions() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      final res = await DioClient.instance.post('/rpc/fn_dashboard_pending_actions', data: {
        'p_client_id': session.clientId,
        'p_company_id': session.companyId,
        'p_user_id': session.userId,
      });
      final list = (res.data as List<dynamic>)
          .map((e) => _PendingAction.fromJson(e as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() { _pendingActions = list; _loadingPending = false; });
    } catch (e, st) {
      AppLogger.error('DashboardPendingActions', e, st);
      if (mounted) setState(() => _loadingPending = false);
    }
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final menu = ref.watch(menuProvider);
    final notifications = ref.watch(notificationProvider);

    final favorites = [
      for (final m in menu)
        for (final g in m.groups)
          for (final f in g.features)
            if (f.isFavorite) f,
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildHero(session),
        const SizedBox(height: 24),
        if (favorites.isNotEmpty) ...[
          _sectionTitle('Favorites'),
          _buildFavoritesStrip(favorites),
          const SizedBox(height: 24),
        ],
        _sectionTitle('Quick Access'),
        _buildQuickAccess(menu),
        const SizedBox(height: 24),
        _sectionTitle('Pending Actions'),
        _buildPendingActions(),
        const SizedBox(height: 24),
        LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth > 900;
          final recent = Expanded(child: _buildRecentActivitySection(notifications));
          final status = Expanded(child: _buildStatusAndLinksSection(session));
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  recent, const SizedBox(width: 16), status,
                ])
              : Column(children: [
                  _buildRecentActivitySection(notifications),
                  const SizedBox(height: 24),
                  _buildStatusAndLinksSection(session),
                ]);
        }),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      );

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );

  // ---- Hero ----------------------------------------------------------

  Widget _buildHero(UserSession? session) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_greeting()}, ${session?.fullName ?? ''}',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(session?.companyName ?? '',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ]),
          ),
        ]),
      );

  // ---- Favorites (user-starred menu items, hidden entirely when empty) --
  // Deliberately a smaller, compact tile than Quick Access's own module
  // tile (160 wide) — per direct user feedback, a favorite is meant to be
  // a dense, glanceable shortcut strip, not another full drilldown card
  // (that's what MenuFeatureCard, used on the Module/Group landing pages,
  // is for). A search box filters by name once the list gets long enough
  // that scanning it visually stops being fast — the whole strip still
  // only shows/hides as a section, never an empty-state message, since
  // it's already hidden entirely when there are zero favorites at all.

  Widget _buildFavoritesStrip(List<MenuFeature> favorites) {
    final filtered = _favoriteSearch.isEmpty
        ? favorites
        : favorites.where((f) => f.featureName.toLowerCase().contains(_favoriteSearch)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (favorites.length > 4)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: 260,
            child: TextField(
              controller: _favoriteSearchCtrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search favorites…',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _favoriteSearch.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: _favoriteSearchCtrl.clear),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
      if (filtered.isEmpty)
        const Text('No favorites match your search.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
      else
        Wrap(
          spacing: 10, runSpacing: 10,
          children: filtered.map((f) => _FavoriteTile(feature: f)).toList(),
        ),
    ]);
  }

  // ---- Quick Access (one card per accessible module) ------------------

  Widget _buildQuickAccess(List<MenuModule> menu) {
    if (menu.isEmpty) return _card(child: const Text('No modules available', style: TextStyle(color: AppColors.textSecondary)));
    return Wrap(
      spacing: 12, runSpacing: 12,
      children: menu.map((m) {
        final hasAnyFeature = m.groups.any((g) => g.features.isNotEmpty);
        return SizedBox(
          width: 160,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            // Opens the module's own landing page (every real group +
            // feature, drilldown-style) instead of jumping straight into
            // an arbitrary first screen — user-requested, since the old
            // behavior gave no sense of what else lives in that module.
            onTap: hasAnyFeature ? () => context.go(RouteNames.modulePath(m.moduleCode)) : null,
            child: _card(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(moduleIconFor(m.moduleCode), color: AppColors.primary, size: 24),
                const SizedBox(height: 10),
                Text(m.moduleName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ---- Pending Actions --------------------------------------------------

  Widget _buildPendingActions() {
    if (_loadingPending) {
      return _card(child: const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())));
    }
    if (_pendingActions.isEmpty) {
      return _card(
        child: const Text('Nothing needs your attention right now.', style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return _card(
      child: Column(
        children: _pendingActions.map((a) {
          return InkWell(
            onTap: () => context.go(a.route),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Expanded(child: Text(a.documentType, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.secondary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                  child: Text('${a.pendingCount}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.secondary)),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 18, color: AppColors.textDisabled),
              ]),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---- Recent Activity ----------------------------------------------

  Widget _buildRecentActivitySection(List<AppNotification> notifications) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('Recent Activity'),
      _card(
        child: notifications.isEmpty
            ? const Text('No recent activity.', style: TextStyle(color: AppColors.textSecondary))
            : Column(
                children: notifications.take(8).map((n) {
                  return InkWell(
                    onTap: () {
                      if (!n.isRead) ref.read(notificationProvider.notifier).markRead(n.id);
                      if (n.linkRoute != null) context.go(n.linkRoute!);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 8, height: 8, margin: const EdgeInsets.only(top: 4, right: 10),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: n.isRead ? Colors.transparent : AppColors.primary),
                        ),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(n.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            if (n.message != null)
                              Text(n.message!, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                          ]),
                        ),
                        Text(relativeTime(n.createdAt), style: const TextStyle(fontSize: 11, color: AppColors.textDisabled)),
                      ]),
                    ),
                  );
                }).toList(),
              ),
      ),
    ]);
  }

  // ---- Sync & Offline Status + Helpful Links -------------------------

  Widget _buildStatusAndLinksSection(UserSession? session) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('Sync & Offline Status'),
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(session?.offlineMode == true ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                size: 18, color: session?.offlineMode == true ? AppColors.secondary : AppColors.positive),
            const SizedBox(width: 8),
            Expanded(
              child: Text(session?.offlineMode == true ? 'Working Offline' : 'Online',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ]),
          if (!kIsWeb) ...[
            const SizedBox(height: 10),
            Consumer(builder: (context, ref, _) {
              final pending = ref.watch(pendingSyncCountProvider);
              return pending.when(
                data: (count) => Text(
                  count == 0 ? 'All documents synced' : '$count document${count == 1 ? '' : 's'} pending sync',
                  style: TextStyle(fontSize: 12, color: count == 0 ? AppColors.textSecondary : AppColors.secondary),
                ),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              );
            }),
          ],
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => context.go(RouteNames.offlineSettings),
            child: const Text('Manage Offline Data'),
          ),
        ]),
      ),
      const SizedBox(height: 24),
      _sectionTitle('Helpful Links'),
      _card(
        child: Column(children: [
          _linkRow(Icons.article_outlined, 'View Logs', () => context.go(RouteNames.appLogs)),
          if (!kIsWeb) _linkRow(Icons.cloud_off_outlined, 'Offline Data', () => context.go(RouteNames.offlineSettings)),
          _linkRow(Icons.lock_reset_outlined, 'Change Password', () => context.go(RouteNames.changePassword)),
        ]),
      ),
    ]);
  }

  Widget _linkRow(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Icon(icon, size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          ]),
        ),
      );
}

/// Compact Favorites-strip tile — deliberately smaller than Quick Access's
/// own 160-wide module tile (per direct user feedback) and simpler than
/// the full MenuFeatureCard used on the Module/Group landing pages: just
/// an icon, the name, and a filled star that un-favorites on tap.
class _FavoriteTile extends ConsumerWidget {
  final MenuFeature feature;
  const _FavoriteTile({required this.feature});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final icon = menuFeatureIcons[feature.featureCode] ?? Icons.grid_view_outlined;
    return SizedBox(
      width: 130,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.go(feature.screenName),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: AppColors.primary, size: 20),
              const Spacer(),
              if (session != null)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => toggleMenuFavorite(ref, session, feature.featureCode, false),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.star, size: 16, color: AppColors.secondary),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            Text(feature.featureName,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

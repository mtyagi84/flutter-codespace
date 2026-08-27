import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../router/route_names.dart';
import '../theme/app_colors.dart';
import '../theme/theme_presets.dart';
import '../utils/responsive.dart';

class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  static const _moduleIcons = <String, IconData>{
    'AD': Icons.admin_panel_settings_outlined,
    'SL': Icons.point_of_sale_outlined,
    'PR': Icons.shopping_cart_outlined,
    'IN': Icons.inventory_2_outlined,
    'FN': Icons.account_balance_outlined,
  };

  bool _seededInitialExpansion = false;
  // Shared between whichever of the two ListViews (collapsed rail vs
  // expanded tree) is actually mounted at a time — never both at once, so
  // one controller is enough.
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // One-time seed, run after the first frame (menu + route are both
  // available by then): every module starts collapsed EXCEPT the one
  // containing whatever screen the user is currently on (e.g. a refresh
  // mid-work inside Sales keeps Sales open) — landing on the Dashboard, with
  // no module active, means every module starts closed. Guarded by
  // _seededInitialExpansion (not "is the provider set still empty") so a
  // user who deliberately collapses that one auto-opened module doesn't get
  // it silently re-added on the next rebuild.
  void _seedInitialExpansion(List<MenuModule> menu, String path) {
    if (_seededInitialExpansion) return;
    // menu loads asynchronously after login — don't consume the one-time
    // seed on an empty tree, or the real menu arriving a frame later would
    // never get its active module auto-opened.
    if (menu.isEmpty) return;
    _seededInitialExpansion = true;
    final active = menu.where((m) => m.groups.any((g) =>
        g.features.any((f) => path.startsWith(f.screenName)) ||
        path == RouteNames.groupPath(g.groupCode)));
    if (active.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sidebarExpandedModulesProvider.notifier).state = {
        ...ref.read(sidebarExpandedModulesProvider),
        for (final m in active) m.moduleCode,
      };
    });
  }

  // ConsumerState's own `ref` field is available in every instance method
  // below, not just build() — read directly where needed rather than
  // threading the active preset through every nested _build* signature.
  ThemePresetConfig get _activePreset => ThemePresetConfig.all[ref.watch(themePresetProvider)]!;

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider);
    final mobile = Responsive.isMobile(context);
    // Tablet zone (600-1024px) forces collapsed regardless of the user's
    // own toggle — must match AppShell's own identical override exactly,
    // or the AnimatedContainer there sizes to 56px while this widget
    // still thinks it should render its full 240px expanded content,
    // overflowing/clipping inside the now-narrower container.
    //
    // Mobile is the OPPOSITE forced case, and a real bug: sidebarCollapsedProvider
    // is a plain global toggle with no concept of "which layout is looking
    // at it" — a user who collapsed the sidebar on desktop would have that
    // SAME state leak into the mobile Drawer, rendering it as tiny
    // icon-only buttons with no text labels at all (nonsensical for a
    // drawer, which only ever appears when explicitly opened to navigate,
    // never needs to save persistent screen space the way a docked
    // desktop sidebar does).
    final collapsed = mobile ? false : (Responsive.isTablet(context) ? true : ref.watch(sidebarCollapsedProvider));
    final path      = GoRouterState.of(context).matchedLocation;
    final activePreset = _activePreset;

    _seedInitialExpansion(menu, path);

    return Container(
      color: activePreset.primary,
      // No app-branding header block — the sidebar's module list starts
      // directly at the top (branding removed per explicit request; the
      // shared TopBar's own company name is the app's identity marker now).
      //
      // A persistent, visible scrollbar — the default desktop/web scrollbar
      // is thin enough to be easy to miss entirely once several modules are
      // open and the tree overflows the viewport, same bug class already
      // found and fixed on the Reporting Engine's own table this session
      // (sakal_report_table.dart's ScrollbarTheme) — themed for THIS dark
      // surface (light/semi-transparent white) rather than that fix's
      // light-surface colors.
      child: ScrollbarTheme(
        data: ScrollbarThemeData(
          thickness: const WidgetStatePropertyAll(8),
          radius: const Radius.circular(4),
          trackVisibility: const WidgetStatePropertyAll(true),
          thumbVisibility: const WidgetStatePropertyAll(true),
          trackColor: const WidgetStatePropertyAll(Colors.white12),
          trackBorderColor: const WidgetStatePropertyAll(Colors.white12),
          thumbColor: const WidgetStatePropertyAll(Colors.white38),
        ),
        child: Scrollbar(
          controller: _scrollController,
          child: collapsed
              ? _buildCollapsedList(menu, path)
              : _buildExpandedList(menu, path, mobile),
        ),
      ),
    );
  }

  // ── Collapsed — icon-only list ──────────────────────────────
  // Tapping a module icon opens a popup flyout listing that module's
  // groups/features, rather than trying to expand the sidebar itself.
  // Real bug, fixed live: on tablet-width windows (600-1024px, see
  // AppShell's own forced-collapse override) the sidebar's expand toggle
  // is deliberately defeated to avoid a real overflow (a full 240px
  // sidebar leaves too little room for content at that width) — so the
  // old "tap to expand" behavior here silently did nothing, leaving the
  // user stuck unable to reach any other page. A popup flyout lets
  // navigation work without ever needing to expand.
  Widget _buildCollapsedList(List<MenuModule> menu, String path) {
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: menu.map((m) {
        final icon = _moduleIcons[m.moduleCode] ?? Icons.apps_outlined;
        final hasActive = m.groups.any((g) =>
            g.features.any((f) => path.startsWith(f.screenName)));
        final isGroupActive = m.groups.any((g) =>
            path == RouteNames.groupPath(g.groupCode));
        final active = hasActive || isGroupActive;

        return Tooltip(
          message: m.moduleName,
          preferBelow: false,
          child: PopupMenuButton<String>(
            tooltip: '',
            offset: const Offset(56, 0),
            itemBuilder: (context) => [
              for (final g in m.groups) ...[
                PopupMenuItem<String>(
                  value: RouteNames.groupPath(g.groupCode),
                  child: Text(g.groupName,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                for (final f in g.features)
                  PopupMenuItem<String>(
                    value: f.screenName,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(f.featureName),
                    ),
                  ),
              ],
            ],
            onSelected: (route) => context.go(route),
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? _activePreset.accent : Colors.transparent,
                border: active
                    ? Border(
                        left: BorderSide(color: _activePreset.secondary, width: 3))
                    : null,
              ),
              child: Icon(icon,
                  size: 20,
                  color: active ? Colors.white : AppColors.sidebarText),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── Expanded — full 3-level tree ────────────────────────────
  // [mobile] makes every row touch-friendly (44-48px, the standard
  // minimum tap-target guideline) with larger text — the desktop sidebar
  // stays as compact as before (mouse clicks don't need the same target
  // size, and a persistent 240px column benefits from fitting more without
  // scrolling); only the mobile Drawer, which has a full screen height to
  // work with and is opened specifically to be tapped, gets the larger
  // sizing. A real complaint: the original 32-40px rows/12px text were
  // sized for the desktop case and never had a mobile-specific pass.
  Widget _buildExpandedList(List<MenuModule> menu, String path, bool mobile) {
    final expandedModules = ref.watch(sidebarExpandedModulesProvider);
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: menu.map((m) => _buildModule(m, path, mobile, expandedModules.contains(m.moduleCode))).toList(),
    );
  }

  void _toggleModule(String moduleCode, bool isExpanded) {
    final current = ref.read(sidebarExpandedModulesProvider);
    ref.read(sidebarExpandedModulesProvider.notifier).state = isExpanded
        ? ({...current}..remove(moduleCode))
        : ({...current}..add(moduleCode));
  }

  Widget _buildModule(MenuModule module, String path, bool mobile, bool isExpanded) {
    final icon = _moduleIcons[module.moduleCode] ?? Icons.apps_outlined;
    final hasActive = module.groups.any((g) =>
        g.features.any((f) => path.startsWith(f.screenName)) ||
        path == RouteNames.groupPath(g.groupCode));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Module header
        InkWell(
          onTap: () => _toggleModule(module.moduleCode, isExpanded),
          child: Container(
            height: mobile ? 52 : 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: hasActive && !isExpanded
                  ? _activePreset.accent
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: mobile ? 20 : 16,
                    color: hasActive
                        ? Colors.white70
                        : AppColors.sidebarText.withValues(alpha: 0.6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    module.moduleName.toUpperCase(),
                    style: TextStyle(
                      fontSize: mobile ? 13 : 11,
                      fontWeight: FontWeight.w700,
                      color: hasActive
                          ? Colors.white
                          : AppColors.sidebarText.withValues(alpha: 0.7),
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeInOut,
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: mobile ? 20 : 16,
                    color: AppColors.sidebarText.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Groups — AnimatedSize (inside ClipRect, so mid-animation content
        // can't spill outside the sidebar's own bounds) slides the group
        // list open/closed instead of the previous instant show/hide.
        ClipRect(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...module.groups.map((g) => _buildGroup(g, path, mobile)),
                      const SizedBox(height: 4),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }

  Widget _buildGroup(MenuGroup group, String path, bool mobile) {
    final groupPath   = RouteNames.groupPath(group.groupCode);
    final isGroupActive = path == groupPath;
    final hasFeatureActive =
        group.features.any((f) => path.startsWith(f.screenName));
    final active = isGroupActive || hasFeatureActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header — clickable → group landing page
        InkWell(
          onTap: () {
            Scaffold.of(context).closeDrawer();
            context.go(groupPath);
          },
          child: Container(
            height: mobile ? 48 : 34,
            padding: const EdgeInsets.only(left: 28, right: 12),
            decoration: BoxDecoration(
              color: active ? _activePreset.accent.withValues(alpha: 0.6) : Colors.transparent,
              border: isGroupActive
                  ? Border(
                      left: BorderSide(color: _activePreset.secondary, width: 3))
                  : null,
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined,
                    size: mobile ? 18 : 13,
                    color: active
                        ? Colors.white70
                        : AppColors.sidebarText.withValues(alpha: 0.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.groupName,
                    style: TextStyle(
                      fontSize: mobile ? 13 : 11,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? Colors.white
                          : AppColors.sidebarText.withValues(alpha: 0.6),
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Icon(Icons.arrow_forward_ios,
                    size: mobile ? 12 : 10,
                    color: AppColors.sidebarText.withValues(alpha: 0.4)),
              ],
            ),
          ),
        ),

        // Feature items
        ...group.features.map((f) => _buildFeature(f, path, mobile)),
        const SizedBox(height: 2),
      ],
    );
  }

  Widget _buildFeature(MenuFeature feature, String path, bool mobile) {
    final isActive =
        path == feature.screenName || path.startsWith('${feature.screenName}/');

    return InkWell(
      onTap: () {
        Scaffold.of(context).closeDrawer();
        context.go(feature.screenName);
      },
      child: Container(
        height: mobile ? 48 : 32,
        padding: const EdgeInsets.only(left: 48, right: 16),
        decoration: BoxDecoration(
          color: isActive ? _activePreset.accent : Colors.transparent,
          border: isActive
              ? Border(
                  left: BorderSide(color: _activePreset.secondary, width: 3))
              : null,
        ),
        alignment: Alignment.centerLeft,
        child: Text(
          feature.featureName,
          style: TextStyle(
            fontSize: mobile ? 14 : 12,
            color: isActive ? Colors.white : AppColors.sidebarText,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

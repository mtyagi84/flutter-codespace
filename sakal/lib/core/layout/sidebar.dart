import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/app_config.dart';
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
  final Set<String> _expandedModules = {};

  static const _moduleIcons = <String, IconData>{
    'AD': Icons.admin_panel_settings_outlined,
    'SL': Icons.point_of_sale_outlined,
    'PR': Icons.shopping_cart_outlined,
    'IN': Icons.inventory_2_outlined,
    'FN': Icons.account_balance_outlined,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final menu = ref.read(menuProvider);
      setState(() {
        for (final m in menu) { _expandedModules.add(m.moduleCode); }
      });
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

    return Container(
      color: activePreset.primary,
      child: Column(
        children: [
          _buildHeader(collapsed),
          Expanded(
            child: collapsed
                ? _buildCollapsedList(menu, path)
                : _buildExpandedList(menu, path, mobile),
          ),
        ],
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────
  Widget _buildHeader(bool collapsed) {
    return Container(
      height: 64,
      padding: EdgeInsets.symmetric(horizontal: collapsed ? 12 : 16),
      decoration: BoxDecoration(
        color: _activePreset.primary,
        border: const Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: collapsed
          ? const Center(
              child: Text('S',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            )
          : Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text('S',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: _activePreset.primary)),
                ),
                const SizedBox(width: 10),
                const Text(AppConfig.appName,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 1.5)),
              ],
            ),
    );
  }

  // ── Collapsed — icon-only list ──────────────────────────────
  Widget _buildCollapsedList(List<MenuModule> menu, String path) {
    return ListView(
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
          child: InkWell(
            onTap: () =>
                ref.read(sidebarCollapsedProvider.notifier).state = false,
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
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: menu.map((m) => _buildModule(m, path, mobile)).toList(),
    );
  }

  Widget _buildModule(MenuModule module, String path, bool mobile) {
    final isExpanded = _expandedModules.contains(module.moduleCode);
    final icon = _moduleIcons[module.moduleCode] ?? Icons.apps_outlined;
    final hasActive = module.groups.any((g) =>
        g.features.any((f) => path.startsWith(f.screenName)) ||
        path == RouteNames.groupPath(g.groupCode));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Module header
        InkWell(
          onTap: () => setState(() => isExpanded
              ? _expandedModules.remove(module.moduleCode)
              : _expandedModules.add(module.moduleCode)),
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
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: mobile ? 20 : 16,
                  color: AppColors.sidebarText.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),

        // Groups
        if (isExpanded)
          ...module.groups.map((g) => _buildGroup(g, path, mobile)),
        if (isExpanded) const SizedBox(height: 4),
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

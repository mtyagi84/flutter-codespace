import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/app_config.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../router/route_names.dart';
import '../theme/app_colors.dart';
import '../theme/theme_presets.dart';

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
    final menu      = ref.watch(menuProvider);
    final collapsed = ref.watch(sidebarCollapsedProvider);
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
                : _buildExpandedList(menu, path),
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
  Widget _buildExpandedList(List<MenuModule> menu, String path) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: menu.map((m) => _buildModule(m, path)).toList(),
    );
  }

  Widget _buildModule(MenuModule module, String path) {
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
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: hasActive && !isExpanded
                  ? _activePreset.accent
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: hasActive
                        ? Colors.white70
                        : AppColors.sidebarText.withValues(alpha: 0.6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    module.moduleName.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
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
                  size: 16,
                  color: AppColors.sidebarText.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),

        // Groups
        if (isExpanded)
          ...module.groups.map((g) => _buildGroup(g, path)),
        if (isExpanded) const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildGroup(MenuGroup group, String path) {
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
            height: 34,
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
                    size: 13,
                    color: active
                        ? Colors.white70
                        : AppColors.sidebarText.withValues(alpha: 0.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group.groupName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? Colors.white
                          : AppColors.sidebarText.withValues(alpha: 0.6),
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Icon(Icons.arrow_forward_ios,
                    size: 10,
                    color: AppColors.sidebarText.withValues(alpha: 0.4)),
              ],
            ),
          ),
        ),

        // Feature items
        ...group.features.map((f) => _buildFeature(f, path)),
        const SizedBox(height: 2),
      ],
    );
  }

  Widget _buildFeature(MenuFeature feature, String path) {
    final isActive =
        path == feature.screenName || path.startsWith('${feature.screenName}/');

    return InkWell(
      onTap: () {
        Scaffold.of(context).closeDrawer();
        context.go(feature.screenName);
      },
      child: Container(
        height: 32,
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
            fontSize: 12,
            color: isActive ? Colors.white : AppColors.sidebarText,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

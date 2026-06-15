import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/app_config.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../theme/app_colors.dart';

class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key});

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final Set<String> _expanded = {};

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
    // Expand all modules by default
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final menu = ref.read(menuProvider);
      setState(() {
        for (final m in menu) _expanded.add(m.moduleCode);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider);
    final currentPath = GoRouterState.of(context).matchedLocation;

    return Container(
      width: 240,
      color: AppColors.sidebarBg,
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: menu.map((m) => _buildModule(m, currentPath)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.primaryDark,
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: const Text('S',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary)),
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

  Widget _buildModule(MenuModule module, String currentPath) {
    final isExpanded = _expanded.contains(module.moduleCode);
    final icon = _moduleIcons[module.moduleCode] ?? Icons.apps_outlined;
    final hasActiveFeature = module.features
        .any((f) => currentPath.startsWith(f.screenName));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Module header
        InkWell(
          onTap: () => setState(() => isExpanded
              ? _expanded.remove(module.moduleCode)
              : _expanded.add(module.moduleCode)),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: hasActiveFeature && !isExpanded
                  ? AppColors.sidebarItemActive
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: hasActiveFeature
                        ? Colors.white70
                        : AppColors.sidebarText.withOpacity(0.6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    module.moduleName.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: hasActiveFeature
                          ? Colors.white
                          : AppColors.sidebarText.withOpacity(0.7),
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 16,
                  color: AppColors.sidebarText.withOpacity(0.5),
                ),
              ],
            ),
          ),
        ),
        // Feature items
        if (isExpanded)
          ...module.features.map((f) => _buildFeature(f, currentPath)),
        if (isExpanded) const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildFeature(MenuFeature feature, String currentPath) {
    final isActive = currentPath == feature.screenName ||
        currentPath.startsWith('${feature.screenName}/');

    return InkWell(
      onTap: () => context.go(feature.screenName),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: isActive ? AppColors.sidebarItemActive : Colors.transparent,
          border: isActive
              ? const Border(
                  left: BorderSide(color: AppColors.secondary, width: 3))
              : null,
        ),
        padding: const EdgeInsets.only(left: 40, right: 16),
        alignment: Alignment.centerLeft,
        child: Text(
          feature.featureName,
          style: TextStyle(
            fontSize: 13,
            color: isActive ? Colors.white : AppColors.sidebarText,
            fontWeight:
                isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

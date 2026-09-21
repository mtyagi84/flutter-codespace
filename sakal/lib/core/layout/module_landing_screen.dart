import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../theme/app_colors.dart';
import 'menu_feature_card.dart';

/// Module-level landing page — replaces the old behavior of a Dashboard
/// module tile jumping straight into an arbitrary first screen. Shows
/// every group the user actually has access to under this module
/// (Transactions, Reports, Masters, Setup, whatever real groups exist —
/// never a forced 2-bucket simplification), each as its own section with
/// its features as cards directly beneath it, so one page answers "what
/// can I do in this module" and every card click goes straight to its
/// screen (no extra hop through GroupLandingScreen needed).
class ModuleLandingScreen extends ConsumerWidget {
  final String moduleCode;
  const ModuleLandingScreen({required this.moduleCode, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menu = ref.watch(menuProvider);
    final module = menu.where((m) => m.moduleCode == moduleCode).firstOrNull;

    if (module == null) {
      return const Center(child: Text('Module not found'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            module.moduleName,
            style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            '${module.groups.fold<int>(0, (sum, g) => sum + g.features.length)} function(s) available',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 28),
          for (final group in module.groups) _buildGroupSection(group),
        ],
      ),
    );
  }

  Widget _buildGroupSection(MenuGroup group) {
    if (group.features.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.groupName,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: group.features.map((f) => MenuFeatureCard(feature: f)).toList(),
          ),
        ],
      ),
    );
  }
}

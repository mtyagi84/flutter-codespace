import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../theme/app_colors.dart';
import 'menu_feature_card.dart';

class GroupLandingScreen extends ConsumerWidget {
  final String groupCode;
  const GroupLandingScreen({required this.groupCode, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menu = ref.watch(menuProvider);

    MenuGroup? group;
    String moduleName = '';
    for (final module in menu) {
      for (final g in module.groups) {
        if (g.groupCode == groupCode) {
          group = g;
          moduleName = module.moduleName;
          break;
        }
      }
      if (group != null) break;
    }

    if (group == null) {
      return const Center(child: Text('Group not found'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Breadcrumb
          Row(
            children: [
              Text(moduleName,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.chevron_right,
                    size: 16, color: AppColors.textSecondary),
              ),
              Text(group.groupName,
                  style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            group.groupName,
            style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text('${group.features.length} functions available',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 32),

          // Feature cards
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: group.features
                .map((f) => MenuFeatureCard(feature: f))
                .toList(),
          ),
        ],
      ),
    );
  }
}

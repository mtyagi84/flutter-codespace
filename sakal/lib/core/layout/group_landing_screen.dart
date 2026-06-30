import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../theme/app_colors.dart';

class GroupLandingScreen extends ConsumerWidget {
  final String groupCode;
  const GroupLandingScreen({required this.groupCode, super.key});

  static const _featureIcons = <String, IconData>{
    'AD-CMP': Icons.business_outlined,
    'AD-LOC': Icons.location_on_outlined,
    'AD-CUR': Icons.currency_exchange_outlined,
    'AD-USR': Icons.people_outline,
    'AD-PRM': Icons.security_outlined,
    'SL-INV': Icons.receipt_long_outlined,
    'SL-RET': Icons.assignment_return_outlined,
    'SL-RCP': Icons.payments_outlined,
    'PR-PO':  Icons.shopping_bag_outlined,
    'PR-GRN': Icons.local_shipping_outlined,
    'PR-INV': Icons.description_outlined,
    'PR-PAY': Icons.account_balance_wallet_outlined,
    'IN-STK': Icons.inventory_2_outlined,
    'IN-TRF': Icons.swap_horiz_outlined,
    'IN-ADJ': Icons.tune_outlined,
    'FN-JRN': Icons.edit_note_outlined,
    'FN-CBK': Icons.menu_book_outlined,
    'FN-TRB': Icons.balance_outlined,
    'FN-PNL': Icons.trending_up_outlined,
    'FN-BSH': Icons.account_balance_outlined,
  };

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
                .map((f) => _FeatureCard(
                      feature: f,
                      icon: _featureIcons[f.featureCode] ?? Icons.grid_view_outlined,
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final MenuFeature feature;
  final IconData icon;

  const _FeatureCard({required this.feature, required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
        child: InkWell(
          onTap: () => context.go(feature.screenName),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: AppColors.primary, size: 24),
                ),
                const SizedBox(height: 16),
                Text(feature.featureName,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text('Open',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.secondary,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_forward,
                        size: 12, color: AppColors.secondary),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

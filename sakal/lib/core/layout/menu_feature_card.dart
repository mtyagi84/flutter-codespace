import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/menu_models.dart';
import '../providers/session_provider.dart';
import '../theme/app_colors.dart';

/// Icon lookup shared by every menu drilldown surface (GroupLandingScreen,
/// ModuleLandingScreen) — extracted from GroupLandingScreen's own
/// originally-private map so both pages benefit from any future addition
/// equally, instead of drifting into two copies. Still only covers a
/// fraction of the ~100+ seeded feature codes — falls back to a generic
/// icon for anything not listed.
const menuFeatureIcons = <String, IconData>{
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

/// A single clickable feature tile — used by GroupLandingScreen,
/// ModuleLandingScreen and the Dashboard's Favorites strip so all three
/// drilldown surfaces share one look and one favorite-toggle behavior.
class MenuFeatureCard extends ConsumerWidget {
  final MenuFeature feature;

  const MenuFeatureCard({required this.feature, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final icon = menuFeatureIcons[feature.featureCode] ?? Icons.grid_view_outlined;

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
                Row(
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
                    const Spacer(),
                    if (session != null)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                        iconSize: 18,
                        icon: Icon(
                          feature.isFavorite ? Icons.star : Icons.star_border,
                          color: feature.isFavorite ? AppColors.secondary : AppColors.textSecondary,
                        ),
                        tooltip: feature.isFavorite ? 'Remove from favorites' : 'Add to favorites',
                        onPressed: () => toggleMenuFavorite(ref, session, feature.featureCode, !feature.isFavorite),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(feature.featureName,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Text('Open',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.secondary,
                            fontWeight: FontWeight.w500)),
                    SizedBox(width: 4),
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

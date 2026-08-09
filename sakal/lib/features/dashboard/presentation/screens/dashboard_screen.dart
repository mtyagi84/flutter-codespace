import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

// Deliberately NOT using ScreenHeaderMixin — landing here right after login
// should show the company name in the shared TopBar (its own default
// fallback when no header is registered), not a plain "Dashboard" label.
// A ScreenHeaderMixin registration was tried here once and reverted after
// live testing showed it silently overrode that fallback.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 72, color: AppColors.positive),
          SizedBox(height: 20),
          Text(
            'Welcome to SAKAL ERP',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Dashboard — coming soon',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

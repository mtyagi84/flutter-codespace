import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/theme/app_colors.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with ScreenHeaderMixin<DashboardScreen> {
  @override
  ScreenHeaderInfo buildScreenHeader() => const ScreenHeaderInfo(title: 'Dashboard');

  @override
  Widget build(BuildContext context) {
    // Title lives in the shared TopBar via ScreenHeaderMixin (see
    // CLAUDE.md's "Screen header" pattern) — not rendered here as body content.
    refreshScreenHeader();
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

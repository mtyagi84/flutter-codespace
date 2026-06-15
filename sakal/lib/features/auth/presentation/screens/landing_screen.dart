import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  _buildLogo(),
                  const SizedBox(height: 12),
                  Text(
                    AppConfig.appTagline,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withOpacity(0.65),
                      letterSpacing: 0.4,
                    ),
                  ),
                  const Spacer(flex: 3),
                  _LandingButton(
                    label: 'Sign In',
                    filled: false,
                    onTap: () => context.go(RouteNames.login),
                  ),
                  const SizedBox(height: 16),
                  _LandingButton(
                    label: 'Register Your Business',
                    filled: true,
                    onTap: () => context.go(RouteNames.register),
                  ),
                  const Spacer(),
                  Text(
                    '${AppConfig.companyName}  ·  v${AppConfig.appVersion}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.35),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
          ),
          alignment: Alignment.center,
          child: const Text(
            'S',
            style: TextStyle(
              fontSize: 52,
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          AppConfig.appName,
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 4,
          ),
        ),
      ],
    );
  }
}

class _LandingButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _LandingButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: filled
          ? ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.secondary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            )
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
    );
  }
}

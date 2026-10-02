import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';

/// Temporary landing screen after a successful PIN login — proves the full
/// auth chain (device setup → PIN login → JWT → menu fetch) works end to
/// end before the real New Sale screen (cart, scan, tender, promotions,
/// loyalty — see docs/pos/mockups/03_new_sale.html) is built on top of it.
/// Replace this file's body, not its route, when that screen lands — see
/// docs/pos/10_phase_plan.md's recommended build order.
class PosSalePlaceholderScreen extends ConsumerWidget {
  const PosSalePlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text('SAKAL POS — ${session?.posTerminalName ?? 'Till'}'),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: AppColors.positive, size: 48),
            const SizedBox(height: 12),
            Text('Signed in as ${session?.fullName ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            const Text(
              'New Sale screen is the next build phase — see docs/pos/10_phase_plan.md.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () {
                ref.read(sessionProvider.notifier).state = null;
                context.go(RouteNames.posLogin);
              },
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

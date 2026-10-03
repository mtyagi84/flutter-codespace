import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';

/// The "This isn't a POS till session…" (or similar guard) error block,
/// shared by every POS screen that requires `session.posTerminalId`/
/// `locationId` to be set. Previously duplicated near-identically across 5
/// screens with only a Retry button and no way out of the dead end other
/// than the browser back button — now also offers "Go to POS Login".
Widget buildPosSessionGuardError(BuildContext context, String message, VoidCallback onRetry) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.negative)),
        const SizedBox(height: 14),
        Wrap(alignment: WrapAlignment.center, spacing: 10, children: [
          TextButton(onPressed: onRetry, child: const Text('Retry')),
          FilledButton(onPressed: () => context.go(RouteNames.posLogin), child: const Text('Go to POS Login')),
        ]),
      ]),
    ),
  );
}

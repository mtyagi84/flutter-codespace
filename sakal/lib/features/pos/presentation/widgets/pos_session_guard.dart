import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';

/// The "This isn't a POS till session…" (or similar guard) error block,
/// shared by every POS screen that requires `session.posTerminalId`/
/// `locationId` to be set. Previously duplicated near-identically across 5
/// screens with only a Retry button and no way out of the dead end other
/// than the browser back button — now also offers "Go to POS Login".
///
/// Real gap found live 2026-10-16: "Go to POS Login" alone can still be a
/// dead end — PosPinLoginScreen itself had no exit of its own (see its own
/// new "Exit to main app" link), so a user who landed here by mistake (not
/// actually on a till) had no way back to the regular back-office app at
/// all short of manually editing the URL. Added here too for the same
/// reason.
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
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => context.go(RouteNames.landing),
          child: const Text('Exit to main app', style: TextStyle(fontSize: 12.5)),
        ),
      ]),
    ),
  );
}

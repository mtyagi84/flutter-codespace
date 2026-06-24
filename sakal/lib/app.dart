import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/session_provider.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class SakalApp extends ConsumerWidget {
  const SakalApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep sessionNotifier in sync with sessionProvider so GoRouter's
    // refreshListenable fires on every login and logout.
    ref.listen(sessionProvider, (_, next) {
      sessionNotifier.value = next;
    });
    return MaterialApp.router(
      title: 'SAKAL ERP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: appRouter,
    );
  }
}

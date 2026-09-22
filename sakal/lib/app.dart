import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/session_provider.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_presets.dart';

class SakalApp extends ConsumerWidget {
  const SakalApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep sessionNotifier in sync with sessionProvider so GoRouter's
    // refreshListenable fires on every login and logout.
    ref.listen(sessionProvider, (_, next) {
      sessionNotifier.value = next;
    });
    final activePreset = ref.watch(themePresetProvider);
    return MaterialApp.router(
      // Browser tab / OS window title only — a temporary, cosmetic rename
      // (2026-09-22, user-requested: "hide the word SAKAL from visible UI"
      // for now). The product itself is still SAKAL everywhere else
      // (AppConfig.appName, docs, code) — this is deliberately the ONLY
      // place the display title is overridden.
      title: 'LiteLink ERP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forPreset(ThemePresetConfig.all[activePreset]!),
      routerConfig: appRouter,
    );
  }
}

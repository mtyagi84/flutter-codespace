import 'package:flutter/material.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class SakalApp extends StatelessWidget {
  const SakalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SAKAL ERP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: appRouter,
      // SelectionArea must be inside MaterialApp so MaterialLocalizations exists.
      builder: (context, child) =>
          SelectionArea(child: child ?? const SizedBox.shrink()),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The four selectable corporate color presets. Swapping the active preset
/// (via [themePresetProvider]) reactively re-themes the app's root
/// `MaterialApp` — see `app_theme.dart`'s `AppTheme.forPreset()`.
enum ThemePreset { navy, emerald, slate, terracotta }

/// One preset's brand-color roles. Only brand-driven roles vary per preset
/// (primary/secondary/accent/background) — semantic colors (success/error/
/// warning, text, borders) stay fixed from `AppColors` regardless of preset,
/// since a red error shouldn't turn green just because the brand palette did.
class ThemePresetConfig {
  final String label;
  final Color primary;
  final Color secondary;
  final Color accent;
  final Color background;

  const ThemePresetConfig({
    required this.label,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.background,
  });

  static const Map<ThemePreset, ThemePresetConfig> all = {
    ThemePreset.navy: ThemePresetConfig(
      label: 'Classic Navy',
      primary: Color(0xFF0F172A),
      secondary: Color(0xFF2563EB),
      accent: Color(0xFF3B82F6),
      background: Color(0xFFF8FAFC),
    ),
    ThemePreset.emerald: ThemePresetConfig(
      label: 'Emerald Forest',
      primary: Color(0xFF065F46),
      secondary: Color(0xFF0284C7),
      accent: Color(0xFF047857),
      background: Color(0xFFF4F7F6),
    ),
    ThemePreset.slate: ThemePresetConfig(
      label: 'Cosmic Slate',
      primary: Color(0xFF1E293B),
      secondary: Color(0xFF4F46E5),
      accent: Color(0xFF312E81),
      background: Color(0xFFF8FAFC),
    ),
    ThemePreset.terracotta: ThemePresetConfig(
      label: 'Warm Terracotta',
      primary: Color(0xFF9A3412),
      secondary: Color(0xFFB45309),
      accent: Color(0xFF7C2D12),
      background: Color(0xFFF5E8E2),
    ),
  };
}

/// Active preset — a plain [StateProvider], the same idiom already used for
/// this app's other simple layout state (e.g. `sidebarCollapsedProvider` in
/// `session_provider.dart`). Deliberately not a `package:provider`
/// `ChangeNotifier` — this app's own convention is Riverpod for all state,
/// and a `StateProvider` already gives every consumer the identical
/// reactive-rebuild-on-change behavior a `ChangeNotifier` would, with no
/// second state-management library introduced alongside Riverpod.
final themePresetProvider = StateProvider<ThemePreset>((ref) => ThemePreset.navy);

/// Row-density toggle — Dense (40px rows / 12px margins) vs Comfortable
/// (54px rows / 18px margins). Same StateProvider idiom as themePresetProvider.
final isCompactDensityProvider = StateProvider<bool>((ref) => false);

/// Row height / margin pair for the active density setting.
class DensityMetrics {
  final double rowHeight;
  final double margin;
  const DensityMetrics({required this.rowHeight, required this.margin});

  static const dense = DensityMetrics(rowHeight: 40.0, margin: 12.0);
  static const comfortable = DensityMetrics(rowHeight: 54.0, margin: 18.0);

  static DensityMetrics of(bool isCompact) => isCompact ? dense : comfortable;
}

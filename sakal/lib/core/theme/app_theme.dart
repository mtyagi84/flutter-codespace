import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'theme_presets.dart';

class AppTheme {
  /// Reactive counterpart of [light] — same structure, but primary/
  /// secondary/background/focused-border roles come from the active
  /// [ThemePresetConfig] instead of the fixed [AppColors] brand constants.
  /// Every OTHER role (semantic colors, text, borders, dividers) stays
  /// fixed from AppColors regardless of preset — see theme_presets.dart's
  /// own doc comment for why. Only affects widgets that read color via
  /// `Theme.of(context)` (AppBar chrome, buttons, cards, inputs, DataTable
  /// headers, dividers, chips) — screens with `AppColors.X` hardcoded as
  /// compile-time constants directly (the majority of the app today) are
  /// unaffected by this and keep their fixed look until individually
  /// migrated to read the active preset.
  static ThemeData forPreset(ThemePresetConfig config) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme(
          brightness: Brightness.light,
          primary: config.primary,
          onPrimary: AppColors.textOnPrimary,
          primaryContainer: config.accent,
          onPrimaryContainer: AppColors.textOnPrimary,
          secondary: config.secondary,
          onSecondary: AppColors.textOnPrimary,
          secondaryContainer: AppColors.secondaryLight,
          onSecondaryContainer: AppColors.textOnPrimary,
          error: AppColors.negative,
          onError: AppColors.textOnPrimary,
          surface: AppColors.surface,
          onSurface: AppColors.textPrimary,
          surfaceContainerHighest: AppColors.surfaceVariant,
          outline: AppColors.border,
        ),
        scaffoldBackgroundColor: config.background,
        appBarTheme: AppBarTheme(
          backgroundColor: config.primary,
          foregroundColor: AppColors.textOnPrimary,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: const TextStyle(
            color: AppColors.textOnPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: config.secondary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.negative),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.negative, width: 2),
          ),
          labelStyle: const TextStyle(color: AppColors.textSecondary),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: config.primary,
            foregroundColor: AppColors.textOnPrimary,
            minimumSize: const Size(64, 48),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
            elevation: 0,
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: config.primary),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.border,
          thickness: 1,
          space: 1,
        ),
        dataTableTheme: DataTableThemeData(
          headingRowColor: WidgetStateProperty.all(AppColors.surfaceVariant),
          headingTextStyle: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          dataTextStyle: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
          ),
          dividerThickness: 1,
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6)),
        ),
        segmentedButtonTheme: _segmentedButtonTheme(config.primary),
      );

  /// Pill-group look (light track, dark filled selected pill) from the
  /// confirmed redesign mockup — themed once here so every SegmentedButton
  /// in the app (Sales Invoice's mode/Cash-Credit selectors today, any
  /// future screen tomorrow) picks it up automatically, reactive to the
  /// active preset, with zero per-screen styling needed.
  static SegmentedButtonThemeData _segmentedButtonTheme(Color selectedColor) =>
      SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? selectedColor : AppColors.surfaceVariant),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? Colors.white : AppColors.textSecondary),
          iconColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? Colors.white : AppColors.textSecondary),
        ),
      );

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme(
          brightness: Brightness.light,
          primary: AppColors.primary,
          onPrimary: AppColors.textOnPrimary,
          primaryContainer: AppColors.primaryLight,
          onPrimaryContainer: AppColors.textOnPrimary,
          secondary: AppColors.secondary,
          onSecondary: AppColors.textOnPrimary,
          secondaryContainer: AppColors.secondaryLight,
          onSecondaryContainer: AppColors.textOnPrimary,
          error: AppColors.negative,
          onError: AppColors.textOnPrimary,
          surface: AppColors.surface,
          onSurface: AppColors.textPrimary,
          surfaceContainerHighest: AppColors.surfaceVariant,
          outline: AppColors.border,
        ),
        scaffoldBackgroundColor: AppColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.textOnPrimary,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: AppColors.textOnPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.primary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.negative),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.negative, width: 2),
          ),
          labelStyle: const TextStyle(color: AppColors.textSecondary),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.textOnPrimary,
            // Finite minimum width — callers that need full-width buttons
            // must wrap in SizedBox(width: double.infinity, child: ...).
            // Size(double.infinity, 48) caused crash when button is a
            // non-flex Row child receiving unconstrained width.
            minimumSize: const Size(64, 48),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
            elevation: 0,
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.primary),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.border,
          thickness: 1,
          space: 1,
        ),
        dataTableTheme: DataTableThemeData(
          headingRowColor: WidgetStateProperty.all(AppColors.surfaceVariant),
          headingTextStyle: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          dataTextStyle: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
          ),
          dividerThickness: 1,
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6)),
        ),
        segmentedButtonTheme: _segmentedButtonTheme(AppColors.primary),
      );
}

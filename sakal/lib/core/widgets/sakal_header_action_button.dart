import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Semantic color for a TopBar action button — same convention already
/// established for the invisible-Save-button fix (Company Setup,
/// Consumption Area Setup, Backdated Entry Control): a bare
/// ElevatedButton/FilledButton's themed default background is the SAME
/// primary color as the TopBar it sits on, so every action button here
/// gets an explicit, semantically-meaningful color instead.
enum SakalActionKind { save, approve, cancel, neutral }

/// A consistent label+icon button for the TopBar's `ScreenHeaderInfo.actions`
/// row — desktop only (see the "Screen header" mandatory pattern in
/// CLAUDE.md and each screen's own mobile/desktop split). Fixes the
/// app-wide inconsistency where some screens showed a labeled body button
/// and others an icon-only TopBar button for what were otherwise
/// equivalent actions (Save, Approve, Cancel, Print, Copy, ...) — one
/// builder, used everywhere, so every screen's actions read the same way.
class SakalHeaderActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final SakalActionKind kind;
  final bool loading;

  const SakalHeaderActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.kind = SakalActionKind.neutral,
    this.loading = false,
  });

  Color get _backgroundColor => switch (kind) {
        SakalActionKind.save => AppColors.secondary,
        SakalActionKind.approve => AppColors.positive,
        SakalActionKind.cancel => AppColors.negative,
        // Print/Copy/etc. — a plain outlined treatment rather than a solid
        // fill, so the one or two "real" actions (Save/Approve) still read
        // as the primary calls-to-action at a glance.
        SakalActionKind.neutral => Colors.transparent,
      };

  @override
  Widget build(BuildContext context) {
    final isNeutral = kind == SakalActionKind.neutral;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 36,
        child: ElevatedButton.icon(
          onPressed: loading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _backgroundColor,
            foregroundColor: Colors.white,
            elevation: isNeutral ? 0 : 1,
            side: isNeutral ? const BorderSide(color: Colors.white38) : BorderSide.none,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          icon: loading
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(icon, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

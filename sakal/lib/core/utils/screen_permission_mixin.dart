import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/session_provider.dart';

/// Mixin for all screens that need permission checks.
/// Usage:
///   class _MyScreenState extends ConsumerState<MyScreen>
///       with ScreenPermissionMixin {
///     @override String get screenName => 'my_screen_name';
///   }
///
/// Then use: canAdd, canEdit, canApprove anywhere in the screen.
mixin ScreenPermissionMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get screenName;

  Map<String, dynamic>? _findFeature() {
    final menus = ref.read(menuProvider);
    for (final m in menus) {
      for (final g in m.groups) {
        for (final item in g.features) {
          if (item.screenName == screenName) {
            return {
              'can_add':     item.addAllowed,
              'can_edit':    item.editAllowed,
              'can_approve': item.approveAllowed,
            };
          }
        }
      }
    }
    return null;
  }

  bool get canAdd     => (_findFeature()?['can_add']     as bool?) ?? true;
  bool get canEdit    => (_findFeature()?['can_edit']    as bool?) ?? true;
  bool get canApprove => (_findFeature()?['can_approve'] as bool?) ?? false;
}

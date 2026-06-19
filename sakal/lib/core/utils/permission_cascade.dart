/// Applies cascade rules when a single permission flag is toggled.
///
/// Cascade rules (mirrors the DB contract):
///   - Unchecking view_allowed clears ALL other flags
///   - Checking any non-view flag auto-checks view_allowed
///
/// Returns a NEW map — never mutates the input.
Map<String, bool> applyPermissionToggle(
    Map<String, bool> current, String field) {
  final flags  = Map<String, bool>.from(current);
  final newVal = !(flags[field] ?? false);
  flags[field] = newVal;

  switch (field) {
    case 'view_allowed':
      if (!newVal) {
        flags['add_allowed']          = false;
        flags['edit_allowed']         = false;
        flags['approve_allowed']      = false;
        flags['copy_allowed']         = false;
        flags['excel_upload_allowed'] = false;
      }
      break;
    case 'add_allowed':
    case 'edit_allowed':
    case 'approve_allowed':
    case 'copy_allowed':
    case 'excel_upload_allowed':
      if (newVal) flags['view_allowed'] = true;
      break;
  }

  return flags;
}

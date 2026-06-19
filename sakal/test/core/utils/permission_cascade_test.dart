import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/utils/permission_cascade.dart';

void main() {
  // Helpers
  Map<String, bool> allFalse() => {
    'view_allowed': false, 'add_allowed': false, 'edit_allowed': false,
    'approve_allowed': false, 'copy_allowed': false, 'excel_upload_allowed': false,
  };

  Map<String, bool> allTrue() => {
    'view_allowed': true, 'add_allowed': true, 'edit_allowed': true,
    'approve_allowed': true, 'copy_allowed': true, 'excel_upload_allowed': true,
  };

  // ── Toggle view_allowed ───────────────────────────────────────────────────

  group('view_allowed toggle', () {
    test('turning view ON sets only view — other flags unchanged', () {
      final result = applyPermissionToggle(allFalse(), 'view_allowed');
      expect(result['view_allowed'],         true);
      expect(result['add_allowed'],          false);
      expect(result['edit_allowed'],         false);
      expect(result['approve_allowed'],      false);
      expect(result['copy_allowed'],         false);
      expect(result['excel_upload_allowed'], false);
    });

    test('turning view OFF clears every flag', () {
      final result = applyPermissionToggle(allTrue(), 'view_allowed');
      expect(result['view_allowed'],         false);
      expect(result['add_allowed'],          false);
      expect(result['edit_allowed'],         false);
      expect(result['approve_allowed'],      false);
      expect(result['copy_allowed'],         false);
      expect(result['excel_upload_allowed'], false);
    });
  });

  // ── Toggle add_allowed ────────────────────────────────────────────────────

  group('add_allowed toggle', () {
    test('turning add ON auto-enables view', () {
      final result = applyPermissionToggle(allFalse(), 'add_allowed');
      expect(result['add_allowed'],  true);
      expect(result['view_allowed'], true);
    });

    test('turning add ON does not affect edit', () {
      final result = applyPermissionToggle(allFalse(), 'add_allowed');
      expect(result['edit_allowed'], false);
    });

    test('turning add OFF does NOT clear view', () {
      final flags  = {...allFalse(), 'view_allowed': true, 'add_allowed': true};
      final result = applyPermissionToggle(flags, 'add_allowed');
      expect(result['add_allowed'],  false);
      expect(result['view_allowed'], true);
    });
  });

  // ── Toggle edit_allowed ───────────────────────────────────────────────────

  group('edit_allowed toggle', () {
    test('turning edit ON auto-enables view', () {
      final result = applyPermissionToggle(allFalse(), 'edit_allowed');
      expect(result['edit_allowed'], true);
      expect(result['view_allowed'], true);
    });

    test('turning edit ON does not grant add', () {
      final result = applyPermissionToggle(allFalse(), 'edit_allowed');
      expect(result['add_allowed'], false);
    });

    test('turning edit OFF does NOT clear view', () {
      final flags  = {...allFalse(), 'view_allowed': true, 'edit_allowed': true};
      final result = applyPermissionToggle(flags, 'edit_allowed');
      expect(result['edit_allowed'], false);
      expect(result['view_allowed'], true);
    });
  });

  // ── Toggle approve_allowed ────────────────────────────────────────────────

  group('approve_allowed toggle', () {
    test('turning approve ON auto-enables view', () {
      final result = applyPermissionToggle(allFalse(), 'approve_allowed');
      expect(result['approve_allowed'], true);
      expect(result['view_allowed'],    true);
    });

    test('turning approve OFF does NOT clear view', () {
      final flags  = {...allFalse(), 'view_allowed': true, 'approve_allowed': true};
      final result = applyPermissionToggle(flags, 'approve_allowed');
      expect(result['approve_allowed'], false);
      expect(result['view_allowed'],    true);
    });
  });

  // ── Toggle copy_allowed ───────────────────────────────────────────────────

  group('copy_allowed toggle', () {
    test('turning copy ON auto-enables view', () {
      final result = applyPermissionToggle(allFalse(), 'copy_allowed');
      expect(result['copy_allowed'],  true);
      expect(result['view_allowed'],  true);
    });
  });

  // ── Toggle excel_upload_allowed ───────────────────────────────────────────

  group('excel_upload_allowed toggle', () {
    test('turning excel ON auto-enables view', () {
      final result = applyPermissionToggle(allFalse(), 'excel_upload_allowed');
      expect(result['excel_upload_allowed'], true);
      expect(result['view_allowed'],         true);
    });
  });

  // ── Immutability ──────────────────────────────────────────────────────────

  group('immutability', () {
    test('does not mutate the input map', () {
      final input = allTrue();
      applyPermissionToggle(input, 'view_allowed');
      // Original map must be untouched
      expect(input['view_allowed'], true);
      expect(input['add_allowed'],  true);
    });

    test('returns a new map instance', () {
      final input  = allFalse();
      final result = applyPermissionToggle(input, 'add_allowed');
      expect(identical(input, result), false);
    });
  });

  // ── Cascade chain ─────────────────────────────────────────────────────────
  // Simulates user workflow: grant add → grant edit → revoke view → all cleared.

  group('cascade chain scenarios', () {
    test('grant add then edit — both set, view auto-enabled', () {
      var flags = allFalse();
      flags = applyPermissionToggle(flags, 'add_allowed');
      flags = applyPermissionToggle(flags, 'edit_allowed');
      expect(flags['view_allowed'], true);
      expect(flags['add_allowed'],  true);
      expect(flags['edit_allowed'], true);
    });

    test('revoke view after granting add + edit — clears both', () {
      var flags = allFalse();
      flags = applyPermissionToggle(flags, 'add_allowed');
      flags = applyPermissionToggle(flags, 'edit_allowed');
      flags = applyPermissionToggle(flags, 'view_allowed'); // was true → now false
      expect(flags['view_allowed'], false);
      expect(flags['add_allowed'],  false);
      expect(flags['edit_allowed'], false);
    });
  });
}

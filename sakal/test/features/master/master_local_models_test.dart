// These row types are defined locally inside their own screen files (no
// repository/model layer exists for either screen — see CLAUDE.md's
// Map<String,dynamic> elimination rollout notes) rather than under
// data/models/, so the test imports the screen file directly.
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/presentation/screens/account_link_setup_screen.dart';
import 'package:sakal/features/master/presentation/screens/sales_executive_master_screen.dart';

void main() {
  group('AccountLinkType', () {
    test('fromJson — missing fields default to safe values', () {
      final t = AccountLinkType.fromJson(const {});
      expect(t.id, '');
      expect(t.linkKey, '');
      expect(t.linkName, '');
      expect(t.sortOrder, 0);
    });

    test('fromJson — all fields present, sort_order coerces from various numeric types', () {
      final t = AccountLinkType.fromJson(const {
        'id': 'link-001',
        'link_key': 'SALES_ACCOUNT',
        'link_name': 'Sales Account',
        'sort_order': '3',
      });
      expect(t.id, 'link-001');
      expect(t.linkKey, 'SALES_ACCOUNT');
      expect(t.linkName, 'Sales Account');
      expect(t.sortOrder, 3);
    });
  });

  group('SalesExecutive', () {
    test('fromJson — missing fields default to safe values', () {
      final s = SalesExecutive.fromJson(const {});
      expect(s.id, '');
      expect(s.employeeCode, '');
      expect(s.fullName, '');
      expect(s.phone, '');
      expect(s.email, '');
      expect(s.linkedUserId, isNull);
      expect(s.linkedUserName, isNull);
      expect(s.isActive, true);
    });

    test('fromJson — linked_user embed resolves the display name', () {
      final s = SalesExecutive.fromJson(const {
        'id': 'exec-001',
        'employee_code': 'EMP-001',
        'full_name': 'Jane Field Rep',
        'phone': '+243900000000',
        'email': 'jane@example.com',
        'linked_user_id': 'user-001',
        'linked_user': {'full_name': 'Jane F. Rep (system)'},
        'is_active': false,
      });
      expect(s.linkedUserId, 'user-001');
      expect(s.linkedUserName, 'Jane F. Rep (system)');
      expect(s.isActive, false);
    });

    test('fromJson — no linked user (field rep with no system login) stays null, not crashing', () {
      final s = SalesExecutive.fromJson(const {
        'employee_code': 'EMP-002',
        'full_name': 'Commission Agent',
        'linked_user_id': null,
        'linked_user': null,
      });
      expect(s.linkedUserId, isNull);
      expect(s.linkedUserName, isNull);
    });
  });
}

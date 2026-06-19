import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/models/menu_models.dart';

void main() {
  // ── MenuFeature ───────────────────────────────────────────────────────────

  group('MenuFeature.fromJson', () {
    const fullJson = {
      'feature_code':         'SALES_INV',
      'feature_name':         'Sales Invoices',
      'screen_name':          'salesInvoices',
      'serial_no':            1,
      'add_allowed':          true,
      'edit_allowed':         false,
      'approve_allowed':      true,
      'copy_allowed':         true,
      'excel_upload_allowed': false,
    };

    test('parses all fields correctly', () {
      final f = MenuFeature.fromJson(fullJson);
      expect(f.featureCode,        'SALES_INV');
      expect(f.featureName,        'Sales Invoices');
      expect(f.screenName,         'salesInvoices');
      expect(f.serialNo,           1);
      expect(f.addAllowed,         true);
      expect(f.editAllowed,        false);
      expect(f.approveAllowed,     true);
      expect(f.copyAllowed,        true);
      expect(f.excelUploadAllowed, false);
    });

    test('missing boolean fields default to false', () {
      final f = MenuFeature.fromJson({
        'feature_code': 'X', 'feature_name': 'X',
        'screen_name':  'x', 'serial_no':    0,
      });
      expect(f.addAllowed,         false);
      expect(f.editAllowed,        false);
      expect(f.approveAllowed,     false);
      expect(f.copyAllowed,        false);
      expect(f.excelUploadAllowed, false);
    });

    test('missing serial_no defaults to 0', () {
      final f = MenuFeature.fromJson({
        'feature_code': 'X', 'feature_name': 'X', 'screen_name': 'x',
      });
      expect(f.serialNo, 0);
    });

    test('toJson → fromJson round-trip is lossless', () {
      final original    = MenuFeature.fromJson(fullJson);
      final roundTripped = MenuFeature.fromJson(original.toJson());
      expect(roundTripped.featureCode,        original.featureCode);
      expect(roundTripped.featureName,        original.featureName);
      expect(roundTripped.screenName,         original.screenName);
      expect(roundTripped.serialNo,           original.serialNo);
      expect(roundTripped.addAllowed,         original.addAllowed);
      expect(roundTripped.editAllowed,        original.editAllowed);
      expect(roundTripped.approveAllowed,     original.approveAllowed);
      expect(roundTripped.copyAllowed,        original.copyAllowed);
      expect(roundTripped.excelUploadAllowed, original.excelUploadAllowed);
    });

    test('toJson contains add_allowed key', () {
      final f    = MenuFeature.fromJson(fullJson);
      final json = f.toJson();
      expect(json.containsKey('add_allowed'), true);
      expect(json['add_allowed'],             true);
    });
  });

  // ── MenuGroup ─────────────────────────────────────────────────────────────

  group('MenuGroup.fromJson', () {
    final groupJson = {
      'group_code': 'INVOICING',
      'group_name': 'Invoicing',
      'serial_no':  1,
      'features':   [
        {
          'feature_code': 'SALES_INV', 'feature_name': 'Sales Invoices',
          'screen_name':  'salesInvoices', 'serial_no': 1,
        },
        {
          'feature_code': 'SALES_RET', 'feature_name': 'Sales Returns',
          'screen_name':  'salesReturns', 'serial_no': 2,
        },
      ],
    };

    test('parses group and nested features', () {
      final g = MenuGroup.fromJson(groupJson);
      expect(g.groupCode, 'INVOICING');
      expect(g.groupName, 'Invoicing');
      expect(g.serialNo,  1);
      expect(g.features,  hasLength(2));
      expect(g.features[0].featureCode, 'SALES_INV');
      expect(g.features[1].featureCode, 'SALES_RET');
    });

    test('missing features list produces empty list', () {
      final g = MenuGroup.fromJson({
        'group_code': 'X', 'group_name': 'X', 'serial_no': 0,
      });
      expect(g.features, isEmpty);
    });

    test('toJson → fromJson round-trip preserves feature count', () {
      final original    = MenuGroup.fromJson(groupJson);
      final roundTripped = MenuGroup.fromJson(original.toJson());
      expect(roundTripped.features, hasLength(original.features.length));
    });
  });

  // ── MenuModule ────────────────────────────────────────────────────────────

  group('MenuModule.fromJson', () {
    final moduleJson = {
      'module_code': 'SALES',
      'module_name': 'Sales',
      'serial_no':   1,
      'groups':      [
        {
          'group_code': 'INVOICING',
          'group_name': 'Invoicing',
          'serial_no':  1,
          'features':   [
            {
              'feature_code': 'SALES_INV', 'feature_name': 'Sales Invoices',
              'screen_name':  'salesInvoices', 'serial_no': 1,
            }
          ],
        }
      ],
    };

    test('parses module → group → feature hierarchy', () {
      final m = MenuModule.fromJson(moduleJson);
      expect(m.moduleCode,                          'SALES');
      expect(m.groups,                              hasLength(1));
      expect(m.groups[0].features,                  hasLength(1));
      expect(m.groups[0].features[0].featureCode,   'SALES_INV');
    });

    test('missing groups list produces empty list', () {
      final m = MenuModule.fromJson({
        'module_code': 'X', 'module_name': 'X', 'serial_no': 0,
      });
      expect(m.groups, isEmpty);
    });

    test('toJson → fromJson round-trip preserves full hierarchy', () {
      final original    = MenuModule.fromJson(moduleJson);
      final roundTripped = MenuModule.fromJson(original.toJson());
      expect(roundTripped.moduleCode,                        original.moduleCode);
      expect(roundTripped.groups,                            hasLength(1));
      expect(roundTripped.groups[0].features[0].featureCode, 'SALES_INV');
    });
  });
}

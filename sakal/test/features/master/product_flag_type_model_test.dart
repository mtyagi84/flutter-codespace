import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/data/models/product_flag_type_model.dart';

void main() {
  group('ProductFlagTypeModel', () {
    const fullJson = {
      'id':            'flag-uuid-1',
      'client_id':     'client-1',
      'company_id':    'company-1',
      'flag_key':      'is_saleable',
      'flag_label':    'Can be Sold',
      'default_value': true,
      'description':   'Controls visibility on Sales Invoice',
      'sort_order':    1,
      'is_active':     true,
    };

    test('fromJson parses all fields', () {
      final m = ProductFlagTypeModel.fromJson(fullJson);
      expect(m.id,           'flag-uuid-1');
      expect(m.clientId,     'client-1');
      expect(m.companyId,    'company-1');
      expect(m.flagKey,      'is_saleable');
      expect(m.flagLabel,    'Can be Sold');
      expect(m.defaultValue, true);
      expect(m.description,  'Controls visibility on Sales Invoice');
      expect(m.sortOrder,    1);
      expect(m.isActive,     true);
    });

    test('id is null when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('id');
      expect(ProductFlagTypeModel.fromJson(json).id, isNull);
    });

    test('description is null when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('description');
      expect(ProductFlagTypeModel.fromJson(json).description, isNull);
    });

    test('default_value defaults to true when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('default_value');
      expect(ProductFlagTypeModel.fromJson(json).defaultValue, true);
    });

    test('sort_order defaults to 0 when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('sort_order');
      expect(ProductFlagTypeModel.fromJson(json).sortOrder, 0);
    });

    test('is_active defaults to true when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_active');
      expect(ProductFlagTypeModel.fromJson(json).isActive, true);
    });

    test('toJson → fromJson round-trip is lossless', () {
      final original = ProductFlagTypeModel.fromJson(fullJson);
      final copy     = ProductFlagTypeModel.fromJson(original.toJson());
      expect(copy.id,           original.id);
      expect(copy.flagKey,      original.flagKey);
      expect(copy.flagLabel,    original.flagLabel);
      expect(copy.defaultValue, original.defaultValue);
      expect(copy.description,  original.description);
      expect(copy.sortOrder,    original.sortOrder);
      expect(copy.isActive,     original.isActive);
    });

    test('toJson omits id when null', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('id');
      final m    = ProductFlagTypeModel.fromJson(json);
      expect(m.toJson().containsKey('id'), false);
    });

    test('toJson omits description when null', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('description');
      final m    = ProductFlagTypeModel.fromJson(json);
      expect(m.toJson().containsKey('description'), false);
    });

    test('copyWith overrides only specified fields', () {
      final original = ProductFlagTypeModel.fromJson(fullJson);
      final updated  = original.copyWith(flagLabel: 'Can Sell', sortOrder: 5, isActive: false);
      expect(updated.flagLabel,    'Can Sell');
      expect(updated.sortOrder,    5);
      expect(updated.isActive,     false);
      expect(updated.flagKey,      original.flagKey);
      expect(updated.defaultValue, original.defaultValue);
    });

    group('defaults()', () {
      final defs = ProductFlagTypeModel.defaults(
          clientId: 'client-1', companyId: 'company-1');

      test('returns exactly 4 entries', () {
        expect(defs.length, 4);
      });

      test('contains is_saleable', () {
        expect(defs.any((d) => d['flag_key'] == 'is_saleable'), true);
      });

      test('contains is_purchasable', () {
        expect(defs.any((d) => d['flag_key'] == 'is_purchasable'), true);
      });

      test('contains is_transferable', () {
        expect(defs.any((d) => d['flag_key'] == 'is_transferable'), true);
      });

      test('contains is_intercompany with default_value = false', () {
        final entry = defs.firstWhere((d) => d['flag_key'] == 'is_intercompany');
        expect(entry['default_value'], false);
      });

      test('all entries carry client_id and company_id', () {
        for (final d in defs) {
          expect(d['client_id'],  'client-1');
          expect(d['company_id'], 'company-1');
        }
      });
    });
  });
}

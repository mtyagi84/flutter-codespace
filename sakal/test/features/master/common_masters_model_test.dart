import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/data/models/common_master_model.dart';
import 'package:sakal/features/master/data/models/common_master_type_model.dart';

void main() {
  group('CommonMasterTypeModel', () {
    const fullJson = {
      'id':        'type-1',
      'type_key':  'BRAND',
      'type_name': 'Brand',
      'is_active': true,
    };

    test('fromJson parses all fields', () {
      final m = CommonMasterTypeModel.fromJson(fullJson);
      expect(m.id,       'type-1');
      expect(m.typeKey,  'BRAND');
      expect(m.typeName, 'Brand');
      expect(m.isActive, true);
    });

    test('is_active defaults to true when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_active');
      final m = CommonMasterTypeModel.fromJson(json);
      expect(m.isActive, true);
    });

    test('toJson → fromJson round-trip is lossless', () {
      final original = CommonMasterTypeModel.fromJson(fullJson);
      final copy     = CommonMasterTypeModel.fromJson(original.toJson());
      expect(copy.id,       original.id);
      expect(copy.typeKey,  original.typeKey);
      expect(copy.typeName, original.typeName);
      expect(copy.isActive, original.isActive);
    });
  });

  group('CommonMasterModel', () {
    const fullJson = {
      'id':          'master-1',
      'client_id':   'client-1',
      'company_id':  'company-1',
      'type_id':     'type-1',
      'description': 'Coca-Cola',
      'short_name':  'CC',
      'sort_order':  1,
      'is_active':   true,
      'is_deleted':  false,
    };

    test('fromJson parses all fields', () {
      final m = CommonMasterModel.fromJson(fullJson);
      expect(m.id,          'master-1');
      expect(m.clientId,    'client-1');
      expect(m.companyId,   'company-1');
      expect(m.typeId,      'type-1');
      expect(m.description, 'Coca-Cola');
      expect(m.shortName,   'CC');
      expect(m.sortOrder,   1);
      expect(m.isActive,    true);
      expect(m.isDeleted,   false);
    });

    test('optional short_name is null when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('short_name');
      final m = CommonMasterModel.fromJson(json);
      expect(m.shortName, isNull);
    });

    test('sort_order defaults to 0 when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('sort_order');
      final m = CommonMasterModel.fromJson(json);
      expect(m.sortOrder, 0);
    });

    test('is_active defaults to true when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_active');
      final m = CommonMasterModel.fromJson(json);
      expect(m.isActive, true);
    });

    test('is_deleted defaults to false when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_deleted');
      final m = CommonMasterModel.fromJson(json);
      expect(m.isDeleted, false);
    });

    test('toJson → fromJson round-trip is lossless', () {
      final original = CommonMasterModel.fromJson(fullJson);
      final copy     = CommonMasterModel.fromJson(original.toJson());
      expect(copy.id,          original.id);
      expect(copy.description, original.description);
      expect(copy.shortName,   original.shortName);
      expect(copy.sortOrder,   original.sortOrder);
      expect(copy.isActive,    original.isActive);
      expect(copy.isDeleted,   original.isDeleted);
    });

    test('toJson omits short_name when null', () {
      final m    = CommonMasterModel.fromJson(
          Map<String, dynamic>.from(fullJson)..remove('short_name'));
      final json = m.toJson();
      expect(json.containsKey('short_name'), false);
    });

    test('copyWith overrides only specified fields', () {
      final original = CommonMasterModel.fromJson(fullJson);
      final updated  = original.copyWith(description: 'Pepsi', sortOrder: 5);
      expect(updated.description, 'Pepsi');
      expect(updated.sortOrder,   5);
      expect(updated.shortName,   original.shortName);
      expect(updated.isActive,    original.isActive);
    });
  });
}

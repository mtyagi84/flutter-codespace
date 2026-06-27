import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/data/models/category_level_model.dart';

void main() {
  group('CategoryLevelModel', () {
    const fullJson = {
      'id':          'level-uuid-1',
      'client_id':   'client-1',
      'company_id':  'company-1',
      'level_no':    1,
      'level_label': 'Department',
      'is_mandatory': true,
      'is_active':    true,
    };

    test('fromJson parses all fields', () {
      final m = CategoryLevelModel.fromJson(fullJson);
      expect(m.id,          'level-uuid-1');
      expect(m.clientId,    'client-1');
      expect(m.companyId,   'company-1');
      expect(m.levelNo,     1);
      expect(m.levelLabel,  'Department');
      expect(m.isMandatory, true);
      expect(m.isActive,    true);
    });

    test('id is null when missing from json', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('id');
      final m = CategoryLevelModel.fromJson(json);
      expect(m.id, isNull);
    });

    test('is_mandatory defaults to false when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_mandatory');
      final m = CategoryLevelModel.fromJson(json);
      expect(m.isMandatory, false);
    });

    test('is_active defaults to true when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_active');
      final m = CategoryLevelModel.fromJson(json);
      expect(m.isActive, true);
    });

    test('toJson → fromJson round-trip is lossless', () {
      final original = CategoryLevelModel.fromJson(fullJson);
      final copy     = CategoryLevelModel.fromJson(original.toJson());
      expect(copy.id,          original.id);
      expect(copy.clientId,    original.clientId);
      expect(copy.companyId,   original.companyId);
      expect(copy.levelNo,     original.levelNo);
      expect(copy.levelLabel,  original.levelLabel);
      expect(copy.isMandatory, original.isMandatory);
      expect(copy.isActive,    original.isActive);
    });

    test('toJson omits id when null', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('id');
      final m    = CategoryLevelModel.fromJson(json);
      expect(m.toJson().containsKey('id'), false);
    });

    test('copyWith overrides only specified fields', () {
      final original = CategoryLevelModel.fromJson(fullJson);
      final updated  = original.copyWith(levelLabel: 'Category', isMandatory: false);
      expect(updated.levelLabel,  'Category');
      expect(updated.isMandatory, false);
      expect(updated.levelNo,     original.levelNo);
      expect(updated.isActive,    original.isActive);
    });

    test('copyWith without args returns equivalent object', () {
      final original = CategoryLevelModel.fromJson(fullJson);
      final copy     = original.copyWith();
      expect(copy.levelLabel,  original.levelLabel);
      expect(copy.isMandatory, original.isMandatory);
      expect(copy.isActive,    original.isActive);
    });
  });
}

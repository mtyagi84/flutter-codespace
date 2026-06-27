import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/data/models/item_category_model.dart';

void main() {
  group('ItemCategoryModel', () {
    const fullJson = {
      'id':             'cat-uuid-1',
      'client_id':      'client-1',
      'company_id':     'company-1',
      'parent_id':      'cat-uuid-parent',
      'level_no':       2,
      'category_name':  'Beverages',
      'category_short': 'BEV',
      'sort_order':     3,
      'is_active':      true,
      'is_deleted':     false,
      'flags': {
        'is_saleable':    true,
        'is_purchasable': false,
      },
    };

    test('fromJson parses all fields', () {
      final m = ItemCategoryModel.fromJson(fullJson);
      expect(m.id,            'cat-uuid-1');
      expect(m.clientId,      'client-1');
      expect(m.companyId,     'company-1');
      expect(m.parentId,      'cat-uuid-parent');
      expect(m.levelNo,       2);
      expect(m.categoryName,  'Beverages');
      expect(m.categoryShort, 'BEV');
      expect(m.sortOrder,     3);
      expect(m.isActive,      true);
      expect(m.isDeleted,     false);
      expect(m.flags['is_saleable'],    true);
      expect(m.flags['is_purchasable'], false);
    });

    test('id is null when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('id');
      expect(ItemCategoryModel.fromJson(json).id, isNull);
    });

    test('parent_id is null when missing (root category)', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('parent_id');
      expect(ItemCategoryModel.fromJson(json).parentId, isNull);
    });

    test('category_short is null when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('category_short');
      expect(ItemCategoryModel.fromJson(json).categoryShort, isNull);
    });

    test('flags defaults to empty map when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('flags');
      final m = ItemCategoryModel.fromJson(json);
      expect(m.flags, isEmpty);
    });

    test('flags defaults to empty map when null in json', () {
      final json = Map<String, dynamic>.from(fullJson);
      json['flags'] = null;
      final m = ItemCategoryModel.fromJson(json);
      expect(m.flags, isEmpty);
    });

    test('sort_order defaults to 0 when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('sort_order');
      expect(ItemCategoryModel.fromJson(json).sortOrder, 0);
    });

    test('is_active defaults to true when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_active');
      expect(ItemCategoryModel.fromJson(json).isActive, true);
    });

    test('is_deleted defaults to false when missing', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('is_deleted');
      expect(ItemCategoryModel.fromJson(json).isDeleted, false);
    });

    test('flags with all 4 standard keys parsed correctly', () {
      final json = Map<String, dynamic>.from(fullJson);
      json['flags'] = {
        'is_saleable':    true,
        'is_purchasable': true,
        'is_transferable': false,
        'is_intercompany': false,
      };
      final m = ItemCategoryModel.fromJson(json);
      expect(m.flags.length,              4);
      expect(m.flags['is_saleable'],      true);
      expect(m.flags['is_purchasable'],   true);
      expect(m.flags['is_transferable'],  false);
      expect(m.flags['is_intercompany'],  false);
    });

    test('toJson → fromJson round-trip is lossless', () {
      final original = ItemCategoryModel.fromJson(fullJson);
      final copy     = ItemCategoryModel.fromJson(original.toJson());
      expect(copy.id,            original.id);
      expect(copy.clientId,      original.clientId);
      expect(copy.companyId,     original.companyId);
      expect(copy.parentId,      original.parentId);
      expect(copy.levelNo,       original.levelNo);
      expect(copy.categoryName,  original.categoryName);
      expect(copy.categoryShort, original.categoryShort);
      expect(copy.sortOrder,     original.sortOrder);
      expect(copy.isActive,      original.isActive);
      expect(copy.isDeleted,     original.isDeleted);
      expect(copy.flags,         original.flags);
    });

    test('toJson omits id when null', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('id');
      final m    = ItemCategoryModel.fromJson(json);
      expect(m.toJson().containsKey('id'), false);
    });

    test('toJson omits parent_id when null', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('parent_id');
      final m    = ItemCategoryModel.fromJson(json);
      expect(m.toJson().containsKey('parent_id'), false);
    });

    test('toJson omits category_short when null', () {
      final json = Map<String, dynamic>.from(fullJson)..remove('category_short');
      final m    = ItemCategoryModel.fromJson(json);
      expect(m.toJson().containsKey('category_short'), false);
    });

    test('toJson does not include children (client-side only)', () {
      final m = ItemCategoryModel.fromJson(fullJson);
      expect(m.toJson().containsKey('children'), false);
    });

    test('root category (level 1) has no parent_id in toJson', () {
      final json = {
        'client_id':     'client-1',
        'company_id':    'company-1',
        'level_no':      1,
        'category_name': 'Food & Beverages',
        'sort_order':    1,
        'is_active':     true,
        'is_deleted':    false,
        'flags':         <String, dynamic>{},
      };
      final m = ItemCategoryModel.fromJson(json);
      expect(m.parentId, isNull);
      expect(m.toJson().containsKey('parent_id'), false);
    });

    test('empty flags round-trips cleanly', () {
      final json = Map<String, dynamic>.from(fullJson);
      json['flags'] = <String, dynamic>{};
      final m    = ItemCategoryModel.fromJson(json);
      final copy = ItemCategoryModel.fromJson(m.toJson());
      expect(copy.flags, isEmpty);
    });
  });
}

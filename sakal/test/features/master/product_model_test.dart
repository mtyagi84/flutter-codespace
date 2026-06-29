import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/data/models/product_model.dart';
import 'package:sakal/features/master/data/models/product_uom_model.dart';
import 'package:sakal/features/master/data/models/product_media_model.dart';

void main() {
  group('ProductModel', () {
    const minimalJson = {
      'id':             'prod-001',
      'client_id':      'client-001',
      'company_id':     'company-001',
      'product_code':   'PRD-00001',
      'product_name':   'Widget A',
    };

    test('fromJson — minimal required fields only', () {
      final p = ProductModel.fromJson(minimalJson);
      expect(p.id,           'prod-001');
      expect(p.productCode,  'PRD-00001');
      expect(p.productName,  'Widget A');
      expect(p.productNature, 'TRADING');
      expect(p.trackingType,  'NONE');
      expect(p.isActive,     true);
      expect(p.isScalable,   false);
      expect(p.standardCost, 0.0);
      expect(p.flags,        isEmpty);
    });

    test('fromJson — full fields including numeric variants', () {
      final json = {
        ...minimalJson,
        'product_nature':       'FINISHED_GOOD',
        'standard_cost':        '150.5',
        'average_cost':         100,
        'last_purchase_cost':   120.75,
        'allowed_cost_variance':'5.0',
        'lead_time_days':       7,
        'tracking_type':        'BATCH',
        'is_scalable':          true,
        'is_active':            false,
        'flags':                {'is_saleable': true, 'is_pos_item': false},
        'weight':               2.5,
        'weight_uom':           'kg',
        'barcode':              '8901234567890',
        'part_number':          'PN-XYZ',
        'remarks':              'Handle with care',
      };
      final p = ProductModel.fromJson(json);
      expect(p.productNature,       'FINISHED_GOOD');
      expect(p.standardCost,        150.5);
      expect(p.averageCost,         100.0);
      expect(p.lastPurchaseCost,    120.75);
      expect(p.allowedCostVariance, 5.0);
      expect(p.leadTimeDays,        7);
      expect(p.trackingType,        'BATCH');
      expect(p.isScalable,          true);
      expect(p.isActive,            false);
      expect(p.flags['is_saleable'],true);
      expect(p.flags['is_pos_item'],false);
      expect(p.weight,              2.5);
      expect(p.weightUom,           'kg');
      expect(p.barcode,             '8901234567890');
      expect(p.partNumber,          'PN-XYZ');
      expect(p.remarks,             'Handle with care');
    });

    test('fromJson — PostgREST embedded joins for list query', () {
      final json = {
        ...minimalJson,
        'category': {'category_name': 'Electronics'},
        'base_uom': {'description':   'Piece'},
      };
      final p = ProductModel.fromJson(json);
      expect(p.categoryName, 'Electronics');
      expect(p.baseUomName,  'Piece');
    });

    test('fromJson — embedded join null does not crash', () {
      final p = ProductModel.fromJson({...minimalJson, 'category': null, 'base_uom': null});
      expect(p.categoryName, isNull);
      expect(p.baseUomName,  isNull);
    });

    test('toJson — round-trips required fields', () {
      final p = ProductModel.fromJson(minimalJson);
      final j = p.toJson();
      expect(j['id'],           'prod-001');
      expect(j['product_code'], 'PRD-00001');
      expect(j['product_name'], 'Widget A');
      expect(j['product_nature'], 'TRADING');
    });

    test('toJson — nullable fields omitted when null', () {
      final p  = ProductModel.fromJson(minimalJson);
      final j  = p.toJson();
      expect(j.containsKey('barcode'),     isFalse);
      expect(j.containsKey('part_number'), isFalse);
      expect(j.containsKey('category_id'), isFalse);
    });

    test('natureLabels — contains all 6 entries', () {
      expect(ProductModel.natureLabels.length, 6);
      expect(ProductModel.natureLabels.containsKey('TRADING'),      true);
      expect(ProductModel.natureLabels.containsKey('FINISHED_GOOD'),true);
      expect(ProductModel.natureLabels.containsKey('SERVICE'),      true);
    });

    test('trackingLabels — contains all 4 entries', () {
      expect(ProductModel.trackingLabels.length, 4);
      expect(ProductModel.trackingLabels.containsKey('NONE'),              true);
      expect(ProductModel.trackingLabels.containsKey('BATCH'),             true);
      expect(ProductModel.trackingLabels.containsKey('BATCH_WITH_EXPIRY'), true);
    });

    test('_toDouble handles int, double, string, null', () {
      // Exercised via standardCost
      final p1 = ProductModel.fromJson({...minimalJson, 'standard_cost': 100});
      final p2 = ProductModel.fromJson({...minimalJson, 'standard_cost': 100.5});
      final p3 = ProductModel.fromJson({...minimalJson, 'standard_cost': '99.9'});
      final p4 = ProductModel.fromJson({...minimalJson, 'standard_cost': null});
      expect(p1.standardCost, 100.0);
      expect(p2.standardCost, 100.5);
      expect(p3.standardCost, 99.9);
      expect(p4.standardCost, 0.0);
    });

    test('_toDoubleNullable returns null for null weight', () {
      final p = ProductModel.fromJson({...minimalJson, 'weight': null});
      expect(p.weight, isNull);
    });
  });

  // ── ProductUomModel ─────────────────────────────────────────────────────────

  group('ProductUomModel', () {
    const minJson = {
      'client_id':  'c1',
      'company_id': 'co1',
      'uom_id':     'uom-001',
    };

    test('fromJson — minimal', () {
      final u = ProductUomModel.fromJson(minJson);
      expect(u.uomId,            'uom-001');
      expect(u.conversionFactor, 1.0);
      expect(u.isBaseUom,        false);
      expect(u.isPurchaseUom,    false);
      expect(u.isSalesUom,       false);
      expect(u.sortOrder,        0);
      expect(u.uomName,          isNull);
    });

    test('fromJson — conversion_factor as int, string, double', () {
      final u1 = ProductUomModel.fromJson({...minJson, 'conversion_factor': 12});
      final u2 = ProductUomModel.fromJson({...minJson, 'conversion_factor': 12.5});
      final u3 = ProductUomModel.fromJson({...minJson, 'conversion_factor': '24'});
      expect(u1.conversionFactor, 12.0);
      expect(u2.conversionFactor, 12.5);
      expect(u3.conversionFactor, 24.0);
    });

    test('fromJson — PostgREST embedded uom_name join', () {
      final u = ProductUomModel.fromJson({...minJson, 'uom_name': {'description': 'Carton'}});
      expect(u.uomName, 'Carton');
    });

    test('toJson — omits null fields', () {
      final u = ProductUomModel.fromJson(minJson);
      final j = u.toJson();
      expect(j.containsKey('id'),      isFalse);
      expect(j.containsKey('barcode'), isFalse);
    });

    test('copyWith — productId and sortOrder', () {
      final u  = ProductUomModel.fromJson(minJson);
      final u2 = u.copyWith(productId: 'prod-123', sortOrder: 3);
      expect(u2.productId, 'prod-123');
      expect(u2.sortOrder, 3);
      expect(u2.uomId,     'uom-001'); // unchanged
    });
  });

  // ── ProductMediaModel ───────────────────────────────────────────────────────

  group('ProductMediaModel', () {
    const minJson = {
      'client_id':  'c1',
      'company_id': 'co1',
      'product_id': 'prod-001',
      'media_type': 'IMAGE',
    };

    test('fromJson — minimal', () {
      final m = ProductMediaModel.fromJson(minJson);
      expect(m.productId, 'prod-001');
      expect(m.mediaType, 'IMAGE');
      expect(m.isPrimary, false);
      expect(m.sortOrder, 0);
      expect(m.mediaData, isNull);
    });

    test('fromJson — full fields', () {
      final json = {
        ...minJson,
        'id':         'media-001',
        'media_data': 'base64data',
        'caption':    'Front view',
        'is_primary': true,
        'sort_order': 2,
      };
      final m = ProductMediaModel.fromJson(json);
      expect(m.id,        'media-001');
      expect(m.mediaData, 'base64data');
      expect(m.caption,   'Front view');
      expect(m.isPrimary, true);
      expect(m.sortOrder, 2);
    });

    test('toJson — round-trips', () {
      final m = ProductMediaModel.fromJson({
        ...minJson,
        'id':         'media-001',
        'media_data': 'abc',
        'caption':    'Side',
        'is_primary': true,
        'sort_order': 1,
      });
      final j = m.toJson();
      expect(j['id'],         'media-001');
      expect(j['media_data'], 'abc');
      expect(j['caption'],    'Side');
      expect(j['is_primary'], true);
      expect(j['sort_order'], 1);
    });
  });
}

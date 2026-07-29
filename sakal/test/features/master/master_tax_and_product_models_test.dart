import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/master/data/models/product_uom_model.dart';
import 'package:sakal/features/master/data/models/product_media_model.dart';
import 'package:sakal/features/master/data/models/tax_group_model.dart';
import 'package:sakal/features/master/data/models/tax_group_member_model.dart';
import 'package:sakal/features/master/data/models/tax_model.dart';
import 'package:sakal/features/master/data/models/tax_rate_model.dart';
import 'package:sakal/features/master/data/models/tax_type_model.dart';

void main() {
  // ── ProductUomModel ───────────────────────────────────────────────────────

  group('ProductUomModel', () {
    const minimalJson = {
      'client_id': 'client-001',
      'company_id': 'company-001',
      'uom_id': 'uom-001',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final u = ProductUomModel.fromJson(minimalJson);
      expect(u.uomId, 'uom-001');
      expect(u.conversionFactor, 1);
      expect(u.isBaseUom, false);
      expect(u.isPurchaseUom, false);
      expect(u.isSalesUom, false);
      expect(u.sortOrder, 0);
      expect(u.uomName, isNull);
    });

    test('fromJson — conversion_factor coerces from int/double/string (genuinely permissive, unlike sort_order)', () {
      expect(ProductUomModel.fromJson({...minimalJson, 'conversion_factor': 12}).conversionFactor, 12.0);
      expect(ProductUomModel.fromJson({...minimalJson, 'conversion_factor': 12.5}).conversionFactor, 12.5);
      expect(ProductUomModel.fromJson({...minimalJson, 'conversion_factor': '12.5'}).conversionFactor, 12.5);
    });

    test('fromJson — uom_name embed (a nested object despite the scalar-sounding key) resolves via description', () {
      final u = ProductUomModel.fromJson({
        ...minimalJson,
        'uom_name': {'description': 'Carton of 12'},
      });
      expect(u.uomName, 'Carton of 12');
    });

    test('copyWith — overrides only the given fields, keeps identity fields', () {
      final original = ProductUomModel.fromJson(minimalJson);
      final updated = original.copyWith(conversionFactor: 24, isBaseUom: true);
      expect(updated.conversionFactor, 24);
      expect(updated.isBaseUom, true);
      expect(updated.uomId, original.uomId);
      expect(updated.clientId, original.clientId);
    });

    test('toJson — omits null id/productId/barcode', () {
      final json = ProductUomModel.fromJson(minimalJson).toJson();
      expect(json.containsKey('id'), false);
      expect(json.containsKey('product_id'), false);
      expect(json.containsKey('barcode'), false);
      expect(json['uom_id'], 'uom-001');
    });
  });

  // ── ProductMediaModel ─────────────────────────────────────────────────────

  group('ProductMediaModel', () {
    const minimalJson = {'client_id': 'client-001', 'company_id': 'company-001'};

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final m = ProductMediaModel.fromJson(minimalJson);
      expect(m.mediaType, 'IMAGE');
      expect(m.isPrimary, false);
      expect(m.sortOrder, 0);
      expect(m.mediaData, isNull);
      expect(m.mediaUrl, isNull);
    });

    test('fromJson — video entry with URL, no media_data', () {
      final m = ProductMediaModel.fromJson({
        ...minimalJson,
        'media_type': 'VIDEO',
        'media_url': 'https://example.com/v.mp4',
        'is_primary': true,
      });
      expect(m.mediaType, 'VIDEO');
      expect(m.mediaUrl, 'https://example.com/v.mp4');
      expect(m.isPrimary, true);
    });

    test('toJson — omits null optional fields', () {
      final json = ProductMediaModel.fromJson(minimalJson).toJson();
      expect(json.containsKey('media_data'), false);
      expect(json.containsKey('media_url'), false);
      expect(json.containsKey('caption'), false);
    });
  });

  // ── TaxGroupModel ─────────────────────────────────────────────────────────

  group('TaxGroupModel', () {
    const minimalJson = {
      'client_id': 'client-001',
      'company_id': 'company-001',
      'group_code': 'VAT-STD',
      'group_name': 'VAT Standard',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final g = TaxGroupModel.fromJson(minimalJson);
      expect(g.applicableOn, 'BOTH');
      expect(g.sortOrder, 0);
      expect(g.isActive, true);
      expect(g.isDeleted, false);
      expect(g.description, isNull);
    });

    test('fromJson — all fields present', () {
      final g = TaxGroupModel.fromJson({
        ...minimalJson,
        'applicable_on': 'SALES',
        'description': 'Standard rate VAT group',
        'is_active': false,
      });
      expect(g.applicableOn, 'SALES');
      expect(g.description, 'Standard rate VAT group');
      expect(g.isActive, false);
    });

    test('copyWith — overrides only the given fields', () {
      final original = TaxGroupModel.fromJson(minimalJson);
      final updated = original.copyWith(isActive: false, description: 'Deprecated');
      expect(updated.isActive, false);
      expect(updated.description, 'Deprecated');
      expect(updated.groupCode, original.groupCode);
    });
  });

  // ── TaxGroupMemberModel ───────────────────────────────────────────────────

  group('TaxGroupMemberModel', () {
    const minimalJson = {
      'client_id': 'client-001',
      'company_id': 'company-001',
      'tax_group_id': 'group-001',
      'tax_id': 'tax-001',
    };

    test('fromJson — minimal required fields only, sequence_no defaults to 1', () {
      final m = TaxGroupMemberModel.fromJson(minimalJson);
      expect(m.sequenceNo, 1);
      expect(m.taxCode, ''); // client-side-only field, never comes from fromJson
      expect(m.taxName, '');
    });

    test('withDisplay — attaches client-resolved code/name without touching identity fields', () {
      final m = TaxGroupMemberModel.fromJson(minimalJson).withDisplay(code: 'VAT16', name: 'VAT 16%');
      expect(m.taxCode, 'VAT16');
      expect(m.taxName, 'VAT 16%');
      expect(m.taxId, 'tax-001');
    });

    test('toRpcJson — only sends tax_id and sequence_no, not the full row', () {
      final json = TaxGroupMemberModel.fromJson({...minimalJson, 'sequence_no': 2}).toRpcJson();
      expect(json, {'tax_id': 'tax-001', 'sequence_no': 2});
    });

    test('copyWith — sequenceNo override only', () {
      final original = TaxGroupMemberModel.fromJson(minimalJson);
      final updated = original.copyWith(sequenceNo: 5);
      expect(updated.sequenceNo, 5);
      expect(updated.taxId, original.taxId);
    });
  });

  // ── TaxModel ───────────────────────────────────────────────────────────────

  group('TaxModel', () {
    const minimalJson = {
      'client_id': 'client-001',
      'company_id': 'company-001',
      'tax_code': 'VAT16',
      'tax_name': 'VAT 16%',
      'tax_type_code': 'VAT',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final t = TaxModel.fromJson(minimalJson);
      expect(t.applicableOn, 'BOTH');
      expect(t.calculationType, 'PERCENTAGE');
      expect(t.isPriceInclusive, false);
      expect(t.isReverseCharge, false);
      expect(t.isActive, true);
      expect(t.isDeleted, false);
      expect(t.glOutputAccountId, isNull);
    });

    test('fromJson — withholding-style tax with GL accounts', () {
      final t = TaxModel.fromJson({
        ...minimalJson,
        'tax_type_code': 'WITHHOLDING',
        'gl_output_account_id': 'acct-out',
        'gl_input_account_id': 'acct-in',
        'gl_expense_account_id': 'acct-exp',
      });
      expect(t.glOutputAccountId, 'acct-out');
      expect(t.glInputAccountId, 'acct-in');
      expect(t.glExpenseAccountId, 'acct-exp');
    });

    test('copyWith — overrides only the given fields', () {
      final original = TaxModel.fromJson(minimalJson);
      final updated = original.copyWith(isActive: false);
      expect(updated.isActive, false);
      expect(updated.taxCode, original.taxCode);
    });
  });

  // ── TaxRateModel ──────────────────────────────────────────────────────────

  group('TaxRateModel', () {
    const minimalJson = {
      'client_id': 'client-001',
      'company_id': 'company-001',
      'tax_id': 'tax-001',
      'rate': 16,
      'effective_from': '2020-01-01',
    };

    test('fromJson — minimal required fields, rate_label defaults to STANDARD', () {
      final r = TaxRateModel.fromJson(minimalJson);
      expect(r.rate, 16.0);
      expect(r.rateLabel, 'STANDARD');
      expect(r.effectiveTo, isNull);
      expect(r.isActive, true);
    });

    test('isCurrent — true when effective range safely spans "now" (wide margin, not date-flaky)', () {
      final r = TaxRateModel.fromJson(minimalJson); // 2020-01-01, no end date
      expect(r.isCurrent, true);
    });

    test('isCurrent — false when not yet effective (far future start date)', () {
      final r = TaxRateModel.fromJson({...minimalJson, 'effective_from': '2099-01-01'});
      expect(r.isCurrent, false);
    });

    test('isCurrent — false when already expired (far past end date)', () {
      final r = TaxRateModel.fromJson({
        ...minimalJson,
        'effective_from': '2020-01-01',
        'effective_to': '2020-12-31',
      });
      expect(r.isCurrent, false);
    });

    test('isCurrent — false when isActive is false regardless of date range', () {
      final r = TaxRateModel.fromJson({...minimalJson, 'is_active': false});
      expect(r.isCurrent, false);
    });

    test('fromJson — thresholds present for a slab-based rate', () {
      final r = TaxRateModel.fromJson({
        ...minimalJson,
        'threshold_min': 0,
        'threshold_max': 10000,
      });
      expect(r.thresholdMin, 0.0);
      expect(r.thresholdMax, 10000.0);
    });

    test('toJson — dates format as YYYY-MM-DD, omits null effective_to', () {
      final json = TaxRateModel.fromJson(minimalJson).toJson();
      expect(json['effective_from'], '2020-01-01');
      expect(json.containsKey('effective_to'), false);
    });
  });

  // ── TaxTypeModel ──────────────────────────────────────────────────────────

  group('TaxTypeModel', () {
    const minimalJson = {
      'id': 'type-001',
      'tax_type_code': 'VAT',
      'type_name': 'Value Added Tax',
    };

    test('fromJson — required fields present, optional fields default', () {
      final t = TaxTypeModel.fromJson(minimalJson);
      expect(t.id, 'type-001');
      expect(t.isWithholding, false);
      expect(t.sortOrder, 0);
      expect(t.isActive, true);
    });

    test('fromJson — withholding tax type', () {
      final t = TaxTypeModel.fromJson({
        ...minimalJson,
        'tax_type_code': 'WITHHOLDING',
        'is_withholding': true,
      });
      expect(t.isWithholding, true);
    });
  });
}

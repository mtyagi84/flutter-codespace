import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/purchase/data/models/purchase_order_model.dart';
import 'package:sakal/features/purchase/data/models/purchase_order_line_model.dart';
import 'package:sakal/features/purchase/data/models/po_charge_line_model.dart';
import 'package:sakal/features/purchase/data/models/po_payment_term_model.dart';

void main() {
  // ── PurchaseOrderModel ────────────────────────────────────────────────────

  group('PurchaseOrderModel', () {
    const minimalJson = {
      'id':           'po-001',
      'client_id':    'client-001',
      'company_id':   'company-001',
      'location_id':  'loc-001',
      'order_no':     'PO-LOC/2026/00001',
      'order_date':   '2026-06-01',
      'supplier_id':  'supplier-001',
      'po_currency_id': 'currency-001',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final po = PurchaseOrderModel.fromJson(minimalJson);
      expect(po.id, 'po-001');
      expect(po.orderNo, 'PO-LOC/2026/00001');
      expect(po.poType, 'LOCAL');
      expect(po.status, 'DRAFT');
      expect(po.rateToBase, 1);
      expect(po.rateToLocal, 1);
      expect(po.grossAmount, 0);
      expect(po.discountAmount, 0);
      expect(po.chargesAmount, 0);
      expect(po.itemTaxAmount, 0);
      expect(po.chargeTaxAmount, 0);
      expect(po.grandTotal, 0);
      expect(po.supplierCode, isNull);
      expect(po.approvedBy, isNull);
    });

    test('fromJson — numeric fields as int/string/double all coerce to double', () {
      final po = PurchaseOrderModel.fromJson({
        ...minimalJson,
        'rate_to_base': 2,
        'rate_to_local': 1.5,
        'grand_total': 1160,
      });
      expect(po.rateToBase, 2.0);
      expect(po.rateToLocal, 1.5);
      expect(po.grandTotal, 1160.0);
    });

    test('fromJson — PostgREST embedded joins (supplier/location/currency/buyer)', () {
      final po = PurchaseOrderModel.fromJson({
        ...minimalJson,
        'supplier': {'account_code': 'SUP-001', 'account_name': 'Acme Supplies'},
        'location': {'location_name': 'Main Warehouse'},
        'currency': {'currency_id': 'USD'},
        'buyer':    {'full_name': 'Jane Buyer'},
      });
      expect(po.supplierCode, 'SUP-001');
      expect(po.supplierName, 'Acme Supplies');
      expect(po.locationName, 'Main Warehouse');
      expect(po.poCurrencyCode, 'USD');
      expect(po.buyerName, 'Jane Buyer');
    });

    test('fromJson — embedded joins null does not crash', () {
      final po = PurchaseOrderModel.fromJson({
        ...minimalJson,
        'supplier': null, 'location': null, 'currency': null, 'buyer': null,
      });
      expect(po.supplierCode, isNull);
      expect(po.locationName, isNull);
      expect(po.poCurrencyCode, isNull);
      expect(po.buyerName, isNull);
    });

    test('fromJson — status/approval fields carry through when present', () {
      final po = PurchaseOrderModel.fromJson({
        ...minimalJson,
        'status': 'APPROVED',
        'approved_by': 'user-001',
        'approved_at': '2026-06-02T10:00:00Z',
      });
      expect(po.status, 'APPROVED');
      expect(po.approvedBy, 'user-001');
      expect(po.approvedAt, '2026-06-02T10:00:00Z');
    });
  });

  // ── PurchaseOrderLineModel ────────────────────────────────────────────────

  group('PurchaseOrderLineModel', () {
    const minimalJson = {
      'id':         'line-001',
      'serial_no':  1,
      'product_id': 'prod-001',
      'uom_id':     'uom-001',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final l = PurchaseOrderLineModel.fromJson(minimalJson);
      expect(l.serialNo, 1);
      expect(l.productId, 'prod-001');
      expect(l.uomConversionFactor, 1);
      expect(l.qtyPack, 0);
      expect(l.qtyLoose, 0);
      expect(l.baseQty, 0);
      expect(l.rate, 0);
      expect(l.taxAmount, 0);
      expect(l.finalAmount, 0);
      expect(l.qtyReceived, 0);
      expect(l.qtyOnHandAtOrder, isNull);
      expect(l.reorderLevelAtOrder, isNull);
    });

    test('fromJson — full numeric fields as int/string/double variants', () {
      final l = PurchaseOrderLineModel.fromJson({
        ...minimalJson,
        'base_qty': 10,
        'rate': '100.5',
        'final_amount': 1160.75,
        'qty_on_hand_at_order': 25,
      });
      expect(l.baseQty, 10.0);
      expect(l.rate, 100.5);
      expect(l.finalAmount, 1160.75);
      expect(l.qtyOnHandAtOrder, 25.0);
    });

    test('fromJson — PostgREST embedded joins (product/uom/tax_group)', () {
      final l = PurchaseOrderLineModel.fromJson({
        ...minimalJson,
        'product':   {'product_code': 'PRD-001', 'product_name': 'Widget A'},
        'uom':       {'description': 'Piece'},
        'tax_group': {'group_name': 'VAT Standard'},
      });
      expect(l.productCode, 'PRD-001');
      expect(l.productName, 'Widget A');
      expect(l.uomLabel, 'Piece');
      expect(l.taxGroupName, 'VAT Standard');
    });

    test('fromJson — embedded joins null does not crash', () {
      final l = PurchaseOrderLineModel.fromJson({
        ...minimalJson,
        'product': null, 'uom': null, 'tax_group': null,
      });
      expect(l.productCode, isNull);
      expect(l.uomLabel, isNull);
      expect(l.taxGroupName, isNull);
    });
  });

  // ── PoChargeLineModel ─────────────────────────────────────────────────────

  group('PoChargeLineModel', () {
    const minimalJson = {
      'id':          'charge-001',
      'serial_no':   1,
      'charge_id':   'charge-master-001',
      'charge_name': 'Freight',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final c = PoChargeLineModel.fromJson(minimalJson);
      expect(c.chargeName, 'Freight');
      expect(c.isTaxable, false);
      expect(c.nature, 'ADD');
      expect(c.amountOrPercent, 'AMOUNT');
      expect(c.amount, 0);
      expect(c.taxAmount, 0);
      expect(c.percent, isNull);
      expect(c.allocationFactor, isNull);
    });

    test('fromJson — full fields, percent-based deduction', () {
      final c = PoChargeLineModel.fromJson({
        ...minimalJson,
        'is_taxable': true,
        'tax_id': 'tax-001',
        'nature': 'DEDUCT',
        'amount_or_percent': 'PERCENT',
        'percent': 5,
        'amount': 61.12,
        'tax_amount': 0,
        'allocation_factor': 0.05,
      });
      expect(c.isTaxable, true);
      expect(c.nature, 'DEDUCT');
      expect(c.amountOrPercent, 'PERCENT');
      expect(c.percent, 5.0);
      expect(c.amount, 61.12);
      expect(c.allocationFactor, 0.05);
    });
  });

  // ── PoPaymentTermModel ────────────────────────────────────────────────────

  group('PoPaymentTermModel', () {
    const minimalJson = {
      'id':        'term-001',
      'serial_no': 1,
      'term_id':   'term-master-001',
      'term_name': 'Credit 30 Days',
    };

    test('fromJson — minimal required fields only', () {
      final t = PoPaymentTermModel.fromJson(minimalJson);
      expect(t.serialNo, 1);
      expect(t.termId, 'term-master-001');
      expect(t.termName, 'Credit 30 Days');
      expect(t.description, isNull);
    });

    test('fromJson — with description', () {
      final t = PoPaymentTermModel.fromJson({
        ...minimalJson,
        'description': '30 days from GRN date',
      });
      expect(t.description, '30 days from GRN date');
    });
  });
}

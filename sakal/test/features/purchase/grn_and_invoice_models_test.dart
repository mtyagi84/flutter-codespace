import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/purchase/data/models/grn_model.dart';
import 'package:sakal/features/purchase/data/models/grn_line_model.dart';
import 'package:sakal/features/purchase/data/models/grn_charge_line_model.dart';
import 'package:sakal/features/purchase/data/models/purchase_invoice_model.dart';
import 'package:sakal/features/purchase/data/models/purchase_return_model.dart';

void main() {
  // ── GrnModel ───────────────────────────────────────────────────────────────

  group('GrnModel', () {
    const minimalJson = {
      'id': 'grn-001',
      'client_id': 'client-001',
      'company_id': 'company-001',
      'location_id': 'loc-001',
      'grn_no': 'GRN-001',
      'grn_date': '2026-07-01',
      'supplier_id': 'supplier-001',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final g = GrnModel.fromJson(minimalJson);
      expect(g.receiptMode, 'DIRECT');
      expect(g.rateToBase, 1);
      expect(g.rateToLocal, 1);
      expect(g.grossAmount, 0);
      expect(g.grandTotal, 0);
      expect(g.status, 'DRAFT');
      expect(g.supplierCode, isNull);
      expect(g.approvedBy, isNull);
    });

    test('fromJson — supplier/location/currency embedded joins', () {
      final g = GrnModel.fromJson({
        ...minimalJson,
        'supplier': {'account_code': 'SUP-001', 'account_name': 'Acme Supplies'},
        'location': {'location_name': 'Main Warehouse'},
        'currency': {'currency_id': 'USD'},
        'receipt_mode': 'AGAINST_PO',
      });
      expect(g.supplierCode, 'SUP-001');
      expect(g.supplierName, 'Acme Supplies');
      expect(g.locationName, 'Main Warehouse');
      expect(g.grnCurrencyCode, 'USD');
      expect(g.receiptMode, 'AGAINST_PO');
    });

    test('fromJson — null embedded joins do not crash', () {
      final g = GrnModel.fromJson({...minimalJson, 'supplier': null, 'location': null, 'currency': null});
      expect(g.supplierCode, isNull);
      expect(g.locationName, isNull);
      expect(g.grnCurrencyCode, isNull);
    });
  });

  // ── GrnBatchModel / GrnSerialModel ────────────────────────────────────────

  group('GrnBatchModel', () {
    test('fromJson — required batch_no only, quantities default to 0', () {
      final b = GrnBatchModel.fromJson(const {'batch_no': 'BATCH-001'});
      expect(b.batchNo, 'BATCH-001');
      expect(b.expiryDate, isNull);
      expect(b.manufacturingDate, isNull);
      expect(b.qtyPack, 0);
      expect(b.qtyLoose, 0);
      expect(b.baseQty, 0);
    });

    test('fromJson — full batch with expiry and manufacturing date', () {
      final b = GrnBatchModel.fromJson(const {
        'batch_no': 'BATCH-002',
        'expiry_date': '2027-01-01',
        'manufacturing_date': '2026-01-01',
        'qty_pack': 10,
        'qty_loose': 5,
        'base_qty': 105,
      });
      expect(b.expiryDate, '2027-01-01');
      expect(b.manufacturingDate, '2026-01-01');
      expect(b.baseQty, 105.0);
    });

    test('toJson — null dates serialize as empty string, not null (server contract)', () {
      final json = GrnBatchModel.fromJson(const {'batch_no': 'BATCH-001'}).toJson();
      expect(json['expiry_date'], '');
      expect(json['manufacturing_date'], '');
    });
  });

  group('GrnSerialModel', () {
    test('fromJson/toJson round-trip', () {
      final s = GrnSerialModel.fromJson(const {'serial_no': 'SN-001'});
      expect(s.serialNo, 'SN-001');
      expect(s.toJson(), {'serial_no': 'SN-001'});
    });
  });

  // ── GrnLineModel ───────────────────────────────────────────────────────────

  group('GrnLineModel', () {
    const minimalJson = {
      'id': 'line-001',
      'serial_no': 1,
      'product_id': 'prod-001',
    };

    test('fromJson — minimal required fields, uom_id defaults to empty string (not strict, unlike id/productId)', () {
      final l = GrnLineModel.fromJson(minimalJson);
      expect(l.uomId, '');
      expect(l.uomConversionFactor, 1);
      expect(l.qtyPack, 0);
      expect(l.baseQty, 0);
      expect(l.batches, isEmpty);
      expect(l.serials, isEmpty);
    });

    test('fromJson — product/uom/tax_group embedded joins + Against-PO traceability', () {
      final l = GrnLineModel.fromJson({
        ...minimalJson,
        'product': {'product_code': 'PRD-001', 'product_name': 'Widget A'},
        'uom': {'description': 'Piece'},
        'tax_group': {'group_name': 'VAT Standard'},
        'source_po_order_no': 'PO-001',
        'source_po_line_serial': 1,
      });
      expect(l.productCode, 'PRD-001');
      expect(l.uomLabel, 'Piece');
      expect(l.taxGroupName, 'VAT Standard');
      expect(l.sourcePoOrderNo, 'PO-001');
      expect(l.sourcePoLineSerial, 1);
    });

    test('withChildren — attaches batches/serials fetched via a second query without touching other fields', () {
      final base = GrnLineModel.fromJson(minimalJson);
      final withBatch = base.withChildren(
        batches: [const GrnBatchModel(batchNo: 'B1', baseQty: 10)],
      );
      expect(withBatch.batches, hasLength(1));
      expect(withBatch.batches.first.batchNo, 'B1');
      expect(withBatch.serials, isEmpty); // untouched, still default
      expect(withBatch.productId, base.productId);
    });

    test('withChildren — omitting a param keeps the existing list, not resets it', () {
      final withBatch = GrnLineModel.fromJson(minimalJson)
          .withChildren(batches: [const GrnBatchModel(batchNo: 'B1')]);
      final stillHasBatch = withBatch.withChildren(serials: [const GrnSerialModel(serialNo: 'S1')]);
      expect(stillHasBatch.batches, hasLength(1)); // preserved from the first withChildren call
      expect(stillHasBatch.serials, hasLength(1));
    });
  });

  // ── GrnChargeLineModel ─────────────────────────────────────────────────────

  group('GrnChargeLineModel', () {
    const minimalJson = {
      'id': 'charge-001',
      'serial_no': 1,
      'charge_id': 'charge-master-001',
      'charge_name': 'Freight',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final c = GrnChargeLineModel.fromJson(minimalJson);
      expect(c.isTaxable, false);
      expect(c.nature, 'ADD');
      expect(c.amountOrPercent, 'AMOUNT');
      expect(c.amount, 0);
      expect(c.percent, isNull);
      expect(c.allocationFactor, isNull);
    });

    test('fromJson — DEDUCT-nature charge carried forward from a source PO', () {
      final c = GrnChargeLineModel.fromJson({
        ...minimalJson,
        'nature': 'DEDUCT',
        'is_taxable': true,
        'tax_id': 'tax-001',
        'amount': 61.12,
        'source_po_order_no': 'PO-001',
        'allocation_factor': 0.05,
      });
      expect(c.nature, 'DEDUCT');
      expect(c.isTaxable, true);
      expect(c.sourcePoOrderNo, 'PO-001');
      expect(c.allocationFactor, 0.05);
    });
  });

  // ── PurchaseInvoiceModel ───────────────────────────────────────────────────

  group('PurchaseInvoiceModel', () {
    const minimalJson = {
      'id': 'inv-001',
      'client_id': 'client-001',
      'company_id': 'company-001',
      'location_id': 'loc-001',
      'invoice_no': 'PINV-001',
      'invoice_date': '2026-07-01',
      'supplier_id': 'supplier-001',
      'supplier_invoice_no': 'SUP-BILL-99',
      'supplier_invoice_date': '2026-06-28',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final inv = PurchaseInvoiceModel.fromJson(minimalJson);
      expect(inv.supplierInvoiceNo, 'SUP-BILL-99');
      expect(inv.rateToBase, 1);
      expect(inv.taxableAmount, 0);
      expect(inv.exchangeDiffBase, 0);
      expect(inv.status, 'DRAFT');
    });

    test('fromJson — supplier/location/currency embeds + exchange difference posted', () {
      final inv = PurchaseInvoiceModel.fromJson({
        ...minimalJson,
        'supplier': {'account_code': 'SUP-001', 'account_name': 'Acme Supplies'},
        'location': {'location_name': 'Main Warehouse'},
        'currency': {'currency_id': 'EUR'},
        'exchange_diff_base': 15.5,
        'status': 'APPROVED',
        'posted_voucher_no': 'PUR-001',
      });
      expect(inv.supplierName, 'Acme Supplies');
      expect(inv.invoiceCurrencyCode, 'EUR');
      expect(inv.exchangeDiffBase, 15.5);
      expect(inv.postedVoucherNo, 'PUR-001');
    });
  });

  // ── PurchaseReturnModel ────────────────────────────────────────────────────

  group('PurchaseReturnModel', () {
    const minimalJson = {
      'id': 'ret-001',
      'client_id': 'client-001',
      'company_id': 'company-001',
      'location_id': 'loc-001',
      'return_no': 'RET-001',
      'return_date': '2026-07-01',
      'supplier_id': 'supplier-001',
    };

    test('fromJson — minimal required fields only, safe defaults for the rest', () {
      final r = PurchaseReturnModel.fromJson(minimalJson);
      expect(r.rateToBase, 1);
      expect(r.taxableAmount, 0);
      expect(r.chargesAmount, 0);
      expect(r.returnTotal, 0);
      expect(r.status, 'DRAFT');
      expect(r.reason, isNull);
    });

    test('fromJson — reason is a free-text audit label, not a business-logic branch', () {
      final r = PurchaseReturnModel.fromJson({
        ...minimalJson,
        'reason': 'Damaged in transit — wrong entry, reversing GRN',
        'return_total': 500.0,
        'status': 'APPROVED',
      });
      expect(r.reason, 'Damaged in transit — wrong entry, reversing GRN');
      expect(r.returnTotal, 500.0);
    });

    test('fromJson — supplier/location/currency embedded joins', () {
      final r = PurchaseReturnModel.fromJson({
        ...minimalJson,
        'supplier': {'account_code': 'SUP-001', 'account_name': 'Acme Supplies'},
        'location': {'location_name': 'Main Warehouse'},
        'currency': {'currency_id': 'USD'},
      });
      expect(r.supplierCode, 'SUP-001');
      expect(r.locationName, 'Main Warehouse');
      expect(r.returnCurrencyCode, 'USD');
    });
  });
}

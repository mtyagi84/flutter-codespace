import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/finance/data/models/expense_voucher_model.dart';

void main() {
  group('ExpenseVoucherHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = ExpenseVoucherHeader.fromJson(const {});
      expect(h.transNo, '');
      expect(h.transDate, '');
      expect(h.supplierId, '');
      expect(h.supplierCode, '');
      expect(h.supplierName, '');
      expect(h.billNo, '');
      expect(h.billDate, '');
      expect(h.status, 'DRAFT');
      expect(h.remarks, '');
    });

    test('fromJson — remote shape: nested supplier embed wins', () {
      final h = ExpenseVoucherHeader.fromJson(const {
        'trans_no': 'EXV-001',
        'trans_date': '2026-07-01',
        'supplier_id': 'sup-001',
        'supplier': {'account_code': 'SUP-01', 'account_name': 'City Power Co.'},
        'bill_no': 'BILL-99',
        'bill_date': '2026-06-25',
        'status': 'APPROVED',
        'remarks': 'Monthly electricity bill',
      });
      expect(h.supplierCode, 'SUP-01');
      expect(h.supplierName, 'City Power Co.');
      expect(h.status, 'APPROVED');
    });

    test('fromJson — local cache shape: flat supplier_code/supplier_name used when no nested embed', () {
      final h = ExpenseVoucherHeader.fromJson(const {
        'trans_no': 'EXV-002',
        'supplier_code': 'SUP-02',
        'supplier_name': 'Water Utility Ltd.',
      });
      expect(h.supplierCode, 'SUP-02');
      expect(h.supplierName, 'Water Utility Ltd.');
    });

    test('fromJson — nested embed takes priority over a coexisting flat fallback', () {
      final h = ExpenseVoucherHeader.fromJson(const {
        'supplier': {'account_code': 'FROM-EMBED', 'account_name': 'Embed Name'},
        'supplier_code': 'FROM-FLAT',
        'supplier_name': 'Flat Name',
      });
      expect(h.supplierCode, 'FROM-EMBED');
      expect(h.supplierName, 'Embed Name');
    });

    test('fromJson — null supplier embed falls through to flat fallback without crashing', () {
      final h = ExpenseVoucherHeader.fromJson(const {
        'supplier': null,
        'supplier_code': 'SUP-03',
        'supplier_name': 'Fallback Name',
      });
      expect(h.supplierCode, 'SUP-03');
      expect(h.supplierName, 'Fallback Name');
    });
  });
}

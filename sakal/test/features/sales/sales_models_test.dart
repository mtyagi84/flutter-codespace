import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/sales/data/models/sales_quotation_header.dart';
import 'package:sakal/features/sales/data/models/sales_order_header.dart';
import 'package:sakal/features/sales/data/models/sales_invoice_header.dart';
import 'package:sakal/features/sales/data/models/sales_return_header.dart';
import 'package:sakal/features/sales/data/models/sales_delivery_header.dart';
import 'package:sakal/features/sales/data/models/cash_receipt_header.dart';
import 'package:sakal/features/sales/data/models/price_master_header.dart';

void main() {
  // ── SalesQuotationHeader ──────────────────────────────────────────────────

  group('SalesQuotationHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = SalesQuotationHeader.fromJson(const {});
      expect(h.quotationNo, '');
      expect(h.validUntilDate, isNull);
      expect(h.customerType, 'CUSTOMER');
      expect(h.partyName, '');
      expect(h.status, 'DRAFT');
      expect(h.grandTotal, 0);
      expect(h.currencyId, '');
    });

    test('fromJson — currency embed resolves, numeric grand_total coerces from int', () {
      final h = SalesQuotationHeader.fromJson(const {
        'quotation_no': 'QUO-001',
        'quotation_date': '2026-07-01',
        'valid_until_date': '2026-07-15',
        'customer_type': 'PROSPECT',
        'party_name': 'Jane Prospect',
        'status': 'APPROVED',
        'grand_total': 1000,
        'currency': {'currency_id': 'USD'},
      });
      expect(h.validUntilDate, '2026-07-15');
      expect(h.customerType, 'PROSPECT');
      expect(h.grandTotal, 1000.0);
      expect(h.currencyId, 'USD');
    });

    test('fromJson — null currency embed does not crash', () {
      final h = SalesQuotationHeader.fromJson(const {'currency': null});
      expect(h.currencyId, '');
    });
  });

  // ── SalesOrderHeader ──────────────────────────────────────────────────────

  group('SalesOrderHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = SalesOrderHeader.fromJson(const {});
      expect(h.orderNo, '');
      expect(h.orderMode, 'DIRECT');
      expect(h.sourceQuotationNo, isNull);
      expect(h.customerName, '');
      expect(h.customerPoRef, '');
      expect(h.status, 'DRAFT');
      expect(h.grandTotal, 0);
    });

    test('fromJson — customer/currency embeds + against-quotation mode', () {
      final h = SalesOrderHeader.fromJson(const {
        'order_no': 'SO-001',
        'order_date': '2026-07-01',
        'order_mode': 'AGAINST_QUOTATION',
        'source_quotation_no': 'QUO-001',
        'customer': {'account_name': 'Acme Retail'},
        'customer_po_ref': 'PO-REF-99',
        'status': 'APPROVED',
        'grand_total': 2500.50,
        'currency': {'currency_id': 'USD'},
      });
      expect(h.orderMode, 'AGAINST_QUOTATION');
      expect(h.sourceQuotationNo, 'QUO-001');
      expect(h.customerName, 'Acme Retail');
      expect(h.customerPoRef, 'PO-REF-99');
      expect(h.grandTotal, 2500.50);
    });

    test('fromJson — null customer/currency embeds do not crash', () {
      final h = SalesOrderHeader.fromJson(const {'customer': null, 'currency': null});
      expect(h.customerName, '');
      expect(h.currencyId, '');
    });

    test('search-relevant field customerPoRef is populated independently of customerName', () {
      // Real bug caught during today's rollout: Sales Order's search filter
      // matches customer_po_ref, not customer name — this field must exist
      // and be readable on its own.
      final h = SalesOrderHeader.fromJson(const {'customer_po_ref': 'REF-123'});
      expect(h.customerPoRef, 'REF-123');
    });
  });

  // ── SalesInvoiceHeader ────────────────────────────────────────────────────

  group('SalesInvoiceHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = SalesInvoiceHeader.fromJson(const {});
      expect(h.invoiceNo, '');
      expect(h.saleType, 'CASH');
      expect(h.customerName, '');
      expect(h.partyName, '');
      expect(h.status, 'DRAFT');
      expect(h.grandTotal, 0);
      expect(h.currencyId, '');
      expect(h.stockDispatchMode, 'IMMEDIATE');
    });

    test('fromJson — customer/currency embeds resolve, deferred dispatch mode carries through', () {
      final h = SalesInvoiceHeader.fromJson(const {
        'invoice_no': 'INV-001',
        'invoice_date': '2026-07-01',
        'sale_type': 'CREDIT',
        'customer': {'account_name': 'Acme Retail'},
        'party_name': 'Walk-in',
        'status': 'APPROVED',
        'grand_total': 500,
        'currency': {'currency_id': 'USD'},
        'stock_dispatch_mode': 'DEFERRED',
      });
      expect(h.saleType, 'CREDIT');
      expect(h.customerName, 'Acme Retail');
      expect(h.stockDispatchMode, 'DEFERRED');
    });

    test('fromJson — null customer/currency embeds fall back to party_name / empty currency', () {
      final h = SalesInvoiceHeader.fromJson(const {
        'customer': null,
        'party_name': 'Walk-in Customer',
        'currency': null,
      });
      expect(h.customerName, '');
      expect(h.partyName, 'Walk-in Customer');
      expect(h.currencyId, '');
    });
  });

  // ── SalesReturnHeader ─────────────────────────────────────────────────────

  group('SalesReturnHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = SalesReturnHeader.fromJson(const {});
      expect(h.returnNo, '');
      expect(h.returnDate, isNull);
      expect(h.invoiceNo, isNull);
      expect(h.customerCode, isNull);
      expect(h.customerName, isNull);
      expect(h.returnTotal, 0);
      expect(h.status, 'DRAFT');
    });

    test('fromJson — customer embed resolves both code and name', () {
      final h = SalesReturnHeader.fromJson(const {
        'return_no': 'SRET-001',
        'return_date': '2026-07-01',
        'invoice_no': 'INV-001',
        'customer': {'account_code': 'CUST-01', 'account_name': 'Acme Retail'},
        'return_total': 150.25,
        'status': 'APPROVED',
      });
      expect(h.customerCode, 'CUST-01');
      expect(h.customerName, 'Acme Retail');
      expect(h.returnTotal, 150.25);
    });

    test('fromJson — null customer embed does not crash', () {
      final h = SalesReturnHeader.fromJson(const {'customer': null});
      expect(h.customerCode, isNull);
      expect(h.customerName, isNull);
    });
  });

  // ── SalesDeliveryHeader ───────────────────────────────────────────────────

  group('SalesDeliveryHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = SalesDeliveryHeader.fromJson(const {});
      expect(h.deliveryNo, '');
      expect(h.deliveryDate, isNull);
      expect(h.invoiceNo, isNull);
      expect(h.customerCode, isNull);
      expect(h.customerName, isNull);
      expect(h.locationName, isNull);
      expect(h.status, 'DRAFT');
    });

    test('fromJson — customer and location embeds resolve independently', () {
      final h = SalesDeliveryHeader.fromJson(const {
        'delivery_no': 'DEL-001',
        'delivery_date': '2026-07-01',
        'invoice_no': 'INV-001',
        'customer': {'account_code': 'CUST-01', 'account_name': 'Acme Retail'},
        'location': {'location_name': 'Main Store'},
        'status': 'DELIVERED',
      });
      expect(h.customerName, 'Acme Retail');
      expect(h.locationName, 'Main Store');
    });

    test('fromJson — null customer/location embeds do not crash', () {
      final h = SalesDeliveryHeader.fromJson(const {'customer': null, 'location': null});
      expect(h.customerName, isNull);
      expect(h.locationName, isNull);
    });
  });

  // ── CashReceiptHeader ─────────────────────────────────────────────────────

  group('CashReceiptHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = CashReceiptHeader.fromJson(const {});
      expect(h.receiptNo, '');
      expect(h.customerName, isNull);
      expect(h.locationName, isNull);
      expect(h.localAmount, 0);
      expect(h.baseAmount, 0);
      expect(h.status, 'DRAFT');
    });

    test('fromJson — customer/location embeds + both currency-leg amounts resolve independently', () {
      final h = CashReceiptHeader.fromJson(const {
        'receipt_no': 'CRCT-001',
        'receipt_date': '2026-07-01',
        'customer': {'account_code': 'CUST-01', 'account_name': 'Acme Retail'},
        'location': {'location_name': 'Main Store'},
        'local_amount': 500,
        'base_amount': 480.5,
        'status': 'APPROVED',
      });
      expect(h.customerName, 'Acme Retail');
      expect(h.locationName, 'Main Store');
      expect(h.localAmount, 500.0);
      expect(h.baseAmount, 480.5);
    });
  });

  // ── PriceMasterHeader ─────────────────────────────────────────────────────

  group('PriceMasterHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = PriceMasterHeader.fromJson(const {});
      expect(h.entryNo, '');
      expect(h.locationName, isNull);
      expect(h.priceType, 'GENERIC');
      expect(h.customerCode, isNull);
      expect(h.currencyId, isNull);
      expect(h.status, 'DRAFT');
      expect(h.lineCount, 0);
    });

    test('fromJson — customer/location/currency embeds + pre-flattened line_count', () {
      // line_count is derived and flattened by the datasource from a
      // PostgREST rid_price_master_lines(count) aggregate embed BEFORE
      // fromJson runs — fromJson itself only ever sees a plain int.
      final h = PriceMasterHeader.fromJson(const {
        'entry_no': 'PM-001',
        'entry_date': '2026-07-01',
        'location': {'location_name': 'Main Store'},
        'price_type': 'CUSTOMER_SPECIFIC',
        'customer': {'account_code': 'CUST-01', 'account_name': 'Acme Retail'},
        'currency': {'currency_id': 'USD'},
        'status': 'ACTIVE',
        'line_count': 12,
      });
      expect(h.locationName, 'Main Store');
      expect(h.priceType, 'CUSTOMER_SPECIFIC');
      expect(h.customerCode, 'CUST-01');
      expect(h.currencyId, 'USD');
      expect(h.lineCount, 12);
    });

    test('fromJson — null customer/location/currency embeds do not crash', () {
      final h = PriceMasterHeader.fromJson(const {
        'customer': null, 'location': null, 'currency': null,
      });
      expect(h.customerCode, isNull);
      expect(h.locationName, isNull);
      expect(h.currencyId, isNull);
    });
  });
}

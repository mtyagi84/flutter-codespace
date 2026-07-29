import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/inventory/data/models/material_requisition_model.dart';
import 'package:sakal/features/inventory/data/models/material_issue_model.dart';
import 'package:sakal/features/inventory/data/models/stock_transfer_request_model.dart';
import 'package:sakal/features/inventory/data/models/stock_transfer_model.dart';
import 'package:sakal/features/inventory/data/models/stock_receipt_model.dart';
import 'package:sakal/features/inventory/data/models/stock_adjustment_model.dart';
import 'package:sakal/features/inventory/data/models/opening_stock_model.dart';
import 'package:sakal/features/inventory/data/models/stock_count_model.dart';
import 'package:sakal/features/inventory/data/models/stock_count_review_model.dart';

void main() {
  // ── MaterialRequisitionHeader ────────────────────────────────────────────

  group('MaterialRequisitionHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = MaterialRequisitionHeader.fromJson(const {});
      expect(h.requisitionNo, '');
      expect(h.requisitionDate, '');
      expect(h.requestedBy, '');
      expect(h.reason, '');
      expect(h.locationId, '');
      expect(h.locationName, '');
      expect(h.status, 'DRAFT');
    });

    test('fromJson — all fields present, including location embed', () {
      final h = MaterialRequisitionHeader.fromJson(const {
        'requisition_no': 'MREQ-001',
        'requisition_date': '2026-07-01',
        'requested_by': 'user-001',
        'reason': 'Monthly consumption',
        'location_id': 'loc-001',
        'location': {'location_name': 'Main Store'},
        'status': 'APPROVED',
      });
      expect(h.requisitionNo, 'MREQ-001');
      expect(h.locationName, 'Main Store');
      expect(h.status, 'APPROVED');
    });

    test('fromJson — null location embed does not crash', () {
      final h = MaterialRequisitionHeader.fromJson(const {'location': null});
      expect(h.locationName, '');
    });
  });

  // ── MaterialIssueHeader ───────────────────────────────────────────────────

  group('MaterialIssueHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = MaterialIssueHeader.fromJson(const {});
      expect(h.issueNo, '');
      expect(h.issueDate, '');
      expect(h.locationId, '');
      expect(h.locationName, '');
      expect(h.status, 'DRAFT');
    });

    test('fromJson — all fields present, including location embed', () {
      final h = MaterialIssueHeader.fromJson(const {
        'issue_no': 'MISS-001',
        'issue_date': '2026-07-01',
        'location_id': 'loc-001',
        'location': {'location_name': 'Main Store'},
        'status': 'APPROVED',
      });
      expect(h.issueNo, 'MISS-001');
      expect(h.locationName, 'Main Store');
      expect(h.status, 'APPROVED');
    });

    test('fromJson — null location embed does not crash', () {
      final h = MaterialIssueHeader.fromJson(const {'location': null});
      expect(h.locationName, '');
    });
  });

  // ── StockTransferRequestHeader ────────────────────────────────────────────

  group('StockTransferRequestHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = StockTransferRequestHeader.fromJson(const {});
      expect(h.requestNo, '');
      expect(h.fromLocationId, '');
      expect(h.fromLocationName, '');
      expect(h.toLocationId, '');
      expect(h.toLocationName, '');
      expect(h.status, 'DRAFT');
    });

    test('fromJson — from/to location embeds resolve independently', () {
      final h = StockTransferRequestHeader.fromJson(const {
        'request_no': 'STR-001',
        'request_date': '2026-07-01',
        'from_location_id': 'loc-001',
        'from_location': {'location_name': 'Warehouse A'},
        'to_location_id': 'loc-002',
        'to_location': {'location_name': 'Store B'},
        'status': 'DRAFT',
      });
      expect(h.fromLocationName, 'Warehouse A');
      expect(h.toLocationName, 'Store B');
    });

    test('fromJson — null from/to embeds do not crash', () {
      final h = StockTransferRequestHeader.fromJson(const {
        'from_location': null,
        'to_location': null,
      });
      expect(h.fromLocationName, '');
      expect(h.toLocationName, '');
    });
  });

  // ── StockTransferHeader ───────────────────────────────────────────────────

  group('StockTransferHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = StockTransferHeader.fromJson(const {});
      expect(h.transferNo, '');
      expect(h.fromLocationName, '');
      expect(h.toLocationName, '');
      expect(h.againstRequest, false);
      expect(h.postingMode, isNull);
      expect(h.status, 'DRAFT');
    });

    test('modeLabel — explicit posting_mode wins over against_request', () {
      final h = StockTransferHeader.fromJson(const {
        'posting_mode': 'Custom Mode',
        'against_request': true,
      });
      expect(h.modeLabel, 'Custom Mode');
    });

    test('modeLabel — falls back to Against Request when posting_mode absent and against_request true', () {
      final h = StockTransferHeader.fromJson(const {'against_request': true});
      expect(h.postingMode, isNull);
      expect(h.modeLabel, 'Against Request');
    });

    test('modeLabel — falls back to Direct when posting_mode absent and against_request false/absent', () {
      final h = StockTransferHeader.fromJson(const {});
      expect(h.modeLabel, 'Direct');
    });

    test('fromJson — from/to location embeds resolve independently', () {
      final h = StockTransferHeader.fromJson(const {
        'transfer_no': 'TRF-001',
        'transfer_date': '2026-07-01',
        'from_location': {'location_name': 'Warehouse A'},
        'to_location': {'location_name': 'Store B'},
      });
      expect(h.fromLocationName, 'Warehouse A');
      expect(h.toLocationName, 'Store B');
    });
  });

  // ── StockReceiptHeader ────────────────────────────────────────────────────

  group('StockReceiptHeader', () {
    test('fromJson — missing fields default to safe values, source_transfer_no stays nullable', () {
      final h = StockReceiptHeader.fromJson(const {});
      expect(h.receiptNo, '');
      expect(h.fromLocationName, '');
      expect(h.toLocationName, '');
      expect(h.sourceTransferNo, isNull);
      expect(h.status, 'DRAFT');
    });

    test('fromJson — all fields present including source_transfer_no', () {
      final h = StockReceiptHeader.fromJson(const {
        'receipt_no': 'SRC-001',
        'receipt_date': '2026-07-01',
        'from_location': {'location_name': 'Warehouse A'},
        'to_location': {'location_name': 'Store B'},
        'source_transfer_no': 'TRF-001',
        'status': 'APPROVED',
      });
      expect(h.sourceTransferNo, 'TRF-001');
      expect(h.fromLocationName, 'Warehouse A');
      expect(h.toLocationName, 'Store B');
    });
  });

  // ── StockAdjustmentHeader ─────────────────────────────────────────────────

  group('StockAdjustmentHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = StockAdjustmentHeader.fromJson(const {});
      expect(h.adjustmentNo, '');
      expect(h.locationName, '');
      expect(h.reasonLabel, '');
      expect(h.status, 'DRAFT');
    });

    test('fromJson — location and reason embeds resolve independently', () {
      final h = StockAdjustmentHeader.fromJson(const {
        'adjustment_no': 'ADJ-001',
        'adjustment_date': '2026-07-01',
        'location': {'location_name': 'Main Store'},
        'reason_id': 'reason-001',
        'reason': {'description': 'Damaged goods'},
        'status': 'APPROVED',
      });
      expect(h.locationName, 'Main Store');
      expect(h.reasonLabel, 'Damaged goods');
    });

    test('fromJson — null location/reason embeds do not crash', () {
      final h = StockAdjustmentHeader.fromJson(const {'location': null, 'reason': null});
      expect(h.locationName, '');
      expect(h.reasonLabel, '');
    });
  });

  // ── OpeningStockHeader ────────────────────────────────────────────────────

  group('OpeningStockHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = OpeningStockHeader.fromJson(const {});
      expect(h.openingNo, '');
      expect(h.locationName, '');
      expect(h.status, 'DRAFT');
    });

    test('fromJson — all fields present including location embed', () {
      final h = OpeningStockHeader.fromJson(const {
        'opening_no': 'OPST-001',
        'opening_date': '2026-07-01',
        'location': {'location_name': 'Main Store'},
        'status': 'APPROVED',
      });
      expect(h.locationName, 'Main Store');
      expect(h.status, 'APPROVED');
    });
  });

  // ── StockCountHeader ──────────────────────────────────────────────────────

  group('StockCountHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = StockCountHeader.fromJson(const {});
      expect(h.countNo, '');
      expect(h.locationName, '');
      expect(h.status, 'DRAFT');
    });

    test('fromJson — all fields present including location embed', () {
      final h = StockCountHeader.fromJson(const {
        'count_no': 'CNT-001',
        'count_date': '2026-07-01',
        'location': {'location_name': 'Main Store'},
        'status': 'SUBMITTED',
      });
      expect(h.locationName, 'Main Store');
      expect(h.status, 'SUBMITTED');
    });
  });

  // ── StockCountReviewHeader ────────────────────────────────────────────────

  group('StockCountReviewHeader', () {
    test('fromJson — missing fields default to safe values, posted_adjustment_no stays nullable', () {
      final h = StockCountReviewHeader.fromJson(const {});
      expect(h.reviewNo, '');
      expect(h.locationName, '');
      expect(h.postedAdjustmentNo, isNull);
      expect(h.status, 'DRAFT');
    });

    test('fromJson — all fields present including posted_adjustment_no', () {
      final h = StockCountReviewHeader.fromJson(const {
        'review_no': 'CNTR-001',
        'review_date': '2026-07-01',
        'location': {'location_name': 'Main Store'},
        'posted_adjustment_no': 'ADJ-005',
        'status': 'APPROVED',
      });
      expect(h.postedAdjustmentNo, 'ADJ-005');
      expect(h.locationName, 'Main Store');
    });
  });
}

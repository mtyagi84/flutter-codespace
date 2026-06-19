// Exchange rate screen — pure logic tests (no Flutter widgets, no network).
// Tests the _RateRow mid-rate calculation and validation rules.
// Run: flutter test test/features/finance/exchange_rate_logic_test.dart

import 'package:flutter_test/flutter_test.dart';

// ── Extracted logic (mirrors _RateRow in exchange_rate_screen.dart) ──────────
// Keeping these as plain functions so they are testable without importing
// Flutter widget code (which requires a binding).

double? midRate(double? buying, double? selling) {
  if (buying  == null || buying  <= 0) return null;
  if (selling == null || selling <= 0) return null;
  return (buying + selling) / 2;
}

bool isRowValid(String buying, String selling) {
  return (double.tryParse(buying)  ?? 0) > 0 &&
         (double.tryParse(selling) ?? 0) > 0;
}

String formatMid(double? mid) {
  if (mid == null)   return '—';
  if (mid >= 1000)   return mid.toStringAsFixed(2);
  if (mid >= 1)      return mid.toStringAsFixed(4);
  return mid.toStringAsFixed(8);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('midRate()', () {
    test('returns (buying + selling) / 2', () {
      expect(midRate(2780, 2820), equals(2800.0));
    });

    test('returns exact midpoint for small rates', () {
      expect(midRate(0.925, 0.935), closeTo(0.930, 0.0001));
    });

    test('returns null when buying is null', () {
      expect(midRate(null, 2820), isNull);
    });

    test('returns null when selling is null', () {
      expect(midRate(2780, null), isNull);
    });

    test('returns null when buying is zero', () {
      expect(midRate(0, 2820), isNull);
    });

    test('returns null when selling is zero', () {
      expect(midRate(2780, 0), isNull);
    });

    test('returns null when buying is negative', () {
      expect(midRate(-100, 2820), isNull);
    });

    test('works for sub-1 rates (EUR/USD style)', () {
      expect(midRate(0.92, 0.94), closeTo(0.93, 0.0001));
    });
  });

  group('isRowValid()', () {
    test('valid when both buying and selling are positive numbers', () {
      expect(isRowValid('2780', '2820'), isTrue);
    });

    test('invalid when buying is empty', () {
      expect(isRowValid('', '2820'), isFalse);
    });

    test('invalid when selling is empty', () {
      expect(isRowValid('2780', ''), isFalse);
    });

    test('invalid when buying is zero', () {
      expect(isRowValid('0', '2820'), isFalse);
    });

    test('invalid when selling is zero', () {
      expect(isRowValid('2780', '0'), isFalse);
    });

    test('invalid when buying is non-numeric text', () {
      expect(isRowValid('abc', '2820'), isFalse);
    });

    test('valid for decimal rates', () {
      expect(isRowValid('0.925', '0.935'), isTrue);
    });
  });

  group('formatMid()', () {
    test('returns em dash for null', () {
      expect(formatMid(null), equals('—'));
    });

    test('formats large rates (CDF) to 2 decimal places', () {
      expect(formatMid(2800.0), equals('2800.00'));
    });

    test('formats mid rates (ZMW) to 4 decimal places', () {
      expect(formatMid(26.5), equals('26.5000'));
    });

    test('formats sub-1 rates (EUR) to 8 decimal places', () {
      expect(formatMid(0.93), equals('0.93000000'));
    });

    test('boundary: exactly 1.0 uses 4 decimal format', () {
      expect(formatMid(1.0), equals('1.0000'));
    });

    test('boundary: exactly 1000.0 uses 2 decimal format', () {
      expect(formatMid(1000.0), equals('1000.00'));
    });
  });
}

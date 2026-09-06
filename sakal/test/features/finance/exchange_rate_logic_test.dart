// Exchange rate screen — pure logic tests (no Flutter widgets, no network).
// Tests the _RateRow validation and formatting rules.
// Run: flutter test test/features/finance/exchange_rate_logic_test.dart
//
// Migration 179: the third rate column ("Mid (auto)") is no longer derived
// as (buying + selling) / 2 -- it's an independently user-entered "Exchange
// Rate" field, unrelated to the other two, and mandatory like they already
// are. There is no more derivation logic to test; isRowValid now requires
// all three fields, and formatRate (the smart-precision formatter) is
// generic across all three rather than "mid rate" specific.

import 'package:flutter_test/flutter_test.dart';

// ── Extracted logic (mirrors _RateRow in exchange_rate_screen.dart) ──────────
// Keeping these as plain functions so they are testable without importing
// Flutter widget code (which requires a binding).

bool isRowValid(String buying, String selling, String exchange) {
  return (double.tryParse(buying)   ?? 0) > 0 &&
         (double.tryParse(selling)  ?? 0) > 0 &&
         (double.tryParse(exchange) ?? 0) > 0;
}

String formatRate(double rate) {
  if (rate >= 1000) return rate.toStringAsFixed(2);
  if (rate >= 1)    return rate.toStringAsFixed(4);
  return rate.toStringAsFixed(8);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('isRowValid()', () {
    test('valid when all three rates are positive numbers', () {
      expect(isRowValid('2780', '2820', '2800'), isTrue);
    });

    test('invalid when buying is empty', () {
      expect(isRowValid('', '2820', '2800'), isFalse);
    });

    test('invalid when selling is empty', () {
      expect(isRowValid('2780', '', '2800'), isFalse);
    });

    test('invalid when exchange rate is empty', () {
      expect(isRowValid('2780', '2820', ''), isFalse);
    });

    test('invalid when buying is zero', () {
      expect(isRowValid('0', '2820', '2800'), isFalse);
    });

    test('invalid when selling is zero', () {
      expect(isRowValid('2780', '0', '2800'), isFalse);
    });

    test('invalid when exchange rate is zero', () {
      expect(isRowValid('2780', '2820', '0'), isFalse);
    });

    test('invalid when buying is non-numeric text', () {
      expect(isRowValid('abc', '2820', '2800'), isFalse);
    });

    test('valid for decimal rates', () {
      expect(isRowValid('0.925', '0.935', '0.930'), isTrue);
    });

    test('the three rates need not agree with each other at all', () {
      // Independently entered now (migration 179) — no relationship
      // enforced between buying/selling/exchange.
      expect(isRowValid('2780', '2900', '10'), isTrue);
    });
  });

  group('formatRate()', () {
    test('formats large rates (CDF) to 2 decimal places', () {
      expect(formatRate(2800.0), equals('2800.00'));
    });

    test('formats mid-magnitude rates (ZMW) to 4 decimal places', () {
      expect(formatRate(26.5), equals('26.5000'));
    });

    test('formats sub-1 rates (EUR) to 8 decimal places', () {
      expect(formatRate(0.93), equals('0.93000000'));
    });

    test('boundary: exactly 1.0 uses 4 decimal format', () {
      expect(formatRate(1.0), equals('1.0000'));
    });

    test('boundary: exactly 1000.0 uses 2 decimal format', () {
      expect(formatRate(1000.0), equals('1000.00'));
    });
  });
}

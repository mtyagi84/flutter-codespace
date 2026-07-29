import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/utils/app_number_format.dart';

void main() {
  // ── amount() — always 2 decimal places regardless of style ───────────────

  group('AppNumberFormat.amount', () {
    test('INTERNATIONAL style groups every 3 digits', () {
      expect(AppNumberFormat.amount(115356, 'INTERNATIONAL'), '115,356.00');
      expect(AppNumberFormat.amount(1000000, 'INTERNATIONAL'), '1,000,000.00');
      expect(AppNumberFormat.amount(999, 'INTERNATIONAL'), '999.00');
    });

    test('INDIAN style groups by 2 after the first group of 3 (lakh/crore convention)', () {
      // 115356 = one lakh fifteen thousand three hundred fifty-six.
      expect(AppNumberFormat.amount(115356, 'INDIAN'), '1,15,356.00');
      // 10000000 = one crore.
      expect(AppNumberFormat.amount(10000000, 'INDIAN'), '1,00,00,000.00');
      expect(AppNumberFormat.amount(999, 'INDIAN'), '999.00');
    });

    test('always rounds to exactly 2 decimals, regardless of the input precision', () {
      expect(AppNumberFormat.amount(1234.5, 'INTERNATIONAL'), '1,234.50');
      expect(AppNumberFormat.amount(1234.567, 'INTERNATIONAL'), '1,234.57');
      expect(AppNumberFormat.amount(1234, 'INTERNATIONAL'), '1,234.00');
    });

    test('negative amounts (e.g. a return/refund total) format with a leading minus', () {
      expect(AppNumberFormat.amount(-500, 'INTERNATIONAL'), '-500.00');
      expect(AppNumberFormat.amount(-115356, 'INDIAN'), '-1,15,356.00');
    });

    test('zero formats as 0.00, not blank', () {
      expect(AppNumberFormat.amount(0, 'INTERNATIONAL'), '0.00');
    });

    test('an unrecognized style string falls back to INTERNATIONAL grouping (only INDIAN is special-cased)', () {
      expect(AppNumberFormat.amount(115356, 'SOMETHING_ELSE'), '115,356.00');
    });
  });

  // ── rate() — decimal precision is per-currency, never global ─────────────

  group('AppNumberFormat.rate', () {
    test('a currency with 2 decimal places (e.g. CDF) formats like amount()', () {
      expect(
        AppNumberFormat.rate(2800, decimalPlaces: 2, numberFormatStyle: 'INTERNATIONAL'),
        '2,800.00',
      );
    });

    test('a currency needing higher precision (e.g. a USD unit cost converted from a bulk purchase)', () {
      expect(
        AppNumberFormat.rate(12.34567, decimalPlaces: 4, numberFormatStyle: 'INTERNATIONAL'),
        '12.3457',
      );
    });

    test('decimalPlaces: 0 — no decimal point at all, not "X.0" or "X."', () {
      final formatted = AppNumberFormat.rate(115356, decimalPlaces: 0, numberFormatStyle: 'INDIAN');
      expect(formatted, '1,15,356');
      expect(formatted.contains('.'), false);
    });

    test('INDIAN grouping applies to rate() exactly like amount()', () {
      expect(
        AppNumberFormat.rate(115356, decimalPlaces: 2, numberFormatStyle: 'INDIAN'),
        '1,15,356.00',
      );
    });
  });
}

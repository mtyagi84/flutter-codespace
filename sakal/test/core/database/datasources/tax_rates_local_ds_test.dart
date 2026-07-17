import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/database/datasources/tax_rates_local_ds.dart';

void main() {
  group('TaxRatesLocalDs.selectActiveRates', () {
    test('picks the rate whose effective window contains asOf', () {
      final rows = [
        {'tax_id': 't1', 'rate': 10, 'effective_from': '2020-01-01', 'effective_to': null},
      ];
      final result = TaxRatesLocalDs.selectActiveRates(rows, DateTime(2026, 7, 17));
      expect(result['t1'], 10.0);
    });

    test('skips a row where asOf falls before effective_from', () {
      final rows = [
        {'tax_id': 't1', 'rate': 10, 'effective_from': '2030-01-01', 'effective_to': null},
      ];
      final result = TaxRatesLocalDs.selectActiveRates(rows, DateTime(2026, 7, 17));
      expect(result.containsKey('t1'), isFalse);
    });

    test('skips a row where asOf falls after effective_to', () {
      final rows = [
        {'tax_id': 't1', 'rate': 10, 'effective_from': '2020-01-01', 'effective_to': '2021-12-31'},
      ];
      final result = TaxRatesLocalDs.selectActiveRates(rows, DateTime(2026, 7, 17));
      expect(result.containsKey('t1'), isFalse);
    });

    test('picks the most recent matching row when multiple rows apply, first-match-wins per tax_id', () {
      // Rows given in effective_from DESC order (as the caller pre-sorts) —
      // the newer, still-open-ended rate should win over an older
      // superseded one for the same tax_id.
      final rows = [
        {'tax_id': 't1', 'rate': 15, 'effective_from': '2025-01-01', 'effective_to': null},
        {'tax_id': 't1', 'rate': 10, 'effective_from': '2020-01-01', 'effective_to': '2024-12-31'},
      ];
      final result = TaxRatesLocalDs.selectActiveRates(rows, DateTime(2026, 7, 17));
      expect(result['t1'], 15.0);
    });

    test('handles multiple distinct tax_ids independently', () {
      final rows = [
        {'tax_id': 't1', 'rate': 10, 'effective_from': '2020-01-01', 'effective_to': null},
        {'tax_id': 't2', 'rate': 5, 'effective_from': '2020-01-01', 'effective_to': null},
      ];
      final result = TaxRatesLocalDs.selectActiveRates(rows, DateTime(2026, 7, 17));
      expect(result['t1'], 10.0);
      expect(result['t2'], 5.0);
    });

    test('matches exactly on the boundary dates (inclusive)', () {
      final rows = [
        {'tax_id': 't1', 'rate': 12, 'effective_from': '2026-07-17', 'effective_to': '2026-07-17'},
      ];
      final result = TaxRatesLocalDs.selectActiveRates(rows, DateTime(2026, 7, 17));
      expect(result['t1'], 12.0);
    });

    test('returns an empty map for an empty input', () {
      final result = TaxRatesLocalDs.selectActiveRates(const [], DateTime(2026, 7, 17));
      expect(result, isEmpty);
    });
  });
}

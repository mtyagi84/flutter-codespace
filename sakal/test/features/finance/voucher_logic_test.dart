// Finance voucher — pure logic tests (no Flutter widgets, no network).
// Tests the functions in lib/core/utils/voucher_logic.dart
// Run: flutter test test/features/finance/voucher_logic_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/utils/voucher_logic.dart';

void main() {

  // ── line1Nature ────────────────────────────────────────────────────────────

  group('line1Nature()', () {
    test('CRV — cash comes in — line 1 is DR', () {
      expect(line1Nature('CRV'), equals('DR'));
    });

    test('BRV — bank receives money — line 1 is DR', () {
      expect(line1Nature('BRV'), equals('DR'));
    });

    test('CPV — cash goes out — line 1 is CR', () {
      expect(line1Nature('CPV'), equals('CR'));
    });

    test('BPV — bank pays out — line 1 is CR', () {
      expect(line1Nature('BPV'), equals('CR'));
    });
  });

  // ── counterNature ──────────────────────────────────────────────────────────

  group('counterNature()', () {
    test('opposite of DR is CR', () {
      expect(counterNature('DR'), equals('CR'));
    });

    test('opposite of CR is DR', () {
      expect(counterNature('CR'), equals('DR'));
    });
  });

  // ── isCashVoucher / isBankVoucher ──────────────────────────────────────────

  group('isCashVoucher()', () {
    test('CRV is a cash voucher', () => expect(isCashVoucher('CRV'), isTrue));
    test('CPV is a cash voucher', () => expect(isCashVoucher('CPV'), isTrue));
    test('BRV is not a cash voucher', () => expect(isCashVoucher('BRV'), isFalse));
    test('BPV is not a cash voucher', () => expect(isCashVoucher('BPV'), isFalse));
  });

  group('isBankVoucher()', () {
    test('BRV is a bank voucher', () => expect(isBankVoucher('BRV'), isTrue));
    test('BPV is a bank voucher', () => expect(isBankVoucher('BPV'), isTrue));
    test('CRV is not a bank voucher', () => expect(isBankVoucher('CRV'), isFalse));
    test('CPV is not a bank voucher', () => expect(isBankVoucher('CPV'), isFalse));
  });

  // ── drTotal / crTotal ──────────────────────────────────────────────────────

  group('drTotal()', () {
    test('sums only DR lines', () {
      final lines = [
        (nature: 'DR', amount: 1000.0),
        (nature: 'CR', amount: 1000.0),
        (nature: 'DR', amount: 500.0),
      ];
      expect(drTotal(lines), equals(1500.0));
    });

    test('returns 0 when no DR lines', () {
      final lines = [(nature: 'CR', amount: 1000.0)];
      expect(drTotal(lines), equals(0.0));
    });

    test('returns 0 for empty list', () {
      expect(drTotal([]), equals(0.0));
    });
  });

  group('crTotal()', () {
    test('sums only CR lines', () {
      final lines = [
        (nature: 'DR', amount: 1000.0),
        (nature: 'CR', amount: 600.0),
        (nature: 'CR', amount: 400.0),
      ];
      expect(crTotal(lines), equals(1000.0));
    });

    test('returns 0 when no CR lines', () {
      final lines = [(nature: 'DR', amount: 1000.0)];
      expect(crTotal(lines), equals(0.0));
    });
  });

  // ── isVoucherBalanced ──────────────────────────────────────────────────────

  group('isVoucherBalanced()', () {
    test('balanced when DR equals CR exactly', () {
      expect(isVoucherBalanced(1000.0, 1000.0), isTrue);
    });

    test('balanced within 0.01 tolerance (rounding)', () {
      expect(isVoucherBalanced(1000.0, 1000.009), isTrue);
    });

    test('not balanced when difference exceeds 0.01', () {
      expect(isVoucherBalanced(1000.0, 1000.02), isFalse);
    });

    test('not balanced when DR is zero and CR is not', () {
      expect(isVoucherBalanced(0.0, 500.0), isFalse);
    });

    test('balanced when both are zero (empty voucher)', () {
      expect(isVoucherBalanced(0.0, 0.0), isTrue);
    });
  });

  // ── toBaseAmount ───────────────────────────────────────────────────────────

  group('toBaseAmount()', () {
    test('same currency — returns amount unchanged', () {
      expect(toBaseAmount(2800.0, 2800.0, 'CDF', 'CDF'), equals(2800.0));
    });

    test('converts CDF to USD at rate 2800', () {
      expect(toBaseAmount(2800.0, 2800.0, 'CDF', 'USD'), closeTo(1.0, 0.0001));
    });

    test('converts large CDF amount', () {
      expect(toBaseAmount(28000.0, 2800.0, 'CDF', 'USD'), closeTo(10.0, 0.0001));
    });

    test('rate <= 0 — returns amount unchanged (guard)', () {
      expect(toBaseAmount(1000.0, 0.0, 'CDF', 'USD'), equals(1000.0));
    });

    test('rate of 1 leaves amount unchanged', () {
      expect(toBaseAmount(500.0, 1.0, 'USD', 'USD'), equals(500.0));
    });
  });

  // ── toLocalAmount ──────────────────────────────────────────────────────────

  group('toLocalAmount()', () {
    test('same currency as local — returns amount unchanged', () {
      expect(toLocalAmount(1000.0, 2800.0, 1.0, 'CDF', 'CDF'), equals(1000.0));
    });

    test('converts USD → CDF via base: USD→base(1.0)→CDF(2800)', () {
      // USD amount 100, baseRate=1, localRate=2800
      expect(toLocalAmount(100.0, 1.0, 2800.0, 'USD', 'CDF'), closeTo(280000.0, 0.01));
    });

    test('baseRate <= 0 — returns amount unchanged (guard)', () {
      expect(toLocalAmount(100.0, 0.0, 2800.0, 'USD', 'CDF'), equals(100.0));
    });

    test('localRate <= 0 — returns amount unchanged (guard)', () {
      expect(toLocalAmount(100.0, 1.0, 0.0, 'USD', 'CDF'), equals(100.0));
    });
  });
}

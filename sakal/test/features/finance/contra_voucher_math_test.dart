import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/finance/domain/contra_voucher_math.dart';

void main() {
  const rate = 1 / 2825; // 1 CDF = 0.000353982 USD

  test('receiving less than the system rate is a loss in both currencies', () {
    final gap = ContraMath.gap(from: 282500, to: 95, rate: rate);
    expect(gap, closeTo(14125, 0.001));
    expect(ContraMath.gapInToCurrency(gap, rate), closeTo(5, 0.0001));
    expect(ContraMath.hasGap(gap), isTrue);
  });

  test('receiving more than the system rate is a gain (negative gap)', () {
    final gap = ContraMath.gap(from: 282500, to: 102, rate: rate);
    expect(gap, closeTo(-5650, 0.001));
    expect(ContraMath.gapInToCurrency(gap, rate), closeTo(-2, 0.0001));
  });

  test('an exact system-rate transfer has no difference', () {
    final gap = ContraMath.gap(from: 282500, to: 100, rate: rate);
    expect(ContraMath.hasGap(gap), isFalse);
  });

  test('same currency: 100 out, 98 in is a fee of 2', () {
    final gap = ContraMath.gap(from: 100, to: 98, rate: 1);
    expect(gap, closeTo(2, 0.0001));
  });

  test('display rate puts the larger-number side first', () {
    final d = ContraMath.displayRate(fromCcy: 'CDF', toCcy: 'USD', rate: rate);
    expect(d.base, 'USD');
    expect(d.quote, 'CDF');
    expect(d.value, closeTo(2825, 0.001));

    final r = ContraMath.displayRate(fromCcy: 'USD', toCcy: 'CDF', rate: 2825);
    expect(r.base, 'USD');
    expect(r.quote, 'CDF');
    expect(r.value, 2825);
  });

  test('actual rate and deviation', () {
    expect(ContraMath.actualRate(from: 282500, to: 95), closeTo(95 / 282500, 1e-12));
    expect(
      ContraMath.deviationPercent(from: 282500, to: 95, rate: rate),
      closeTo(-5, 0.0001),
    );
    expect(
      ContraMath.deviationPercent(from: 282500, to: 100, rate: rate),
      closeTo(0, 0.0001),
    );
  });

  test('a missing or zero rate never divides by zero', () {
    expect(ContraMath.gap(from: 100, to: 50, rate: 0), 0);
    expect(ContraMath.deviationPercent(from: 100, to: 50, rate: 0), 0);
  });
}

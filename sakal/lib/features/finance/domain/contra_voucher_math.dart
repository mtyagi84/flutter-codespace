/// Pure arithmetic for the Contra Voucher's exchange difference, kept out of
/// the screen so the worked examples are unit-testable.
///
/// `rate` is always the FROM→TO system rate ("1 FROM = rate TO"), as stored
/// by the always-multiply convention. The voucher is booked in the FROM
/// currency: the TO line is `to / rate`, and the difference is whatever is
/// left over of the FROM amount.
class ContraMath {
  ContraMath._();

  /// Difference in the FROM currency. Positive = received less than the
  /// system rate implies (loss / fee, debit); negative = received more (gain,
  /// credit).
  static double gap({
    required double from,
    required double to,
    required double rate,
  }) {
    if (rate <= 0) return 0;
    return from - to / rate;
  }

  /// The same difference expressed in the TO currency.
  static double gapInToCurrency(double gapInFrom, double rate) =>
      gapInFrom * rate;

  /// System rate in the orientation people read: the currency that is worth
  /// more goes on the left, so 0.0003539823 USD-per-CDF reads "1 USD = 2,825
  /// CDF" rather than "1 CDF = 0.00035 USD".
  static ({String base, double value, String quote}) displayRate({
    required String fromCcy,
    required String toCcy,
    required double rate,
  }) {
    if (rate <= 0) return (base: fromCcy, value: 0, quote: toCcy);
    return rate >= 1
        ? (base: fromCcy, value: rate, quote: toCcy)
        : (base: toCcy, value: 1 / rate, quote: fromCcy);
  }

  /// The rate implied by what the user actually typed ("1 FROM = x TO").
  static double actualRate({required double from, required double to}) =>
      from <= 0 ? 0 : to / from;

  /// How far the typed amounts sit from the system rate, in percent.
  static double deviationPercent({
    required double from,
    required double to,
    required double rate,
  }) {
    if (rate <= 0 || from <= 0) return 0;
    return (actualRate(from: from, to: to) - rate) / rate * 100;
  }

  /// A difference beyond a cent is a real accounting event.
  static bool hasGap(double gap) => gap.abs() > 0.01;
}

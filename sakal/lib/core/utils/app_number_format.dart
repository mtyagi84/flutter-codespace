import 'package:intl/intl.dart';

/// Shared number-display formatting — two genuinely independent settings,
/// not one (researched against Odoo's res.currency.rounding + separate
/// "Decimal Accuracy" table, and SAP's TCURX):
///
/// 1. Grouping STYLE (company-level, `ric_companies.number_format` via
///    [UserSession.numberFormat]) — cosmetic, applies to every number
///    shown anywhere: INTERNATIONAL (115,356.00) vs INDIAN (1,15,356.00).
/// 2. Decimal PRECISION — two different rules depending on what kind of
///    number is being shown:
///    - [amount] — a calculated total (Gross/Tax/Grand Total, any report
///      subtotal) always rounds to a FIXED 2 decimal places regardless of
///      currency, matching universal accounting practice.
///    - [rate] — a unit price/rate in a SPECIFIC currency uses THAT
///      currency's own `rim_currencies.rate_decimal_places` (a USD unit
///      cost may need 4-5dp when converted from a bulk purchase; CDF only
///      needs 2) — never a single global decimal count.
///
/// Deliberately display-only: this formats already-computed values for
/// READ-ONLY text (Financial Summary, Posted Journal Entries, line
/// Amount columns). It does NOT reformat what a user is actively TYPING
/// into a live Rate/Qty field — commas-while-typing needs a dedicated
/// TextInputFormatter with cursor-position handling, a separate, riskier
/// piece of work not attempted here (see
/// project_redesign_widgets_implementation memory for why).
class AppNumberFormat {
  // Built from an explicit ICU-style pattern rather than
  // NumberFormat.decimalPatternDigits(locale: 'en_IN') — this intl version's
  // compiled locale-symbol tables don't include an 'en_IN' entry, so that
  // constructor would silently fall back to a default (non-Indian) grouping
  // instead of throwing, making the bug invisible until someone actually
  // looked at the rendered number. Spelling out the grouping size in the
  // pattern itself ("#,##,##0.00" = group by 2, final group by 3 — the
  // standard ICU idiom for Indian numbering) works regardless of which
  // locale symbol tables happen to be compiled in; 'en_US' is only used
  // here for its decimal-point/comma separator characters, which every
  // intl build has.
  static NumberFormat _grouped(String numberFormatStyle, int decimalDigits) {
    final decimalPart = decimalDigits > 0 ? '.${'0' * decimalDigits}' : '';
    final pattern = numberFormatStyle == 'INDIAN' ? '#,##,##0$decimalPart' : '#,##0$decimalPart';
    return NumberFormat(pattern, 'en_US');
  }

  static String amount(num value, String numberFormatStyle) =>
      _grouped(numberFormatStyle, 2).format(value);

  static String rate(num value, {required int decimalPlaces, required String numberFormatStyle}) =>
      _grouped(numberFormatStyle, decimalPlaces).format(value);
}

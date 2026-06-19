// Pure functions for finance voucher business logic.
// Extracted so they can be unit-tested without Flutter bindings.

/// DR side for line 1 (Cash/Bank) based on voucher type.
/// CRV/BRV = cash/bank is debited (money comes IN).
/// CPV/BPV = cash/bank is credited (money goes OUT).
String line1Nature(String voucherType) =>
    (voucherType == 'CRV' || voucherType == 'BRV') ? 'DR' : 'CR';

/// Opposite of DR/CR.
String counterNature(String nature) => nature == 'DR' ? 'CR' : 'DR';

/// Whether voucher type uses a Cash account on line 1.
bool isCashVoucher(String voucherType) =>
    voucherType == 'CRV' || voucherType == 'CPV';

/// Whether voucher type uses a Bank account on line 1.
bool isBankVoucher(String voucherType) =>
    voucherType == 'BRV' || voucherType == 'BPV';

/// Sum of amounts on DR lines.
double drTotal(List<({String nature, double amount})> lines) =>
    lines.where((l) => l.nature == 'DR').fold(0.0, (s, l) => s + l.amount);

/// Sum of amounts on CR lines.
double crTotal(List<({String nature, double amount})> lines) =>
    lines.where((l) => l.nature == 'CR').fold(0.0, (s, l) => s + l.amount);

/// Voucher is balanced when |DR − CR| < 0.01.
bool isVoucherBalanced(double dr, double cr) => (dr - cr).abs() < 0.01;

/// Convert transaction amount to base currency.
/// [rate] = units of transCurrency per 1 unit of baseCurrency.
/// If same currency, returns amount unchanged.
double toBaseAmount(double amount, double rate, String transCurrency, String baseCurrency) {
  if (transCurrency == baseCurrency || rate <= 0) return amount;
  return amount / rate;
}

/// Convert transaction amount to local currency.
/// [rate] = units of localCurrency per 1 unit of baseCurrency.
double toLocalAmount(double amount, double baseRate, double localRate,
    String transCurrency, String localCurrency) {
  if (transCurrency == localCurrency) return amount;
  if (baseRate <= 0 || localRate <= 0) return amount;
  // trans → base → local
  final inBase = amount / baseRate;
  return inBase * localRate;
}

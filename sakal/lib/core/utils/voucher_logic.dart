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

/// Convert transaction amount using a stored rate.
/// [baseRate] = fn_get_exchange_rate(trans → base).
/// Always multiply: base_amount = trans_amount × base_rate.
double toBaseAmount(double transAmount, double baseRate) => transAmount * baseRate;

/// Convert transaction amount to local currency using a stored rate.
/// [localRate] = fn_get_exchange_rate(trans → local).
/// Always multiply: local_amount = trans_amount × local_rate.
double toLocalAmount(double transAmount, double localRate) => transAmount * localRate;

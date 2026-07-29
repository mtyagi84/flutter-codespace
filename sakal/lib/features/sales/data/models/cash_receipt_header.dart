/// List-row shape for the Cash Receipt list screen. Mirrors the fields
/// consumed by `cash_receipt_list_screen.dart` — reads either the remote
/// shape (nested `customer`/`location` embeds from PostgREST) or the local
/// cache's own flat map (`CashReceiptLocalDs._headerToMap`).
class CashReceiptHeader {
  final String  receiptNo;
  final String? receiptDate;
  final String? customerCode;
  final String? customerName;
  final String? locationName;
  final double  localAmount;
  final double  baseAmount;
  final String  status;

  const CashReceiptHeader({
    required this.receiptNo,
    required this.receiptDate,
    required this.customerCode,
    required this.customerName,
    required this.locationName,
    required this.localAmount,
    required this.baseAmount,
    required this.status,
  });

  factory CashReceiptHeader.fromJson(Map<String, dynamic> j) {
    final customer = j['customer'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    return CashReceiptHeader(
      receiptNo:    j['receipt_no']   as String? ?? '',
      receiptDate:  j['receipt_date'] as String?,
      customerCode: customer?['account_code'] as String?,
      customerName: customer?['account_name'] as String?,
      locationName: location?['location_name'] as String?,
      localAmount:  (j['local_amount'] as num? ?? 0).toDouble(),
      baseAmount:   (j['base_amount']  as num? ?? 0).toDouble(),
      status:       j['status']       as String? ?? 'DRAFT',
    );
  }
}

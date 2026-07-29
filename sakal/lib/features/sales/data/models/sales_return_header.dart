/// List-row shape for the Sales Return list screen. Mirrors the fields
/// consumed by `sales_return_list_screen.dart` — reads either the remote
/// shape (nested `customer` embed from PostgREST) or the local cache's own
/// flat map (`SalesReturnLocalDs._headerToMap`).
class SalesReturnHeader {
  final String  returnNo;
  final String? returnDate;
  final String? invoiceNo;
  final String? customerCode;
  final String? customerName;
  final double  returnTotal;
  final String  status;

  const SalesReturnHeader({
    required this.returnNo,
    required this.returnDate,
    required this.invoiceNo,
    required this.customerCode,
    required this.customerName,
    required this.returnTotal,
    required this.status,
  });

  factory SalesReturnHeader.fromJson(Map<String, dynamic> j) {
    final customer = j['customer'] as Map<String, dynamic>?;
    return SalesReturnHeader(
      returnNo:     j['return_no']   as String? ?? '',
      returnDate:   j['return_date'] as String?,
      invoiceNo:    j['invoice_no']  as String?,
      customerCode: customer?['account_code'] as String?,
      customerName: customer?['account_name'] as String?,
      returnTotal:  (j['return_total'] as num? ?? 0).toDouble(),
      status:       j['status']      as String? ?? 'DRAFT',
    );
  }
}

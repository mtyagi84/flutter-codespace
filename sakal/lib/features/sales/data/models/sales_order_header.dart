/// List-row shape for the Sales Order list screen. Mirrors the fields
/// consumed by `sales_order_list_screen.dart` — reads either the remote
/// shape (nested `customer`/`currency` embeds from PostgREST) or the local
/// cache's own flat map (`SalesOrderLocalDs._headerToMap`).
class SalesOrderHeader {
  final String  orderNo;
  final String  orderDate;
  final String  orderMode;
  final String? sourceQuotationNo;
  final String  customerName;
  final String  customerPoRef;
  final String  status;
  final double  grandTotal;
  final String  currencyId;

  const SalesOrderHeader({
    required this.orderNo,
    required this.orderDate,
    required this.orderMode,
    required this.sourceQuotationNo,
    required this.customerName,
    required this.customerPoRef,
    required this.status,
    required this.grandTotal,
    required this.currencyId,
  });

  factory SalesOrderHeader.fromJson(Map<String, dynamic> j) {
    final customer = j['customer'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    return SalesOrderHeader(
      orderNo:           j['order_no']    as String? ?? '',
      orderDate:         j['order_date']  as String? ?? '',
      orderMode:         j['order_mode']  as String? ?? 'DIRECT',
      sourceQuotationNo: j['source_quotation_no'] as String?,
      customerName:      customer?['account_name'] as String? ?? '',
      customerPoRef:     j['customer_po_ref'] as String? ?? '',
      status:            j['status']      as String? ?? 'DRAFT',
      grandTotal:        (j['grand_total'] as num? ?? 0).toDouble(),
      currencyId:        currency?['currency_id'] as String? ?? '',
    );
  }
}

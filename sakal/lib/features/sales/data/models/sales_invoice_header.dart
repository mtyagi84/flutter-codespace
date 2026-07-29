/// List-row shape for the Sales Invoice list screen. Mirrors the fields
/// consumed by `sales_invoice_list_screen.dart` — reads either the remote
/// shape (nested `customer`/`currency` embeds from PostgREST) or the local
/// cache's own flat map (`SalesInvoiceLocalDs._headerToMap`). The entry
/// screen's own full-document load (`getHeader`) is untouched — deliberately
/// out of scope, since it feeds the complex editable entry screen.
class SalesInvoiceHeader {
  final String  invoiceNo;
  final String  invoiceDate;
  final String  saleType;
  final String  customerName;
  final String  partyName;
  final String  status;
  final double  grandTotal;
  final String  currencyId;
  final String  stockDispatchMode;

  const SalesInvoiceHeader({
    required this.invoiceNo,
    required this.invoiceDate,
    required this.saleType,
    required this.customerName,
    required this.partyName,
    required this.status,
    required this.grandTotal,
    required this.currencyId,
    required this.stockDispatchMode,
  });

  factory SalesInvoiceHeader.fromJson(Map<String, dynamic> j) {
    final customer = j['customer'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    return SalesInvoiceHeader(
      invoiceNo:         j['invoice_no']   as String? ?? '',
      invoiceDate:       j['invoice_date'] as String? ?? '',
      saleType:          j['sale_type']    as String? ?? 'CASH',
      customerName:      customer?['account_name'] as String? ?? '',
      partyName:         j['party_name']   as String? ?? '',
      status:            j['status']       as String? ?? 'DRAFT',
      grandTotal:        (j['grand_total'] as num? ?? 0).toDouble(),
      currencyId:        currency?['currency_id'] as String? ?? '',
      stockDispatchMode: j['stock_dispatch_mode'] as String? ?? 'IMMEDIATE',
    );
  }
}

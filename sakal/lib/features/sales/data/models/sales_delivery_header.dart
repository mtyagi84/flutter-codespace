/// List-row shape for the Sales Delivery list screen. Mirrors the fields
/// consumed by `sales_delivery_list_screen.dart` — reads either the remote
/// shape (nested `customer`/`location` embeds from PostgREST) or the local
/// cache's own flat map (`SalesDeliveryLocalDs._headerToMap`).
class SalesDeliveryHeader {
  final String  deliveryNo;
  final String? deliveryDate;
  final String? invoiceNo;
  final String? customerCode;
  final String? customerName;
  final String? locationName;
  final String  status;

  const SalesDeliveryHeader({
    required this.deliveryNo,
    required this.deliveryDate,
    required this.invoiceNo,
    required this.customerCode,
    required this.customerName,
    required this.locationName,
    required this.status,
  });

  factory SalesDeliveryHeader.fromJson(Map<String, dynamic> j) {
    final customer = j['customer'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    return SalesDeliveryHeader(
      deliveryNo:   j['delivery_no']   as String? ?? '',
      deliveryDate: j['delivery_date'] as String?,
      invoiceNo:    j['invoice_no']    as String?,
      customerCode: customer?['account_code'] as String?,
      customerName: customer?['account_name'] as String?,
      locationName: location?['location_name'] as String?,
      status:       j['status']        as String? ?? 'DRAFT',
    );
  }
}

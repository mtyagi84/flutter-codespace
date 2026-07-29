/// List-row shape for the Sales Quotation list screen. Mirrors the fields
/// consumed by `sales_quotation_list_screen.dart` — reads either the remote
/// shape (nested `customer`/`currency` embeds from PostgREST) or the local
/// cache's own flat map (`SalesQuotationLocalDs._headerToMap`).
class SalesQuotationHeader {
  final String  quotationNo;
  final String  quotationDate;
  final String? validUntilDate;
  final String  customerType;
  final String  partyName;
  final String  status;
  final double  grandTotal;
  final String  currencyId;

  const SalesQuotationHeader({
    required this.quotationNo,
    required this.quotationDate,
    required this.validUntilDate,
    required this.customerType,
    required this.partyName,
    required this.status,
    required this.grandTotal,
    required this.currencyId,
  });

  factory SalesQuotationHeader.fromJson(Map<String, dynamic> j) {
    final currency = j['currency'] as Map<String, dynamic>?;
    return SalesQuotationHeader(
      quotationNo:    j['quotation_no']     as String? ?? '',
      quotationDate:  j['quotation_date']   as String? ?? '',
      validUntilDate: j['valid_until_date'] as String?,
      customerType:   j['customer_type']    as String? ?? 'CUSTOMER',
      partyName:      j['party_name']       as String? ?? '',
      status:         j['status']           as String? ?? 'DRAFT',
      grandTotal:     (j['grand_total'] as num? ?? 0).toDouble(),
      currencyId:     currency?['currency_id'] as String? ?? '',
    );
  }
}

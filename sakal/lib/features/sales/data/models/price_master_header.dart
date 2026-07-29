/// List-row shape for the Sales Price Master list screen. Mirrors the
/// fields consumed by `price_master_list_screen.dart` — reads either the
/// remote shape (nested `customer`/`location`/`currency` embeds from
/// PostgREST, plus the `line_count` the datasource derives from a
/// `rid_price_master_lines(count)` aggregate embed) or the local cache's
/// own flat map (`PriceMasterLocalDs._headerToMap`).
class PriceMasterHeader {
  final String  entryNo;
  final String? entryDate;
  final String? locationName;
  final String  priceType;
  final String? customerCode;
  final String? customerName;
  final String? effectiveDate;
  final String? currencyId;
  final String  status;
  final int     lineCount;

  const PriceMasterHeader({
    required this.entryNo,
    required this.entryDate,
    required this.locationName,
    required this.priceType,
    required this.customerCode,
    required this.customerName,
    required this.effectiveDate,
    required this.currencyId,
    required this.status,
    required this.lineCount,
  });

  factory PriceMasterHeader.fromJson(Map<String, dynamic> j) {
    final customer = j['customer'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    return PriceMasterHeader(
      entryNo:       j['entry_no']       as String? ?? '',
      entryDate:     j['entry_date']     as String?,
      locationName:  location?['location_name'] as String?,
      priceType:     j['price_type']     as String? ?? 'GENERIC',
      customerCode:  customer?['account_code'] as String?,
      customerName:  customer?['account_name'] as String?,
      effectiveDate: j['effective_date'] as String?,
      currencyId:    currency?['currency_id'] as String?,
      status:        j['status']         as String? ?? 'DRAFT',
      lineCount:     (j['line_count'] as num? ?? 0).toInt(),
    );
  }
}

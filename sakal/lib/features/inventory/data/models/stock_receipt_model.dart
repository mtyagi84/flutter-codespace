class StockReceiptHeader {
  final String  receiptNo;
  final String  receiptDate;
  final String  fromLocationId;
  final String  fromLocationName;
  final String  toLocationId;
  final String  toLocationName;
  final String? sourceTransferNo;
  final String  status;

  const StockReceiptHeader({
    required this.receiptNo,
    required this.receiptDate,
    required this.fromLocationId,
    required this.fromLocationName,
    required this.toLocationId,
    required this.toLocationName,
    required this.sourceTransferNo,
    required this.status,
  });

  factory StockReceiptHeader.fromJson(Map<String, dynamic> j) {
    final from = j['from_location'] as Map<String, dynamic>?;
    final to   = j['to_location']   as Map<String, dynamic>?;
    return StockReceiptHeader(
      receiptNo:        j['receipt_no']         as String? ?? '',
      receiptDate:      j['receipt_date']       as String? ?? '',
      fromLocationId:   j['from_location_id']   as String? ?? '',
      fromLocationName: from?['location_name']  as String? ?? '',
      toLocationId:     j['to_location_id']     as String? ?? '',
      toLocationName:   to?['location_name']    as String? ?? '',
      sourceTransferNo: j['source_transfer_no'] as String?,
      status:           j['status']             as String? ?? 'DRAFT',
    );
  }
}

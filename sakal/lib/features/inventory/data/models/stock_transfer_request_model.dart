class StockTransferRequestHeader {
  final String requestNo;
  final String requestDate;
  final String fromLocationId;
  final String fromLocationName;
  final String toLocationId;
  final String toLocationName;
  final String status;

  const StockTransferRequestHeader({
    required this.requestNo,
    required this.requestDate,
    required this.fromLocationId,
    required this.fromLocationName,
    required this.toLocationId,
    required this.toLocationName,
    required this.status,
  });

  factory StockTransferRequestHeader.fromJson(Map<String, dynamic> j) {
    final from = j['from_location'] as Map<String, dynamic>?;
    final to   = j['to_location']   as Map<String, dynamic>?;
    return StockTransferRequestHeader(
      requestNo:        j['request_no']       as String? ?? '',
      requestDate:      j['request_date']     as String? ?? '',
      fromLocationId:   j['from_location_id'] as String? ?? '',
      fromLocationName: from?['location_name'] as String? ?? '',
      toLocationId:     j['to_location_id']   as String? ?? '',
      toLocationName:   to?['location_name']  as String? ?? '',
      status:           j['status']           as String? ?? 'DRAFT',
    );
  }
}

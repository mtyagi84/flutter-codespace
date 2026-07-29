class StockTransferHeader {
  final String  transferNo;
  final String  transferDate;
  final String  fromLocationId;
  final String  fromLocationName;
  final String  toLocationId;
  final String  toLocationName;
  final bool    againstRequest;
  final String? postingMode;
  final String  status;

  const StockTransferHeader({
    required this.transferNo,
    required this.transferDate,
    required this.fromLocationId,
    required this.fromLocationName,
    required this.toLocationId,
    required this.toLocationName,
    required this.againstRequest,
    required this.postingMode,
    required this.status,
  });

  factory StockTransferHeader.fromJson(Map<String, dynamic> j) {
    final from = j['from_location'] as Map<String, dynamic>?;
    final to   = j['to_location']   as Map<String, dynamic>?;
    return StockTransferHeader(
      transferNo:       j['transfer_no']      as String? ?? '',
      transferDate:     j['transfer_date']    as String? ?? '',
      fromLocationId:   j['from_location_id'] as String? ?? '',
      fromLocationName: from?['location_name'] as String? ?? '',
      toLocationId:     j['to_location_id']   as String? ?? '',
      toLocationName:   to?['location_name']  as String? ?? '',
      againstRequest:   j['against_request']  as bool?   ?? false,
      postingMode:      j['posting_mode']     as String?,
      status:           j['status']           as String? ?? 'DRAFT',
    );
  }

  /// Mirrors the list screen's original inline fallback:
  /// `posting_mode` if present, else derived from `against_request`.
  String get modeLabel => postingMode ?? (againstRequest ? 'Against Request' : 'Direct');
}

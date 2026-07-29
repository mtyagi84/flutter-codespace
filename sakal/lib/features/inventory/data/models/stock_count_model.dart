class StockCountHeader {
  final String countNo;
  final String countDate;
  final String locationId;
  final String locationName;
  final String status;

  const StockCountHeader({
    required this.countNo,
    required this.countDate,
    required this.locationId,
    required this.locationName,
    required this.status,
  });

  factory StockCountHeader.fromJson(Map<String, dynamic> j) {
    final location = j['location'] as Map<String, dynamic>?;
    return StockCountHeader(
      countNo:      j['count_no']    as String? ?? '',
      countDate:    j['count_date']  as String? ?? '',
      locationId:   j['location_id'] as String? ?? '',
      locationName: location?['location_name'] as String? ?? '',
      status:       j['status']      as String? ?? 'DRAFT',
    );
  }
}

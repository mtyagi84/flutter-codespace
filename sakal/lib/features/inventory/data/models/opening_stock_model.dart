class OpeningStockHeader {
  final String openingNo;
  final String openingDate;
  final String locationId;
  final String locationName;
  final String status;

  const OpeningStockHeader({
    required this.openingNo,
    required this.openingDate,
    required this.locationId,
    required this.locationName,
    required this.status,
  });

  factory OpeningStockHeader.fromJson(Map<String, dynamic> j) {
    final location = j['location'] as Map<String, dynamic>?;
    return OpeningStockHeader(
      openingNo:    j['opening_no']   as String? ?? '',
      openingDate:  j['opening_date'] as String? ?? '',
      locationId:   j['location_id'] as String? ?? '',
      locationName: location?['location_name'] as String? ?? '',
      status:       j['status']       as String? ?? 'DRAFT',
    );
  }
}

class StockCountReviewHeader {
  final String  reviewNo;
  final String  reviewDate;
  final String  locationId;
  final String  locationName;
  final String? postedAdjustmentNo;
  final String  status;

  const StockCountReviewHeader({
    required this.reviewNo,
    required this.reviewDate,
    required this.locationId,
    required this.locationName,
    required this.postedAdjustmentNo,
    required this.status,
  });

  factory StockCountReviewHeader.fromJson(Map<String, dynamic> j) {
    final location = j['location'] as Map<String, dynamic>?;
    return StockCountReviewHeader(
      reviewNo:           j['review_no']            as String? ?? '',
      reviewDate:         j['review_date']           as String? ?? '',
      locationId:         j['location_id']           as String? ?? '',
      locationName:       location?['location_name'] as String? ?? '',
      postedAdjustmentNo: j['posted_adjustment_no']  as String?,
      status:             j['status']                as String? ?? 'DRAFT',
    );
  }
}

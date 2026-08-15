class StockAdjustmentHeader {
  final String adjustmentNo;
  final String adjustmentDate;
  final String locationId;
  final String locationName;
  final String reasonId;
  final String reasonLabel;
  final String status;
  final String? createdBy;
  final String? approvedBy;

  const StockAdjustmentHeader({
    required this.adjustmentNo,
    required this.adjustmentDate,
    required this.locationId,
    required this.locationName,
    required this.reasonId,
    required this.reasonLabel,
    required this.status,
    this.createdBy,
    this.approvedBy,
  });

  factory StockAdjustmentHeader.fromJson(Map<String, dynamic> j) {
    final location = j['location'] as Map<String, dynamic>?;
    final reason   = j['reason']   as Map<String, dynamic>?;
    return StockAdjustmentHeader(
      adjustmentNo:   j['adjustment_no']   as String? ?? '',
      adjustmentDate: j['adjustment_date'] as String? ?? '',
      locationId:     j['location_id']     as String? ?? '',
      locationName:   location?['location_name'] as String? ?? '',
      reasonId:       j['reason_id']       as String? ?? '',
      reasonLabel:    reason?['description'] as String? ?? '',
      status:         j['status']          as String? ?? 'DRAFT',
      createdBy:      j['created_by']  as String?,
      approvedBy:     j['approved_by'] as String?,
    );
  }
}

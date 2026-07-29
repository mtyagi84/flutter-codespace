class MaterialRequisitionHeader {
  final String requisitionNo;
  final String requisitionDate;
  final String requestedBy;
  final String reason;
  final String locationId;
  final String locationName;
  final String status;

  const MaterialRequisitionHeader({
    required this.requisitionNo,
    required this.requisitionDate,
    required this.requestedBy,
    required this.reason,
    required this.locationId,
    required this.locationName,
    required this.status,
  });

  factory MaterialRequisitionHeader.fromJson(Map<String, dynamic> j) {
    final location = j['location'] as Map<String, dynamic>?;
    return MaterialRequisitionHeader(
      requisitionNo:   j['requisition_no']   as String? ?? '',
      requisitionDate: j['requisition_date'] as String? ?? '',
      requestedBy:     j['requested_by']     as String? ?? '',
      reason:          j['reason']           as String? ?? '',
      locationId:      j['location_id']      as String? ?? '',
      locationName:    location?['location_name'] as String? ?? '',
      status:          j['status']           as String? ?? 'DRAFT',
    );
  }
}

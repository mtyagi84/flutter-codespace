class MaterialIssueHeader {
  final String issueNo;
  final String issueDate;
  final String locationId;
  final String locationName;
  final String status;
  final String? createdBy;
  final String? approvedBy;

  const MaterialIssueHeader({
    required this.issueNo,
    required this.issueDate,
    required this.locationId,
    required this.locationName,
    required this.status,
    this.createdBy,
    this.approvedBy,
  });

  factory MaterialIssueHeader.fromJson(Map<String, dynamic> j) {
    final location = j['location'] as Map<String, dynamic>?;
    return MaterialIssueHeader(
      issueNo:      j['issue_no']     as String? ?? '',
      issueDate:    j['issue_date']   as String? ?? '',
      locationId:   j['location_id'] as String? ?? '',
      locationName: location?['location_name'] as String? ?? '',
      status:       j['status']       as String? ?? 'DRAFT',
      createdBy:    j['created_by']  as String?,
      approvedBy:   j['approved_by'] as String?,
    );
  }
}

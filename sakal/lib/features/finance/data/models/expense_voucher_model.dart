class ExpenseVoucherHeader {
  final String transNo;
  final String transDate;
  final String supplierId;
  final String supplierCode;
  final String supplierName;
  final String billNo;
  final String billDate;
  final String status;
  final String remarks;

  const ExpenseVoucherHeader({
    required this.transNo,
    required this.transDate,
    required this.supplierId,
    required this.supplierCode,
    required this.supplierName,
    required this.billNo,
    required this.billDate,
    required this.status,
    required this.remarks,
  });

  // Reads either the remote shape (nested `supplier: {account_code,
  // account_name}` embed from PostgREST) or the local cache's own flat
  // supplier_code/supplier_name columns — whichever is present.
  factory ExpenseVoucherHeader.fromJson(Map<String, dynamic> j) {
    final supplier = j['supplier'] as Map<String, dynamic>?;
    return ExpenseVoucherHeader(
      transNo:      j['trans_no']      as String? ?? '',
      transDate:    j['trans_date']    as String? ?? '',
      supplierId:   j['supplier_id']   as String? ?? '',
      supplierCode: supplier?['account_code'] as String? ?? j['supplier_code'] as String? ?? '',
      supplierName: supplier?['account_name'] as String? ?? j['supplier_name'] as String? ?? '',
      billNo:       j['bill_no']       as String? ?? '',
      billDate:     j['bill_date']     as String? ?? '',
      status:       j['status']        as String? ?? 'DRAFT',
      remarks:      j['remarks']       as String? ?? '',
    );
  }
}

/// rih_purchase_return_headers. See backend/migrations/061_purchase_return.sql.
class PurchaseReturnModel {
  final String  id;
  final String  clientId;
  final String  companyId;
  final String  locationId;
  final String? locationName;
  final String  returnNo;
  final String  returnDate;
  final String  supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String? returnCurrencyId;
  final String? returnCurrencyCode;
  final double  rateToBase;
  final double  rateToLocal;
  final double  taxableAmount;
  final double  taxAmount;
  final double  chargesAmount;
  final double  returnTotal;
  final String? reason;
  final String? remarks;
  final String  status; // DRAFT / APPROVED
  final String? approvedBy;
  final String? approvedAt;
  final String? postedVoucherNo;
  final String? postedVoucherDate;

  const PurchaseReturnModel({
    required this.id,
    required this.clientId,
    required this.companyId,
    required this.locationId,
    this.locationName,
    required this.returnNo,
    required this.returnDate,
    required this.supplierId,
    this.supplierCode,
    this.supplierName,
    this.returnCurrencyId,
    this.returnCurrencyCode,
    this.rateToBase = 1,
    this.rateToLocal = 1,
    this.taxableAmount = 0,
    this.taxAmount = 0,
    this.chargesAmount = 0,
    this.returnTotal = 0,
    this.reason,
    this.remarks,
    this.status = 'DRAFT',
    this.approvedBy,
    this.approvedAt,
    this.postedVoucherNo,
    this.postedVoucherDate,
  });

  factory PurchaseReturnModel.fromJson(Map<String, dynamic> j) {
    final supplier = j['supplier'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    return PurchaseReturnModel(
      id:                  j['id'] as String,
      clientId:            j['client_id'] as String,
      companyId:           j['company_id'] as String,
      locationId:          j['location_id'] as String,
      locationName:        location?['location_name'] as String?,
      returnNo:            j['return_no'] as String,
      returnDate:          j['return_date'] as String,
      supplierId:          j['supplier_id'] as String,
      supplierCode:        supplier?['account_code'] as String?,
      supplierName:        supplier?['account_name'] as String?,
      returnCurrencyId:    j['return_currency_id'] as String?,
      returnCurrencyCode:  currency?['currency_id'] as String?,
      rateToBase:          (j['rate_to_base'] as num? ?? 1).toDouble(),
      rateToLocal:         (j['rate_to_local'] as num? ?? 1).toDouble(),
      taxableAmount:       (j['taxable_amount'] as num? ?? 0).toDouble(),
      taxAmount:           (j['tax_amount'] as num? ?? 0).toDouble(),
      chargesAmount:       (j['charges_amount'] as num? ?? 0).toDouble(),
      returnTotal:         (j['return_total'] as num? ?? 0).toDouble(),
      reason:              j['reason'] as String?,
      remarks:             j['remarks'] as String?,
      status:              j['status'] as String? ?? 'DRAFT',
      approvedBy:          j['approved_by'] as String?,
      approvedAt:          j['approved_at'] as String?,
      postedVoucherNo:     j['posted_voucher_no'] as String?,
      postedVoucherDate:   j['posted_voucher_date'] as String?,
    );
  }
}

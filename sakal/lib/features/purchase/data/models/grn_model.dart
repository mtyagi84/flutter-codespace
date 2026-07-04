/// rih_grn_headers. See backend/migrations/038_grn.sql.
class GrnModel {
  final String  id;
  final String  clientId;
  final String  companyId;
  final String  locationId;
  final String? locationName;
  final String  grnNo;
  final String  grnDate;
  final String  supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String  receiptMode; // AGAINST_PO / DIRECT
  final String? supplierDeliveryNo;
  final String? supplierDeliveryDate;
  final String? grnCurrencyId;
  final String? grnCurrencyCode;
  final double  rateToBase;
  final double  rateToLocal;
  final double  grossAmount;
  final double  discountAmount;
  final double  chargesAmount;
  final double  itemTaxAmount;
  final double  chargeTaxAmount;
  final double  grandTotal;
  final String? billTo;
  final String? shipTo;
  final String? remarks;
  final String  status; // DRAFT / APPROVED
  final String? approvedBy;
  final String? approvedAt;
  final String? postedVoucherNo;
  final String? postedVoucherDate;

  const GrnModel({
    required this.id,
    required this.clientId,
    required this.companyId,
    required this.locationId,
    this.locationName,
    required this.grnNo,
    required this.grnDate,
    required this.supplierId,
    this.supplierCode,
    this.supplierName,
    this.receiptMode = 'DIRECT',
    this.supplierDeliveryNo,
    this.supplierDeliveryDate,
    this.grnCurrencyId,
    this.grnCurrencyCode,
    this.rateToBase = 1,
    this.rateToLocal = 1,
    this.grossAmount = 0,
    this.discountAmount = 0,
    this.chargesAmount = 0,
    this.itemTaxAmount = 0,
    this.chargeTaxAmount = 0,
    this.grandTotal = 0,
    this.billTo,
    this.shipTo,
    this.remarks,
    this.status = 'DRAFT',
    this.approvedBy,
    this.approvedAt,
    this.postedVoucherNo,
    this.postedVoucherDate,
  });

  factory GrnModel.fromJson(Map<String, dynamic> j) {
    final supplier = j['supplier'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    return GrnModel(
      id:                   j['id'] as String,
      clientId:             j['client_id'] as String,
      companyId:            j['company_id'] as String,
      locationId:           j['location_id'] as String,
      locationName:         location?['location_name'] as String?,
      grnNo:                j['grn_no'] as String,
      grnDate:              j['grn_date'] as String,
      supplierId:           j['supplier_id'] as String,
      supplierCode:         supplier?['account_code'] as String?,
      supplierName:         supplier?['account_name'] as String?,
      receiptMode:          j['receipt_mode'] as String? ?? 'DIRECT',
      supplierDeliveryNo:   j['supplier_delivery_no'] as String?,
      supplierDeliveryDate: j['supplier_delivery_date'] as String?,
      grnCurrencyId:        j['grn_currency_id'] as String?,
      grnCurrencyCode:      currency?['currency_id'] as String?,
      rateToBase:           (j['rate_to_base'] as num? ?? 1).toDouble(),
      rateToLocal:          (j['rate_to_local'] as num? ?? 1).toDouble(),
      grossAmount:          (j['gross_amount'] as num? ?? 0).toDouble(),
      discountAmount:       (j['discount_amount'] as num? ?? 0).toDouble(),
      chargesAmount:        (j['charges_amount'] as num? ?? 0).toDouble(),
      itemTaxAmount:        (j['item_tax_amount'] as num? ?? 0).toDouble(),
      chargeTaxAmount:      (j['charge_tax_amount'] as num? ?? 0).toDouble(),
      grandTotal:           (j['grand_total'] as num? ?? 0).toDouble(),
      billTo:               j['bill_to'] as String?,
      shipTo:               j['ship_to'] as String?,
      remarks:              j['remarks'] as String?,
      status:               j['status'] as String? ?? 'DRAFT',
      approvedBy:           j['approved_by'] as String?,
      approvedAt:           j['approved_at'] as String?,
      postedVoucherNo:      j['posted_voucher_no'] as String?,
      postedVoucherDate:    j['posted_voucher_date'] as String?,
    );
  }
}

/// rih_purchase_orders header. See backend/migrations/031_purchase_orders.sql.
class PurchaseOrderModel {
  final String  id;
  final String  clientId;
  final String  companyId;
  final String  locationId;
  final String? locationName;
  final String  orderNo;
  final String  orderDate;
  final String  poType; // LOCAL / IMPORT
  final String  supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String? supplierRefNo;
  final String? supplierRefDate;
  final String? indentNo;
  final String? indentDate;
  final String? rfqNo;
  final String? rfqDate;
  final String? quotationNo;
  final String? quotationDate;
  final String  poCurrencyId;
  final String? poCurrencyCode;
  final double  rateToBase;
  final double  rateToLocal;
  final double  grossAmount;
  final double  discountAmount;
  final double  chargesAmount;
  final double  itemTaxAmount;
  final double  chargeTaxAmount;
  final double  grandTotal;
  final String? buyerId;
  final String? buyerName;
  final String  status; // DRAFT / APPROVED / PARTIALLY_RECEIVED / CLOSED / CANCELLED
  final String? approvedBy;
  final String? approvedAt;
  final String? orderSubject;
  final String? billTo;
  final String? shipTo;
  final String? remarks;

  const PurchaseOrderModel({
    required this.id,
    required this.clientId,
    required this.companyId,
    required this.locationId,
    this.locationName,
    required this.orderNo,
    required this.orderDate,
    required this.poType,
    required this.supplierId,
    this.supplierCode,
    this.supplierName,
    this.supplierRefNo,
    this.supplierRefDate,
    this.indentNo,
    this.indentDate,
    this.rfqNo,
    this.rfqDate,
    this.quotationNo,
    this.quotationDate,
    required this.poCurrencyId,
    this.poCurrencyCode,
    this.rateToBase = 1,
    this.rateToLocal = 1,
    this.grossAmount = 0,
    this.discountAmount = 0,
    this.chargesAmount = 0,
    this.itemTaxAmount = 0,
    this.chargeTaxAmount = 0,
    this.grandTotal = 0,
    this.buyerId,
    this.buyerName,
    this.status = 'DRAFT',
    this.approvedBy,
    this.approvedAt,
    this.orderSubject,
    this.billTo,
    this.shipTo,
    this.remarks,
  });

  factory PurchaseOrderModel.fromJson(Map<String, dynamic> j) {
    final supplier = j['supplier'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    final buyer    = j['buyer'] as Map<String, dynamic>?;
    return PurchaseOrderModel(
      id:              j['id'] as String,
      clientId:        j['client_id'] as String,
      companyId:       j['company_id'] as String,
      locationId:      j['location_id'] as String,
      locationName:    location?['location_name'] as String?,
      orderNo:         j['order_no'] as String,
      orderDate:       j['order_date'] as String,
      poType:          j['po_type'] as String? ?? 'LOCAL',
      supplierId:      j['supplier_id'] as String,
      supplierCode:    supplier?['account_code'] as String?,
      supplierName:    supplier?['account_name'] as String?,
      supplierRefNo:   j['supplier_ref_no'] as String?,
      supplierRefDate: j['supplier_ref_date'] as String?,
      indentNo:        j['indent_no'] as String?,
      indentDate:      j['indent_date'] as String?,
      rfqNo:           j['rfq_no'] as String?,
      rfqDate:         j['rfq_date'] as String?,
      quotationNo:     j['quotation_no'] as String?,
      quotationDate:   j['quotation_date'] as String?,
      poCurrencyId:    j['po_currency_id'] as String,
      poCurrencyCode:  currency?['currency_id'] as String?,
      rateToBase:      (j['rate_to_base'] as num? ?? 1).toDouble(),
      rateToLocal:     (j['rate_to_local'] as num? ?? 1).toDouble(),
      grossAmount:     (j['gross_amount'] as num? ?? 0).toDouble(),
      discountAmount:  (j['discount_amount'] as num? ?? 0).toDouble(),
      chargesAmount:   (j['charges_amount'] as num? ?? 0).toDouble(),
      itemTaxAmount:   (j['item_tax_amount'] as num? ?? 0).toDouble(),
      chargeTaxAmount: (j['charge_tax_amount'] as num? ?? 0).toDouble(),
      grandTotal:      (j['grand_total'] as num? ?? 0).toDouble(),
      buyerId:         j['buyer_id'] as String?,
      buyerName:       buyer?['full_name'] as String?,
      status:          j['status'] as String? ?? 'DRAFT',
      approvedBy:      j['approved_by'] as String?,
      approvedAt:      j['approved_at'] as String?,
      orderSubject:    j['order_subject'] as String?,
      billTo:          j['bill_to'] as String?,
      shipTo:          j['ship_to'] as String?,
      remarks:         j['remarks'] as String?,
    );
  }
}

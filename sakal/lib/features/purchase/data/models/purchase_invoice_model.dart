/// rih_purchase_invoices. See backend/migrations/054_purchase_invoice.sql.
class PurchaseInvoiceModel {
  final String  id;
  final String  clientId;
  final String  companyId;
  final String  locationId;
  final String? locationName;
  final String  invoiceNo;
  final String  invoiceDate;
  final String  supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String  supplierInvoiceNo;
  final String  supplierInvoiceDate;
  final String? invoiceCurrencyId;
  final String? invoiceCurrencyCode;
  final double  rateToBase;
  final double  rateToLocal;
  final double  taxableAmount;
  final double  taxAmount;
  final double  invoiceTotal;
  final double  exchangeDiffBase;
  final String? remarks;
  final String  status; // DRAFT / APPROVED
  final String? approvedBy;
  final String? approvedAt;
  final String? postedVoucherNo;
  final String? postedVoucherDate;

  const PurchaseInvoiceModel({
    required this.id,
    required this.clientId,
    required this.companyId,
    required this.locationId,
    this.locationName,
    required this.invoiceNo,
    required this.invoiceDate,
    required this.supplierId,
    this.supplierCode,
    this.supplierName,
    required this.supplierInvoiceNo,
    required this.supplierInvoiceDate,
    this.invoiceCurrencyId,
    this.invoiceCurrencyCode,
    this.rateToBase = 1,
    this.rateToLocal = 1,
    this.taxableAmount = 0,
    this.taxAmount = 0,
    this.invoiceTotal = 0,
    this.exchangeDiffBase = 0,
    this.remarks,
    this.status = 'DRAFT',
    this.approvedBy,
    this.approvedAt,
    this.postedVoucherNo,
    this.postedVoucherDate,
  });

  factory PurchaseInvoiceModel.fromJson(Map<String, dynamic> j) {
    final supplier = j['supplier'] as Map<String, dynamic>?;
    final location = j['location'] as Map<String, dynamic>?;
    final currency = j['currency'] as Map<String, dynamic>?;
    return PurchaseInvoiceModel(
      id:                  j['id'] as String,
      clientId:            j['client_id'] as String,
      companyId:           j['company_id'] as String,
      locationId:          j['location_id'] as String,
      locationName:        location?['location_name'] as String?,
      invoiceNo:           j['invoice_no'] as String,
      invoiceDate:         j['invoice_date'] as String,
      supplierId:          j['supplier_id'] as String,
      supplierCode:        supplier?['account_code'] as String?,
      supplierName:        supplier?['account_name'] as String?,
      supplierInvoiceNo:   j['supplier_invoice_no'] as String,
      supplierInvoiceDate: j['supplier_invoice_date'] as String,
      invoiceCurrencyId:   j['invoice_currency_id'] as String?,
      invoiceCurrencyCode: currency?['currency_id'] as String?,
      rateToBase:          (j['rate_to_base'] as num? ?? 1).toDouble(),
      rateToLocal:         (j['rate_to_local'] as num? ?? 1).toDouble(),
      taxableAmount:       (j['taxable_amount'] as num? ?? 0).toDouble(),
      taxAmount:           (j['tax_amount'] as num? ?? 0).toDouble(),
      invoiceTotal:        (j['invoice_total'] as num? ?? 0).toDouble(),
      exchangeDiffBase:    (j['exchange_diff_base'] as num? ?? 0).toDouble(),
      remarks:             j['remarks'] as String?,
      status:              j['status'] as String? ?? 'DRAFT',
      approvedBy:          j['approved_by'] as String?,
      approvedAt:          j['approved_at'] as String?,
      postedVoucherNo:     j['posted_voucher_no'] as String?,
      postedVoucherDate:   j['posted_voucher_date'] as String?,
    );
  }
}

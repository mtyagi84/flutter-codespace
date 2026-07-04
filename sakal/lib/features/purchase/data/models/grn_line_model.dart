/// rid_transaction_line_batches — document-type-generic, but every field GRN
/// needs is here. See backend/migrations/038_grn.sql.
class GrnBatchModel {
  final String  batchNo;
  final String? expiryDate;
  final double  qtyPack;
  final double  qtyLoose;
  final double  baseQty;

  const GrnBatchModel({
    required this.batchNo,
    this.expiryDate,
    this.qtyPack = 0,
    this.qtyLoose = 0,
    this.baseQty = 0,
  });

  factory GrnBatchModel.fromJson(Map<String, dynamic> j) => GrnBatchModel(
    batchNo:    j['batch_no'] as String,
    expiryDate: j['expiry_date'] as String?,
    qtyPack:    (j['qty_pack'] as num? ?? 0).toDouble(),
    qtyLoose:   (j['qty_loose'] as num? ?? 0).toDouble(),
    baseQty:    (j['base_qty'] as num? ?? 0).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'batch_no': batchNo,
    'expiry_date': expiryDate ?? '',
    'qty_pack': qtyPack,
    'qty_loose': qtyLoose,
    'base_qty': baseQty,
  };
}

/// rid_transaction_line_serials — one row per physical unit.
class GrnSerialModel {
  final String serialNo;

  const GrnSerialModel({required this.serialNo});

  factory GrnSerialModel.fromJson(Map<String, dynamic> j) =>
      GrnSerialModel(serialNo: j['serial_no'] as String);

  Map<String, dynamic> toJson() => {'serial_no': serialNo};
}

/// rid_grn_lines. source_po_* is null for Direct-mode lines.
class GrnLineModel {
  final String  id;
  final int     serialNo;
  final String  productId;
  final String? productCode;
  final String? productName;
  final String? sourcePoOrderNo;
  final String? sourcePoOrderDate;
  final int?    sourcePoLineSerial;
  final String? itemDescription;
  final String  uomId;
  final String? uomLabel;
  final double  uomConversionFactor;
  final double  qtyPack;
  final double  qtyLoose;
  final double  baseQty;
  final double  rate;
  final double  grossAmount;
  final double  discountPercent;
  final double  discountAmount;
  final String? taxGroupId;
  final String? taxGroupName;
  final double  taxAmount;
  final double  finalAmount;
  final double  baseAmount;
  final double  localAmount;
  final double  chargeAmount;
  final double  landedAmount;
  final String? departmentId;
  final String? consumptionAreaId;
  final List<GrnBatchModel>  batches;
  final List<GrnSerialModel> serials;

  const GrnLineModel({
    required this.id,
    required this.serialNo,
    required this.productId,
    this.productCode,
    this.productName,
    this.sourcePoOrderNo,
    this.sourcePoOrderDate,
    this.sourcePoLineSerial,
    this.itemDescription,
    required this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    this.qtyPack = 0,
    this.qtyLoose = 0,
    this.baseQty = 0,
    this.rate = 0,
    this.grossAmount = 0,
    this.discountPercent = 0,
    this.discountAmount = 0,
    this.taxGroupId,
    this.taxGroupName,
    this.taxAmount = 0,
    this.finalAmount = 0,
    this.baseAmount = 0,
    this.localAmount = 0,
    this.chargeAmount = 0,
    this.landedAmount = 0,
    this.departmentId,
    this.consumptionAreaId,
    this.batches = const [],
    this.serials = const [],
  });

  /// Used after the batches/serials children are fetched in a second query
  /// (rid_transaction_line_batches/serials aren't embeddable joins — they're
  /// keyed by source_doc_type/no/date, not a real FK PostgREST can traverse).
  GrnLineModel withChildren({List<GrnBatchModel>? batches, List<GrnSerialModel>? serials}) => GrnLineModel(
    id: id, serialNo: serialNo, productId: productId, productCode: productCode, productName: productName,
    sourcePoOrderNo: sourcePoOrderNo, sourcePoOrderDate: sourcePoOrderDate, sourcePoLineSerial: sourcePoLineSerial,
    itemDescription: itemDescription, uomId: uomId, uomLabel: uomLabel, uomConversionFactor: uomConversionFactor,
    qtyPack: qtyPack, qtyLoose: qtyLoose, baseQty: baseQty, rate: rate, grossAmount: grossAmount,
    discountPercent: discountPercent, discountAmount: discountAmount, taxGroupId: taxGroupId, taxGroupName: taxGroupName,
    taxAmount: taxAmount, finalAmount: finalAmount, baseAmount: baseAmount, localAmount: localAmount,
    chargeAmount: chargeAmount, landedAmount: landedAmount, departmentId: departmentId, consumptionAreaId: consumptionAreaId,
    batches: batches ?? this.batches, serials: serials ?? this.serials,
  );

  factory GrnLineModel.fromJson(Map<String, dynamic> j) {
    final product  = j['product'] as Map<String, dynamic>?;
    final uom      = j['uom'] as Map<String, dynamic>?;
    final taxGroup = j['tax_group'] as Map<String, dynamic>?;
    return GrnLineModel(
      id:                  j['id'] as String,
      serialNo:            j['serial_no'] as int,
      productId:           j['product_id'] as String,
      productCode:         product?['product_code'] as String?,
      productName:         product?['product_name'] as String?,
      sourcePoOrderNo:     j['source_po_order_no'] as String?,
      sourcePoOrderDate:   j['source_po_order_date'] as String?,
      sourcePoLineSerial:  j['source_po_line_serial'] as int?,
      itemDescription:     j['item_description'] as String?,
      uomId:               j['uom_id'] as String? ?? '',
      uomLabel:            uom?['description'] as String?,
      uomConversionFactor: (j['uom_conversion_factor'] as num? ?? 1).toDouble(),
      qtyPack:             (j['qty_pack'] as num? ?? 0).toDouble(),
      qtyLoose:            (j['qty_loose'] as num? ?? 0).toDouble(),
      baseQty:             (j['base_qty'] as num? ?? 0).toDouble(),
      rate:                (j['rate'] as num? ?? 0).toDouble(),
      grossAmount:         (j['gross_amount'] as num? ?? 0).toDouble(),
      discountPercent:     (j['discount_percent'] as num? ?? 0).toDouble(),
      discountAmount:      (j['discount_amount'] as num? ?? 0).toDouble(),
      taxGroupId:          j['tax_group_id'] as String?,
      taxGroupName:        taxGroup?['group_name'] as String?,
      taxAmount:           (j['tax_amount'] as num? ?? 0).toDouble(),
      finalAmount:         (j['final_amount'] as num? ?? 0).toDouble(),
      baseAmount:          (j['base_amount'] as num? ?? 0).toDouble(),
      localAmount:         (j['local_amount'] as num? ?? 0).toDouble(),
      chargeAmount:        (j['charge_amount'] as num? ?? 0).toDouble(),
      landedAmount:        (j['landed_amount'] as num? ?? 0).toDouble(),
      departmentId:        j['department_id'] as String?,
      consumptionAreaId:   j['consumption_area_id'] as String?,
    );
  }
}

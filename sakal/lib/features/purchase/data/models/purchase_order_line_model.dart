/// PostgREST can return a NUMERIC/DECIMAL column as either a JSON number or
/// a JSON string (precision-preserving encoding) — `as num?` alone throws on
/// the string case rather than parsing it.
double _asDouble(dynamic v, [double fallback = 0]) {
  if (v == null) return fallback;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

double? _asDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// rid_purchase_order_lines. See backend/migrations/031_purchase_orders.sql.
class PurchaseOrderLineModel {
  final String  id;
  final int     serialNo;
  final String  productId;
  final String? productCode;
  final String? productName;
  final String? itemDescription;
  final String? barcode;
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
  final double? qtyOnHandAtOrder;
  final double? reorderLevelAtOrder;
  final double  qtyReceived;

  const PurchaseOrderLineModel({
    required this.id,
    required this.serialNo,
    required this.productId,
    this.productCode,
    this.productName,
    this.itemDescription,
    this.barcode,
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
    this.qtyOnHandAtOrder,
    this.reorderLevelAtOrder,
    this.qtyReceived = 0,
  });

  factory PurchaseOrderLineModel.fromJson(Map<String, dynamic> j) {
    final product  = j['product'] as Map<String, dynamic>?;
    final uom      = j['uom'] as Map<String, dynamic>?;
    final taxGroup = j['tax_group'] as Map<String, dynamic>?;
    return PurchaseOrderLineModel(
      id:                  j['id'] as String,
      serialNo:            j['serial_no'] as int,
      productId:           j['product_id'] as String,
      productCode:         product?['product_code'] as String?,
      productName:         product?['product_name'] as String?,
      itemDescription:     j['item_description'] as String?,
      barcode:             j['barcode'] as String?,
      uomId:               j['uom_id'] as String,
      uomLabel:            uom?['description'] as String?,
      uomConversionFactor: _asDouble(j['uom_conversion_factor'], 1),
      qtyPack:             _asDouble(j['qty_pack']),
      qtyLoose:            _asDouble(j['qty_loose']),
      baseQty:             _asDouble(j['base_qty']),
      rate:                _asDouble(j['rate']),
      grossAmount:         _asDouble(j['gross_amount']),
      discountPercent:     _asDouble(j['discount_percent']),
      discountAmount:      _asDouble(j['discount_amount']),
      taxGroupId:          j['tax_group_id'] as String?,
      taxGroupName:        taxGroup?['group_name'] as String?,
      taxAmount:           _asDouble(j['tax_amount']),
      finalAmount:         _asDouble(j['final_amount']),
      baseAmount:          _asDouble(j['base_amount']),
      localAmount:         _asDouble(j['local_amount']),
      chargeAmount:        _asDouble(j['charge_amount']),
      landedAmount:        _asDouble(j['landed_amount']),
      departmentId:        j['department_id'] as String?,
      consumptionAreaId:   j['consumption_area_id'] as String?,
      qtyOnHandAtOrder:    _asDoubleOrNull(j['qty_on_hand_at_order']),
      reorderLevelAtOrder: _asDoubleOrNull(j['reorder_level_at_order']),
      qtyReceived:         _asDouble(j['qty_received']),
    );
  }
}

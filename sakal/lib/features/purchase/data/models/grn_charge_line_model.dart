/// rid_grn_charge_lines. Same shape as PoChargeLineModel plus source_po_*
/// traceability — a charge carried forward from a consolidated PO keeps a
/// pointer back to which PO it came from.
class GrnChargeLineModel {
  final String  id;
  final int     serialNo;
  final String  chargeId;
  final String  chargeName;
  final bool    isTaxable;
  final String? taxId;
  final String  nature; // ADD / DEDUCT
  final String? glAccountId;
  final String  amountOrPercent; // AMOUNT / PERCENT
  final double? percent;
  final double  amount;
  final double  taxAmount;
  final double? allocationFactor;
  final String? sourcePoOrderNo;
  final String? sourcePoOrderDate;

  const GrnChargeLineModel({
    required this.id,
    required this.serialNo,
    required this.chargeId,
    required this.chargeName,
    this.isTaxable = false,
    this.taxId,
    this.nature = 'ADD',
    this.glAccountId,
    this.amountOrPercent = 'AMOUNT',
    this.percent,
    this.amount = 0,
    this.taxAmount = 0,
    this.allocationFactor,
    this.sourcePoOrderNo,
    this.sourcePoOrderDate,
  });

  factory GrnChargeLineModel.fromJson(Map<String, dynamic> j) => GrnChargeLineModel(
    id:                j['id'] as String,
    serialNo:          j['serial_no'] as int,
    chargeId:          j['charge_id'] as String,
    chargeName:        j['charge_name'] as String,
    isTaxable:         j['is_taxable'] as bool? ?? false,
    taxId:             j['tax_id'] as String?,
    nature:            j['nature'] as String? ?? 'ADD',
    glAccountId:       j['gl_account_id'] as String?,
    amountOrPercent:   j['amount_or_percent'] as String? ?? 'AMOUNT',
    percent:           (j['percent'] as num?)?.toDouble(),
    amount:            (j['amount'] as num? ?? 0).toDouble(),
    taxAmount:         (j['tax_amount'] as num? ?? 0).toDouble(),
    allocationFactor:  (j['allocation_factor'] as num?)?.toDouble(),
    sourcePoOrderNo:   j['source_po_order_no'] as String?,
    sourcePoOrderDate: j['source_po_order_date'] as String?,
  );
}

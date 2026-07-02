/// rid_po_charge_lines. See backend/migrations/031_purchase_orders.sql.
/// isTaxable / taxId / nature / glAccountId / amountOrPercent are frozen
/// copies from rim_additional_charges at entry time — only percent/amount
/// are editable per transaction.
class PoChargeLineModel {
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

  const PoChargeLineModel({
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
  });

  factory PoChargeLineModel.fromJson(Map<String, dynamic> j) => PoChargeLineModel(
    id:               j['id'] as String,
    serialNo:         j['serial_no'] as int,
    chargeId:         j['charge_id'] as String,
    chargeName:       j['charge_name'] as String,
    isTaxable:        j['is_taxable'] as bool? ?? false,
    taxId:            j['tax_id'] as String?,
    nature:           j['nature'] as String? ?? 'ADD',
    glAccountId:      j['gl_account_id'] as String?,
    amountOrPercent:  j['amount_or_percent'] as String? ?? 'AMOUNT',
    percent:          (j['percent'] as num?)?.toDouble(),
    amount:           (j['amount'] as num? ?? 0).toDouble(),
    taxAmount:        (j['tax_amount'] as num? ?? 0).toDouble(),
    allocationFactor: (j['allocation_factor'] as num?)?.toDouble(),
  );
}

class TaxRateModel {
  final String?   id;
  final String    clientId;
  final String    companyId;
  final String    taxId;
  final String    rateLabel;       // STANDARD | REDUCED | ZERO | EXEMPT | SPECIAL
  final double    rate;
  final DateTime  effectiveFrom;
  final DateTime? effectiveTo;     // null = currently active
  final double?   thresholdMin;
  final double?   thresholdMax;
  final String?   description;
  final bool      isActive;

  const TaxRateModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.taxId,
    required this.rateLabel,
    required this.rate,
    required this.effectiveFrom,
    this.effectiveTo,
    this.thresholdMin,
    this.thresholdMax,
    this.description,
    this.isActive = true,
  });

  factory TaxRateModel.fromJson(Map<String, dynamic> j) => TaxRateModel(
    id:            j['id']             as String?,
    clientId:      j['client_id']      as String,
    companyId:     j['company_id']     as String,
    taxId:         j['tax_id']         as String,
    rateLabel:     j['rate_label']     as String? ?? 'STANDARD',
    rate:          (j['rate']          as num).toDouble(),
    effectiveFrom: DateTime.parse(j['effective_from'] as String),
    effectiveTo:   j['effective_to'] != null
        ? DateTime.parse(j['effective_to'] as String) : null,
    thresholdMin:  j['threshold_min'] != null
        ? (j['threshold_min'] as num).toDouble() : null,
    thresholdMax:  j['threshold_max'] != null
        ? (j['threshold_max'] as num).toDouble() : null,
    description:   j['description'] as String?,
    isActive:      j['is_active']  as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'client_id':      clientId,
    'company_id':     companyId,
    'tax_id':         taxId,
    'rate_label':     rateLabel,
    'rate':           rate,
    'effective_from': effectiveFrom.toIso8601String().substring(0, 10),
    if (effectiveTo != null)
      'effective_to': effectiveTo!.toIso8601String().substring(0, 10),
    if (thresholdMin != null) 'threshold_min': thresholdMin,
    if (thresholdMax != null) 'threshold_max': thresholdMax,
    if (description  != null) 'description':   description,
    'is_active': isActive,
  };

  bool get isCurrent {
    final now = DateTime.now();
    if (now.isBefore(effectiveFrom)) return false;
    if (effectiveTo != null && now.isAfter(effectiveTo!)) return false;
    return isActive;
  }

  TaxRateModel copyWith({
    String?   id,
    String?   rateLabel,
    double?   rate,
    DateTime? effectiveFrom,
    DateTime? effectiveTo,
    double?   thresholdMin,
    double?   thresholdMax,
    String?   description,
    bool?     isActive,
  }) =>
      TaxRateModel(
        id:            id            ?? this.id,
        clientId:      clientId,
        companyId:     companyId,
        taxId:         taxId,
        rateLabel:     rateLabel     ?? this.rateLabel,
        rate:          rate          ?? this.rate,
        effectiveFrom: effectiveFrom ?? this.effectiveFrom,
        effectiveTo:   effectiveTo   ?? this.effectiveTo,
        thresholdMin:  thresholdMin  ?? this.thresholdMin,
        thresholdMax:  thresholdMax  ?? this.thresholdMax,
        description:   description   ?? this.description,
        isActive:      isActive      ?? this.isActive,
      );
}

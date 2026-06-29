class ProductModel {
  final String? id;
  final String  clientId;
  final String  companyId;

  // Codes
  final String  productCode;
  final String? barcode;
  final String? partNumber;

  // Names
  final String  productName;
  final String? shortName;
  final String? description;

  // Classification
  final String  productNature; // TRADING | FINISHED_GOOD | RAW_MATERIAL | PACKAGING | CONSUMABLE | SERVICE
  final String? categoryId;
  final String? brandId;
  final String? itemSizeId;
  final String? itemColorId;
  final String? baseUomId;

  // Costing
  final double  standardCost;
  final double  averageCost;
  final double  lastPurchaseCost;
  final double  allowedCostVariance;
  final String? costCurrencyId; // "Maintain Price In" currency

  // Taxation
  final String? salesTaxGroupId;
  final String? purchaseTaxGroupId;
  final String? hsnSacCode;

  // Supplier
  final String? mainSupplierId;
  final int     leadTimeDays;

  // Physical dimensions
  final double? weight;
  final String? weightUom;    // g | kg | lb | oz
  final double? volume;
  final String? volumeUom;    // ml | L | fl_oz | cm3
  final double? length;
  final double? width;
  final double? height;
  final String? dimensionUom; // mm | cm | inch | m

  // Tracking
  final String trackingType; // NONE | BATCH | SERIAL | BATCH_WITH_EXPIRY

  // Status flags
  final bool isActive;
  final bool isDeleted;
  final bool isScalable;

  // Dynamic business flags (from rim_product_flag_types)
  final Map<String, bool> flags;

  // Misc
  final int     sortOrder;
  final String? remarks;

  // Audit
  final String? createdBy;
  final String? updatedBy;

  // Joined display names — populated only for list queries with PostgREST embed
  final String? categoryName;
  final String? baseUomName;

  const ProductModel({
    this.id,
    required this.clientId,
    required this.companyId,
    required this.productCode,
    this.barcode,
    this.partNumber,
    required this.productName,
    this.shortName,
    this.description,
    this.productNature        = 'TRADING',
    this.categoryId,
    this.brandId,
    this.itemSizeId,
    this.itemColorId,
    this.baseUomId,
    this.standardCost         = 0,
    this.averageCost          = 0,
    this.lastPurchaseCost     = 0,
    this.allowedCostVariance  = 0,
    this.costCurrencyId,
    this.salesTaxGroupId,
    this.purchaseTaxGroupId,
    this.hsnSacCode,
    this.mainSupplierId,
    this.leadTimeDays         = 0,
    this.weight,
    this.weightUom,
    this.volume,
    this.volumeUom,
    this.length,
    this.width,
    this.height,
    this.dimensionUom,
    this.trackingType         = 'NONE',
    this.isActive             = true,
    this.isDeleted            = false,
    this.isScalable           = false,
    this.flags                = const {},
    this.sortOrder            = 0,
    this.remarks,
    this.createdBy,
    this.updatedBy,
    this.categoryName,
    this.baseUomName,
  });

  factory ProductModel.fromJson(Map<String, dynamic> j) {
    final rawFlags = j['flags'] as Map<String, dynamic>? ?? {};
    // Handle PostgREST embedded objects from list queries
    final catEmbed  = j['category'] as Map<String, dynamic>?;
    final uomEmbed  = j['base_uom'] as Map<String, dynamic>?;
    return ProductModel(
      id:                   j['id']                     as String?,
      clientId:             j['client_id']              as String,
      companyId:            j['company_id']             as String,
      productCode:          j['product_code']           as String,
      barcode:              j['barcode']                as String?,
      partNumber:           j['part_number']            as String?,
      productName:          j['product_name']           as String,
      shortName:            j['short_name']             as String?,
      description:          j['description']            as String?,
      productNature:        j['product_nature']         as String? ?? 'TRADING',
      categoryId:           j['category_id']            as String?,
      brandId:              j['brand_id']               as String?,
      itemSizeId:           j['item_size_id']           as String?,
      itemColorId:          j['item_color_id']          as String?,
      baseUomId:            j['base_uom_id']            as String?,
      standardCost:         _toDouble(j['standard_cost']),
      averageCost:          _toDouble(j['average_cost']),
      lastPurchaseCost:     _toDouble(j['last_purchase_cost']),
      allowedCostVariance:  _toDouble(j['allowed_cost_variance']),
      costCurrencyId:       j['cost_currency_id']       as String?,
      salesTaxGroupId:      j['sales_tax_group_id']     as String?,
      purchaseTaxGroupId:   j['purchase_tax_group_id']  as String?,
      hsnSacCode:           j['hsn_sac_code']           as String?,
      mainSupplierId:       j['main_supplier_id']       as String?,
      leadTimeDays:         j['lead_time_days']         as int? ?? 0,
      weight:               _toDoubleNullable(j['weight']),
      weightUom:            j['weight_uom']             as String?,
      volume:               _toDoubleNullable(j['volume']),
      volumeUom:            j['volume_uom']             as String?,
      length:               _toDoubleNullable(j['length']),
      width:                _toDoubleNullable(j['width']),
      height:               _toDoubleNullable(j['height']),
      dimensionUom:         j['dimension_uom']          as String?,
      trackingType:         j['tracking_type']          as String? ?? 'NONE',
      isActive:             j['is_active']              as bool? ?? true,
      isDeleted:            j['is_deleted']             as bool? ?? false,
      isScalable:           j['is_scalable']            as bool? ?? false,
      flags:                rawFlags.map((k, v) => MapEntry(k, (v as bool?) ?? false)),
      sortOrder:            j['sort_order']             as int? ?? 0,
      remarks:              j['remarks']                as String?,
      createdBy:            j['created_by']             as String?,
      updatedBy:            j['updated_by']             as String?,
      categoryName:         catEmbed?['category_name']  as String?,
      baseUomName:          uomEmbed?['description']    as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null)               'id':                    id,
        'client_id':                  clientId,
        'company_id':                 companyId,
        'product_code':               productCode,
        if (barcode != null)          'barcode':               barcode,
        if (partNumber != null)       'part_number':           partNumber,
        'product_name':               productName,
        if (shortName != null)        'short_name':            shortName,
        if (description != null)      'description':           description,
        'product_nature':             productNature,
        if (categoryId != null)       'category_id':           categoryId,
        if (brandId != null)          'brand_id':              brandId,
        if (itemSizeId != null)       'item_size_id':          itemSizeId,
        if (itemColorId != null)      'item_color_id':         itemColorId,
        if (baseUomId != null)        'base_uom_id':           baseUomId,
        'standard_cost':              standardCost,
        'allowed_cost_variance':      allowedCostVariance,
        if (costCurrencyId != null)   'cost_currency_id':      costCurrencyId,
        if (salesTaxGroupId != null)  'sales_tax_group_id':    salesTaxGroupId,
        if (purchaseTaxGroupId != null) 'purchase_tax_group_id': purchaseTaxGroupId,
        if (hsnSacCode != null)       'hsn_sac_code':          hsnSacCode,
        if (mainSupplierId != null)   'main_supplier_id':      mainSupplierId,
        'lead_time_days':             leadTimeDays,
        if (weight != null)           'weight':                weight,
        if (weightUom != null)        'weight_uom':            weightUom,
        if (volume != null)           'volume':                volume,
        if (volumeUom != null)        'volume_uom':            volumeUom,
        if (length != null)           'length':                length,
        if (width != null)            'width':                 width,
        if (height != null)           'height':                height,
        if (dimensionUom != null)     'dimension_uom':         dimensionUom,
        'tracking_type':              trackingType,
        'is_active':                  isActive,
        'is_scalable':                isScalable,
        'flags':                      flags,
        'sort_order':                 sortOrder,
        if (remarks != null)          'remarks':               remarks,
      };

  static double _toDouble(dynamic v) {
    if (v == null) return 0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  static double? _toDoubleNullable(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static const natureLabels = {
    'TRADING':      'Trading / Resale',
    'FINISHED_GOOD':'Finished Good',
    'RAW_MATERIAL': 'Raw Material',
    'PACKAGING':    'Packaging',
    'CONSUMABLE':   'Consumable',
    'SERVICE':      'Service',
  };

  static const trackingLabels = {
    'NONE':              'No Tracking',
    'BATCH':             'Batch / Lot',
    'SERIAL':            'Serial Number',
    'BATCH_WITH_EXPIRY': 'Batch + Expiry Date',
  };
}

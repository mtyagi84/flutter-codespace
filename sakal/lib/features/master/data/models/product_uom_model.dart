class ProductUomModel {
  final String? id;
  final String  clientId;
  final String  companyId;
  final String? productId;
  final String  uomId;
  final double  conversionFactor;
  final String? barcode;
  final bool    isBaseUom;
  final bool    isPurchaseUom;
  final bool    isSalesUom;
  final int     sortOrder;

  // Joined — populated from PostgREST embed
  final String? uomName;

  const ProductUomModel({
    this.id,
    required this.clientId,
    required this.companyId,
    this.productId,
    required this.uomId,
    this.conversionFactor = 1,
    this.barcode,
    this.isBaseUom     = false,
    this.isPurchaseUom = false,
    this.isSalesUom    = false,
    this.sortOrder     = 0,
    this.uomName,
  });

  factory ProductUomModel.fromJson(Map<String, dynamic> j) {
    final uomEmbed = j['uom_name'] as Map<String, dynamic>?;
    final cf       = j['conversion_factor'];
    return ProductUomModel(
      id:               j['id']               as String?,
      clientId:         j['client_id']        as String,
      companyId:        j['company_id']       as String,
      productId:        j['product_id']       as String?,
      uomId:            j['uom_id']           as String,
      conversionFactor: cf is double ? cf : (cf is int ? cf.toDouble() : double.tryParse(cf.toString()) ?? 1),
      barcode:          j['barcode']          as String?,
      isBaseUom:        j['is_base_uom']      as bool? ?? false,
      isPurchaseUom:    j['is_purchase_uom']  as bool? ?? false,
      isSalesUom:       j['is_sales_uom']     as bool? ?? false,
      sortOrder:        j['sort_order']       as int? ?? 0,
      uomName:          uomEmbed?['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null)         'id':                id,
        'client_id':            clientId,
        'company_id':           companyId,
        if (productId != null)  'product_id':        productId,
        'uom_id':               uomId,
        'conversion_factor':    conversionFactor,
        if (barcode != null)    'barcode':           barcode,
        'is_base_uom':          isBaseUom,
        'is_purchase_uom':      isPurchaseUom,
        'is_sales_uom':         isSalesUom,
        'sort_order':           sortOrder,
      };

  ProductUomModel copyWith({
    String? productId,
    String? uomId,
    String? uomName,
    double? conversionFactor,
    String? barcode,
    bool?   isBaseUom,
    bool?   isPurchaseUom,
    bool?   isSalesUom,
    int?    sortOrder,
  }) =>
      ProductUomModel(
        id:               id,
        clientId:         clientId,
        companyId:        companyId,
        productId:        productId        ?? this.productId,
        uomId:            uomId            ?? this.uomId,
        conversionFactor: conversionFactor ?? this.conversionFactor,
        barcode:          barcode          ?? this.barcode,
        isBaseUom:        isBaseUom        ?? this.isBaseUom,
        isPurchaseUom:    isPurchaseUom    ?? this.isPurchaseUom,
        isSalesUom:       isSalesUom       ?? this.isSalesUom,
        sortOrder:        sortOrder        ?? this.sortOrder,
        uomName:          uomName          ?? this.uomName,
      );
}

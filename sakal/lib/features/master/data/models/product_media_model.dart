class ProductMediaModel {
  final String? id;
  final String  clientId;
  final String  companyId;
  final String? productId;
  final String  mediaType; // IMAGE | VIDEO
  final String? mediaData; // base64 for images
  final String? mediaUrl;  // URL for videos
  final bool    isPrimary;
  final int     sortOrder;
  final String? caption;

  const ProductMediaModel({
    this.id,
    required this.clientId,
    required this.companyId,
    this.productId,
    this.mediaType  = 'IMAGE',
    this.mediaData,
    this.mediaUrl,
    this.isPrimary  = false,
    this.sortOrder  = 0,
    this.caption,
  });

  factory ProductMediaModel.fromJson(Map<String, dynamic> j) => ProductMediaModel(
        id:         j['id']          as String?,
        clientId:   j['client_id']   as String,
        companyId:  j['company_id']  as String,
        productId:  j['product_id']  as String?,
        mediaType:  j['media_type']  as String? ?? 'IMAGE',
        mediaData:  j['media_data']  as String?,
        mediaUrl:   j['media_url']   as String?,
        isPrimary:  j['is_primary']  as bool? ?? false,
        sortOrder:  j['sort_order']  as int? ?? 0,
        caption:    j['caption']     as String?,
      );

  Map<String, dynamic> toJson() => {
        if (id != null)        'id':          id,
        'client_id':           clientId,
        'company_id':          companyId,
        if (productId != null) 'product_id':  productId,
        'media_type':          mediaType,
        if (mediaData != null) 'media_data':  mediaData,
        if (mediaUrl != null)  'media_url':   mediaUrl,
        'is_primary':          isPrimary,
        'sort_order':          sortOrder,
        if (caption != null)   'caption':     caption,
      };
}

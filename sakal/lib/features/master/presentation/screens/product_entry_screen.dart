import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/datasources/products_remote_ds.dart';
import '../../data/models/common_master_model.dart';
import '../../data/models/item_category_model.dart';
import '../../data/models/product_flag_type_model.dart';
import '../../data/models/product_media_model.dart';
import '../../data/models/product_model.dart';
import '../../data/models/product_uom_model.dart';
import '../../data/models/tax_group_model.dart';

// ── Entry point ───────────────────────────────────────────────────────────────

class ProductEntryScreen extends ConsumerStatefulWidget {
  final String? productId;
  const ProductEntryScreen({this.productId, super.key});

  @override
  ConsumerState<ProductEntryScreen> createState() => _ProductEntryScreenState();
}

class _ProductEntryScreenState extends ConsumerState<ProductEntryScreen>
    with ScreenPermissionMixin<ProductEntryScreen> {
  @override
  String get screenName => RouteNames.productMaster;

  final _ds      = ProductsRemoteDs();
  final _formKey = GlobalKey<FormState>();

  // ── Form controllers ───────────────────────────────────────────────────────
  final _codeCtrl      = TextEditingController();
  final _nameCtrl      = TextEditingController();
  final _shortCtrl     = TextEditingController();
  final _descCtrl      = TextEditingController();
  final _barcodeCtrl   = TextEditingController();
  final _partNoCtrl    = TextEditingController();
  final _hsnCtrl       = TextEditingController();
  final _remarksCtrl   = TextEditingController();
  final _stdCostCtrl   = TextEditingController();
  final _varCtrl       = TextEditingController();
  final _leadTimeCtrl  = TextEditingController();
  final _weightCtrl    = TextEditingController();
  final _volumeCtrl    = TextEditingController();
  final _lengthCtrl    = TextEditingController();
  final _widthCtrl     = TextEditingController();
  final _heightCtrl    = TextEditingController();

  // ── Dropdown selections ────────────────────────────────────────────────────
  String  _nature       = 'TRADING';
  String  _trackingType = 'NONE';
  bool    _isScalable   = false;
  bool    _isActive     = true;
  String? _weightUom;
  String? _volumeUom;
  String? _dimensionUom;

  // ── FK pickers ─────────────────────────────────────────────────────────────
  String? _categoryId;     String? _categoryDisplay;
  String? _brandId;        String? _brandDisplay;
  String? _itemSizeId;     String? _itemSizeDisplay;
  String? _itemColorId;    String? _itemColorDisplay;
  String? _baseUomId;      String? _baseUomDisplay;
  String? _costCurrencyId; String? _costCurrencyDisplay;
  String? _salesTaxId;     String? _salesTaxDisplay;
  String? _purchTaxId;     String? _purchTaxDisplay;

  // ── Sub-table state ────────────────────────────────────────────────────────
  List<ProductUomModel>  _uomRows   = [];
  List<_MediaEntry>      _mediaItems = [];

  // ── Flags ──────────────────────────────────────────────────────────────────
  Map<String, bool>          _flags     = {};
  List<ProductFlagTypeModel> _flagTypes = [];

  // ── Reference data ─────────────────────────────────────────────────────────
  List<ItemCategoryModel>    _categories   = [];
  List<CommonMasterModel>    _brands       = [];
  List<CommonMasterModel>    _sizes        = [];
  List<CommonMasterModel>    _colors       = [];
  List<CommonMasterModel>    _uoms         = [];
  List<TaxGroupModel>        _taxGroups    = [];
  List<Map<String, dynamic>> _currencies   = [];
  Map<String, String>        _catPaths     = {}; // id → full breadcrumb

  // ── Read-only cost display ─────────────────────────────────────────────────
  double _averageCost      = 0;
  double _lastPurchaseCost = 0;

  // ── Screen state ───────────────────────────────────────────────────────────
  bool    _loadingRefs = true;
  bool    _loadingProd = false;
  bool    _saving      = false;
  String? _error;
  String? _successMsg;

  bool get _isNew => widget.productId == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    for (final c in [
      _codeCtrl, _nameCtrl, _shortCtrl, _descCtrl, _barcodeCtrl,
      _partNoCtrl, _hsnCtrl, _remarksCtrl, _stdCostCtrl, _varCtrl,
      _leadTimeCtrl, _weightCtrl, _volumeCtrl, _lengthCtrl, _widthCtrl,
      _heightCtrl,
    ]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    await _loadRefs(session);
    if (!_isNew && mounted) await _loadProduct(widget.productId!);
  }

  // ── Load reference data (all in parallel) ───────────────────────────────────

  Future<void> _loadRefs(UserSession session) async {
    try {
      final results = await Future.wait([
        _ds.loadMasterSets(
            clientId: session.clientId, companyId: session.companyId),
        _ds.getCategories(
            clientId: session.clientId, companyId: session.companyId),
        _ds.getTaxGroups(
            clientId: session.clientId, companyId: session.companyId),
        _ds.getCurrencies(session.clientId),
        _ds.getFlagTypes(
            clientId: session.clientId, companyId: session.companyId),
      ]);

      final masterSets  = results[0] as Map<String, List<CommonMasterModel>>;
      final categories  = results[1] as List<ItemCategoryModel>;
      final taxGroups   = results[2] as List<TaxGroupModel>;
      final currencies  = results[3] as List<Map<String, dynamic>>;
      final flagTypes   = results[4] as List<ProductFlagTypeModel>;

      if (!mounted) return;
      setState(() {
        _brands     = masterSets['BRAND']     ?? [];
        _uoms       = masterSets['UNIT']      ?? [];
        _sizes      = masterSets['ITEM_SIZE'] ?? [];
        _colors     = masterSets['COLOR']     ?? [];
        _categories = categories;
        _catPaths   = _buildCategoryPaths(categories);
        _taxGroups  = taxGroups;
        _currencies = currencies;
        _flagTypes  = flagTypes;
        // For new products, initialize flags from default values
        if (_isNew) {
          _flags = {for (final f in flagTypes) f.flagKey: f.defaultValue};
        }
        _loadingRefs = false;
      });
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _loadingRefs = false;
          _error = 'Failed to load reference data: '
              '${e.response?.data?['message'] ?? e.message}';
        });
      }
    }
  }

  Map<String, String> _buildCategoryPaths(List<ItemCategoryModel> cats) {
    final byId = {for (final c in cats) if (c.id != null) c.id!: c};
    String path(String id) {
      final c = byId[id];
      if (c == null) return '';
      if (c.parentId == null) return c.categoryName;
      final p = path(c.parentId!);
      return p.isEmpty ? c.categoryName : '$p › ${c.categoryName}';
    }
    return {for (final c in cats) if (c.id != null) c.id!: path(c.id!)};
  }

  // ── Load existing product ──────────────────────────────────────────────────

  Future<void> _loadProduct(String id) async {
    if (mounted) setState(() { _loadingProd = true; _error = null; });
    try {
      final results = await Future.wait([
        _ds.getProduct(id),
        _ds.getProductUoms(id),
        _ds.getProductMedia(id),
      ]);
      final product = results[0] as ProductModel?;
      final uoms    = results[1] as List<ProductUomModel>;
      final media   = results[2] as List<ProductMediaModel>;

      if (!mounted) return;
      if (product == null) {
        setState(() { _loadingProd = false; _error = 'Product not found.'; });
        return;
      }
      _populate(product, uoms, media);
      setState(() => _loadingProd = false);
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _loadingProd = false;
          _error = e.response?.data?['message'] as String? ?? 'Failed to load product.';
        });
      }
    }
  }

  void _populate(
    ProductModel p,
    List<ProductUomModel>   uoms,
    List<ProductMediaModel> media,
  ) {
    _codeCtrl.text      = p.productCode;
    _nameCtrl.text      = p.productName;
    _shortCtrl.text     = p.shortName    ?? '';
    _descCtrl.text      = p.description  ?? '';
    _barcodeCtrl.text   = p.barcode      ?? '';
    _partNoCtrl.text    = p.partNumber   ?? '';
    _hsnCtrl.text       = p.hsnSacCode   ?? '';
    _remarksCtrl.text   = p.remarks      ?? '';
    _stdCostCtrl.text   = p.standardCost > 0 ? p.standardCost.toString() : '';
    _varCtrl.text       = p.allowedCostVariance > 0
        ? p.allowedCostVariance.toString()
        : '';
    _leadTimeCtrl.text  = p.leadTimeDays > 0 ? p.leadTimeDays.toString() : '';
    _weightCtrl.text    = p.weight  != null ? p.weight!.toString()  : '';
    _volumeCtrl.text    = p.volume  != null ? p.volume!.toString()  : '';
    _lengthCtrl.text    = p.length  != null ? p.length!.toString()  : '';
    _widthCtrl.text     = p.width   != null ? p.width!.toString()   : '';
    _heightCtrl.text    = p.height  != null ? p.height!.toString()  : '';

    _nature             = p.productNature;
    _trackingType       = p.trackingType;
    _isScalable         = p.isScalable;
    _isActive           = p.isActive;
    _weightUom          = p.weightUom;
    _volumeUom          = p.volumeUom;
    _dimensionUom       = p.dimensionUom;

    _categoryId         = p.categoryId;
    _categoryDisplay    = _catPaths[p.categoryId] ?? p.categoryName;
    _brandId            = p.brandId;
    _brandDisplay       = _brands.where((b) => b.id == p.brandId).firstOrNull?.description;
    _itemSizeId         = p.itemSizeId;
    _itemSizeDisplay    = _sizes.where((s) => s.id == p.itemSizeId).firstOrNull?.description;
    _itemColorId        = p.itemColorId;
    _itemColorDisplay   = _colors.where((c) => c.id == p.itemColorId).firstOrNull?.description;
    _baseUomId          = p.baseUomId;
    _baseUomDisplay     = _uoms.where((u) => u.id == p.baseUomId).firstOrNull?.description;
    _costCurrencyId     = p.costCurrencyId;
    _costCurrencyDisplay = _currencies
        .where((c) => c['id'] == p.costCurrencyId)
        .map<String>((c) => '${c['currency_id']} — ${c['currency_name']}')
        .firstOrNull;
    _salesTaxId         = p.salesTaxGroupId;
    _salesTaxDisplay    = _taxGroups.where((t) => t.id == p.salesTaxGroupId).firstOrNull?.groupName;
    _purchTaxId         = p.purchaseTaxGroupId;
    _purchTaxDisplay    = _taxGroups.where((t) => t.id == p.purchaseTaxGroupId).firstOrNull?.groupName;

    _averageCost        = p.averageCost;
    _lastPurchaseCost   = p.lastPurchaseCost;

    // Flags: merge saved values over defaults
    _flags = {
      for (final f in _flagTypes) f.flagKey: p.flags[f.flagKey] ?? f.defaultValue,
    };

    _uomRows    = uoms;
    _mediaItems = media
        .map((m) => _MediaEntry(
              id:        m.id,
              base64Data: m.mediaData ?? '',
              caption:   m.caption ?? '',
              isPrimary: m.isPrimary,
            ))
        .toList();
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _error = null; _successMsg = null; });

    try {
      final productId = widget.productId ?? const Uuid().v4();
      final now       = DateTime.now().toUtc().toIso8601String();

      final payload = <String, dynamic>{
        'id':           productId,
        'client_id':    session.clientId,
        'company_id':   session.companyId,
        'product_code': _codeCtrl.text.trim().toUpperCase(),
        'product_name': _nameCtrl.text.trim(),
        if (_shortCtrl.text.isNotEmpty)    'short_name':  _shortCtrl.text.trim(),
        if (_descCtrl.text.isNotEmpty)     'description': _descCtrl.text.trim(),
        if (session.enableBarcode && _barcodeCtrl.text.isNotEmpty)
          'barcode': _barcodeCtrl.text.trim(),
        if (session.enablePartNumber && _partNoCtrl.text.isNotEmpty)
          'part_number': _partNoCtrl.text.trim(),
        'product_nature':  _nature,
        if (_categoryId != null)    'category_id':           _categoryId,
        if (_brandId != null)       'brand_id':              _brandId,
        if (_itemSizeId != null)    'item_size_id':          _itemSizeId,
        if (_itemColorId != null)   'item_color_id':         _itemColorId,
        if (_baseUomId != null)     'base_uom_id':           _baseUomId,
        'standard_cost': double.tryParse(_stdCostCtrl.text) ?? 0,
        'allowed_cost_variance': double.tryParse(_varCtrl.text) ?? 0,
        if (_costCurrencyId != null) 'cost_currency_id':      _costCurrencyId,
        if (_salesTaxId != null)    'sales_tax_group_id':    _salesTaxId,
        if (_purchTaxId != null)    'purchase_tax_group_id': _purchTaxId,
        if (_hsnCtrl.text.isNotEmpty) 'hsn_sac_code': _hsnCtrl.text.trim(),
        'lead_time_days':  int.tryParse(_leadTimeCtrl.text) ?? 0,
        if (_weightCtrl.text.isNotEmpty) 'weight': double.tryParse(_weightCtrl.text),
        if (_weightUom != null)          'weight_uom':  _weightUom,
        if (_volumeCtrl.text.isNotEmpty) 'volume': double.tryParse(_volumeCtrl.text),
        if (_volumeUom != null)          'volume_uom':  _volumeUom,
        if (_lengthCtrl.text.isNotEmpty) 'length': double.tryParse(_lengthCtrl.text),
        if (_widthCtrl.text.isNotEmpty)  'width':  double.tryParse(_widthCtrl.text),
        if (_heightCtrl.text.isNotEmpty) 'height': double.tryParse(_heightCtrl.text),
        if (_dimensionUom != null)       'dimension_uom': _dimensionUom,
        'tracking_type': _trackingType,
        'is_active':     _isActive,
        'is_scalable':   _isScalable,
        'flags':         _flags,
        if (_remarksCtrl.text.isNotEmpty) 'remarks': _remarksCtrl.text.trim(),
        if (_isNew) 'created_by': session.userId
        else ...{
          'updated_by': session.userId,
          'updated_at': now,
        },
      };

      await _ds.saveProduct(payload, isNew: _isNew);
      await _saveUoms(productId, session);
      await _saveMedia(productId, session);

      if (!mounted) return;
      setState(() {
        _saving     = false;
        _successMsg = 'Product saved successfully.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Product saved.'),
              backgroundColor: AppColors.positive));
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error  = e.response?.data?['message'] as String? ?? 'Save failed. Please try again.';
        });
      }
    }
  }

  Future<void> _saveUoms(String productId, UserSession session) async {
    for (int i = 0; i < _uomRows.length; i++) {
      final row = _uomRows[i];
      if (row.id == null && row.uomId.isEmpty) continue; // skip empty placeholders
      final payload = row.copyWith(productId: productId, sortOrder: i)
          .toJson()
        ..['client_id']  = session.clientId
        ..['company_id'] = session.companyId;
      await _ds.saveProductUom(payload);
    }
  }

  Future<void> _saveMedia(String productId, UserSession session) async {
    for (int i = 0; i < _mediaItems.length; i++) {
      final m = _mediaItems[i];
      if (m.toDelete && m.id != null) {
        await _ds.deleteProductMedia(m.id!);
        continue;
      }
      if (m.isNew && m.base64Data.isNotEmpty) {
        await _ds.saveProductMedia({
          'id':         const Uuid().v4(),
          'client_id':  session.clientId,
          'company_id': session.companyId,
          'product_id': productId,
          'media_type': 'IMAGE',
          'media_data': m.base64Data,
          'caption':    m.caption.isNotEmpty ? m.caption : null,
          'is_primary': m.isPrimary,
          'sort_order': i,
          'created_by': session.userId,
        });
      }
    }
  }

  // ── Auto-generate code ─────────────────────────────────────────────────────

  Future<void> _generateCode() async {
    final session = ref.read(sessionProvider)!;
    try {
      final code = await _ds.generateProductCode(
          clientId: session.clientId, companyId: session.companyId);
      if (mounted) setState(() => _codeCtrl.text = code);
    } catch (_) {}
  }

  // ── Image picker ───────────────────────────────────────────────────────────

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final file   = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (file == null || !mounted) return;
    final bytes  = await file.readAsBytes();
    final b64    = base64Encode(bytes);
    setState(() {
      _mediaItems.add(_MediaEntry(
        base64Data: b64,
        isPrimary:  _mediaItems.isEmpty,
        isNew:      true,
      ));
    });
  }

  void _setPrimaryImage(int idx) {
    setState(() {
      for (int i = 0; i < _mediaItems.length; i++) {
        _mediaItems[i] = _mediaItems[i].copyWith(isPrimary: i == idx);
      }
    });
  }

  void _removeImage(int idx) {
    setState(() {
      final m = _mediaItems[idx];
      if (m.id != null) {
        _mediaItems[idx] = m.copyWith(toDelete: true);
      } else {
        _mediaItems.removeAt(idx);
      }
      // Re-assign primary if needed
      final visible = _mediaItems.where((e) => !e.toDelete).toList();
      if (visible.isNotEmpty && !visible.any((e) => e.isPrimary)) {
        final first = _mediaItems.indexOf(visible.first);
        _mediaItems[first] = _mediaItems[first].copyWith(isPrimary: true);
      }
    });
  }

  // ── UOM sub-table ──────────────────────────────────────────────────────────

  Future<void> _addOrEditUomRow({ProductUomModel? existing, int? index}) async {
    final result = await showDialog<ProductUomModel>(
      context: context,
      builder: (_) => _UomLevelDialog(
        existing:   existing,
        uomOptions: _uoms,
        session:    ref.read(sessionProvider)!,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index != null) {
        _uomRows[index] = result;
      } else {
        _uomRows.add(result);
      }
    });
  }

  void _deleteUomRow(int index) {
    final row = _uomRows[index];
    if (row.id != null) {
      _ds.deleteProductUom(row.id!).catchError((_) {});
    }
    setState(() => _uomRows.removeAt(index));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final offline = session?.offlineMode ?? false;
    final canSave = !offline && (_isNew ? canAdd : canEdit);

    if (_loadingRefs || _loadingProd) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        const OfflineBanner(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Page header ─────────────────────────────────────
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isNew ? 'New Product' : _nameCtrl.text.isNotEmpty
                                      ? _nameCtrl.text
                                      : 'Edit Product',
                                  style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary),
                                ),
                                const Text('Product Master',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppColors.textSecondary)),
                              ],
                            ),
                          ),
                          if (canSave)
                            FilledButton.icon(
                              onPressed: _saving ? null : _save,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 16, height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.save_outlined, size: 18),
                              label: Text(_saving ? 'Saving…' : 'Save Product'),
                            ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        _ErrorBanner(_error!),
                      ],
                      if (_successMsg != null) ...[
                        const SizedBox(height: 16),
                        _SuccessBanner(_successMsg!),
                      ],
                      const SizedBox(height: 24),
                      // ── Sections ────────────────────────────────────────
                      _buildBasicDetails(session!),
                      const SizedBox(height: 16),
                      _buildIdentifiers(session),
                      const SizedBox(height: 16),
                      _buildClassification(),
                      const SizedBox(height: 16),
                      _buildUomTracking(),
                      const SizedBox(height: 16),
                      _buildCosting(),
                      const SizedBox(height: 16),
                      _buildTaxation(),
                      const SizedBox(height: 16),
                      _buildDimensions(),
                      const SizedBox(height: 16),
                      _buildUomLevels(canSave),
                      const SizedBox(height: 16),
                      _buildFlags(),
                      const SizedBox(height: 16),
                      _buildImages(canSave),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Section 1: Basic Details ───────────────────────────────────────────────

  Widget _buildBasicDetails(UserSession session) => _SectionCard(
        title: 'Basic Details',
        icon:  Icons.inventory_2_outlined,
        children: [
          _TwoCol(
            left: TextFormField(
              controller: _codeCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Product Code *',
                hintText:  'e.g. PRD-00001',
                suffixIcon: _isNew
                    ? TextButton(
                        onPressed: _generateCode,
                        child: const Text('Generate'))
                    : null,
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Product code is required'
                  : null,
            ),
            right: TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Product Name *',
                hintText:  'Full product name',
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Product name is required'
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          _TwoCol(
            left: TextFormField(
              controller: _shortCtrl,
              decoration: const InputDecoration(
                labelText: 'Short Name',
                hintText:  'Abbreviation shown on receipts',
              ),
            ),
            right: DropdownButtonFormField<String>(
              value: _nature,
              decoration: const InputDecoration(labelText: 'Product Nature'),
              items: ProductModel.natureLabels.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) => setState(() => _nature = v ?? 'TRADING'),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _descCtrl,
            maxLines:   3,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText:  'Detailed product description',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            value: _isActive,
            onChanged: (v) => setState(() => _isActive = v),
          ),
        ],
      );

  // ── Section 2: Identifiers ─────────────────────────────────────────────────

  Widget _buildIdentifiers(UserSession session) {
    final showBarcode  = session.enableBarcode;
    final showPartNo   = session.enablePartNumber;
    return _SectionCard(
      title: 'Identifiers & Codes',
      icon:  Icons.qr_code_outlined,
      children: [
        if (showBarcode || showPartNo) ...[
          _TwoCol(
            left: showBarcode
                ? TextFormField(
                    controller: _barcodeCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Barcode',
                        hintText:  'Scan or type barcode',
                        prefixIcon: Icon(Icons.barcode_reader, size: 18)),
                  )
                : const SizedBox.shrink(),
            right: showPartNo
                ? TextFormField(
                    controller: _partNoCtrl,
                    decoration: const InputDecoration(
                        labelText: "Part Number",
                        hintText:  "Manufacturer's part number"),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),
        ],
        _TwoCol(
          left: TextFormField(
            controller: _hsnCtrl,
            decoration: const InputDecoration(
                labelText: 'HSN / SAC Code',
                hintText:  'For customs / GST classification'),
          ),
          right: TextFormField(
            controller: _remarksCtrl,
            decoration: const InputDecoration(
                labelText: 'Remarks',
                hintText:  'Internal notes'),
          ),
        ),
      ],
    );
  }

  // ── Section 3: Classification ──────────────────────────────────────────────

  Widget _buildClassification() => _SectionCard(
        title: 'Classification',
        icon:  Icons.category_outlined,
        children: [
          _TwoCol(
            left: _buildCategoryPicker(),
            right: _buildCommonMasterPicker(
              label:    'Brand',
              options:  _brands,
              value:    _brandId,
              display:  _brandDisplay,
              onPicked: (id, name) => setState(() { _brandId = id; _brandDisplay = name; }),
            ),
          ),
          const SizedBox(height: 16),
          _TwoCol(
            left: _buildCommonMasterPicker(
              label:    'Item Size',
              options:  _sizes,
              value:    _itemSizeId,
              display:  _itemSizeDisplay,
              onPicked: (id, name) => setState(() { _itemSizeId = id; _itemSizeDisplay = name; }),
            ),
            right: _buildCommonMasterPicker(
              label:    'Item Color',
              options:  _colors,
              value:    _itemColorId,
              display:  _itemColorDisplay,
              onPicked: (id, name) => setState(() { _itemColorId = id; _itemColorDisplay = name; }),
            ),
          ),
        ],
      );

  Widget _buildCategoryPicker() {
    final options = _categories.where((c) => c.id != null).toList();
    return Autocomplete<ItemCategoryModel>(
      displayStringForOption: (c) => _catPaths[c.id] ?? c.categoryName,
      initialValue: TextEditingValue(text: _categoryDisplay ?? ''),
      optionsBuilder: (val) {
        final q = val.text.toLowerCase();
        if (q.isEmpty) return options.take(20);
        return options.where((c) =>
            c.categoryName.toLowerCase().contains(q) ||
            (_catPaths[c.id] ?? '').toLowerCase().contains(q));
      },
      onSelected: (c) => setState(() {
        _categoryId      = c.id;
        _categoryDisplay = _catPaths[c.id] ?? c.categoryName;
      }),
      fieldViewBuilder: (ctx, ctrl, focus, onSubmit) => TextFormField(
        controller:  ctrl,
        focusNode:   focus,
        decoration:  const InputDecoration(
            labelText: 'Category',
            hintText:  'Type to search categories',
            suffixIcon: Icon(Icons.keyboard_arrow_down, size: 18)),
        onFieldSubmitted: (_) => onSubmit(),
      ),
    );
  }

  Widget _buildCommonMasterPicker({
    required String label,
    required List<CommonMasterModel> options,
    required String? value,
    required String? display,
    required void Function(String? id, String? name) onPicked,
  }) {
    if (options.isEmpty) {
      return InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text('No ${label.toLowerCase()} options defined',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      );
    }
    return DropdownButtonFormField<String?>(
      value: value,
      decoration: InputDecoration(labelText: label),
      isExpanded: true,
      items: [
        const DropdownMenuItem(value: null, child: Text('— None —')),
        ...options.map((o) => DropdownMenuItem(value: o.id, child: Text(o.description))),
      ],
      onChanged: (id) {
        final name = id == null ? null : options.firstWhere((o) => o.id == id).description;
        onPicked(id, name);
      },
    );
  }

  // ── Section 4: UOM & Tracking ──────────────────────────────────────────────

  Widget _buildUomTracking() => _SectionCard(
        title: 'UOM & Tracking',
        icon:  Icons.scale_outlined,
        children: [
          _TwoCol(
            left: DropdownButtonFormField<String?>(
              value: _baseUomId,
              decoration: const InputDecoration(labelText: 'Base UOM *'),
              isExpanded: true,
              validator: (v) => v == null ? 'Base UOM is required' : null,
              items: [
                const DropdownMenuItem(value: null, child: Text('— Select —')),
                ..._uoms.map((u) => DropdownMenuItem(
                    value: u.id, child: Text(u.description))),
              ],
              onChanged: (id) => setState(() {
                _baseUomId      = id;
                _baseUomDisplay = id == null
                    ? null
                    : _uoms.firstWhere((u) => u.id == id).description;
              }),
            ),
            right: DropdownButtonFormField<String>(
              value: _trackingType,
              decoration: const InputDecoration(labelText: 'Tracking Type'),
              items: ProductModel.trackingLabels.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) => setState(() => _trackingType = v ?? 'NONE'),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Scalable Item',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            subtitle: const Text(
                'Sold by weight on a weighing scale (e.g. loose grains, deli)',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            value: _isScalable,
            onChanged: (v) => setState(() => _isScalable = v),
          ),
        ],
      );

  // ── Section 5: Costing ─────────────────────────────────────────────────────

  Widget _buildCosting() => _SectionCard(
        title: 'Costing',
        icon:  Icons.attach_money_outlined,
        children: [
          _TwoCol(
            left: TextFormField(
              controller: _stdCostCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Standard Cost',
                  hintText:  '0.00',
                  helperText: 'In company base currency'),
            ),
            right: DropdownButtonFormField<String?>(
              value: _costCurrencyId,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Maintain Price In',
                  helperText: 'Optional: procurement reference currency'),
              items: [
                const DropdownMenuItem(value: null, child: Text('— Base currency —')),
                ..._currencies.map((c) => DropdownMenuItem(
                    value: c['id'] as String,
                    child: Text('${c['currency_id']} — ${c['currency_name']}'))),
              ],
              onChanged: (id) => setState(() {
                _costCurrencyId      = id;
                _costCurrencyDisplay = id == null
                    ? null
                    : _currencies
                        .where((c) => c['id'] == id)
                        .map<String>((c) => '${c['currency_id']} — ${c['currency_name']}')
                        .firstOrNull;
              }),
            ),
          ),
          const SizedBox(height: 16),
          _TwoCol(
            left: TextFormField(
              controller: _varCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Allowed Cost Variance %',
                  hintText:  '0.00',
                  helperText: 'Variance allowed before GRN alert'),
            ),
            right: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('System-Managed Costs',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: _ReadOnlyCost('Average Cost', _averageCost)),
                  const SizedBox(width: 12),
                  Expanded(child: _ReadOnlyCost('Last Purchase', _lastPurchaseCost)),
                ]),
              ],
            ),
          ),
        ],
      );

  // ── Section 6: Taxation ────────────────────────────────────────────────────

  Widget _buildTaxation() => _SectionCard(
        title: 'Taxation & Supplier',
        icon:  Icons.receipt_long_outlined,
        children: [
          _TwoCol(
            left: _buildTaxGroupPicker(
              label:    'Sales Tax Group',
              filter:   ['SALES', 'BOTH'],
              value:    _salesTaxId,
              onPicked: (id, name) => setState(() { _salesTaxId = id; _salesTaxDisplay = name; }),
            ),
            right: _buildTaxGroupPicker(
              label:    'Purchase Tax Group',
              filter:   ['PURCHASE', 'BOTH'],
              value:    _purchTaxId,
              onPicked: (id, name) => setState(() { _purchTaxId = id; _purchTaxDisplay = name; }),
            ),
          ),
          const SizedBox(height: 16),
          _TwoCol(
            left: TextFormField(
              controller: _leadTimeCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Lead Time (Days)',
                  hintText:  '0'),
            ),
            right: const SizedBox.shrink(),
          ),
        ],
      );

  Widget _buildTaxGroupPicker({
    required String label,
    required List<String> filter,
    required String? value,
    required void Function(String? id, String? name) onPicked,
  }) {
    final options = _taxGroups
        .where((t) => filter.contains(t.applicableOn))
        .toList();
    return DropdownButtonFormField<String?>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: null, child: Text('— None —')),
        ...options.map((t) => DropdownMenuItem(
            value: t.id, child: Text(t.groupName))),
      ],
      onChanged: (id) {
        final name = id == null
            ? null
            : options.firstWhere((t) => t.id == id).groupName;
        onPicked(id, name);
      },
    );
  }

  // ── Section 7: Physical Dimensions ────────────────────────────────────────

  Widget _buildDimensions() => _SectionCard(
        title: 'Physical Dimensions',
        icon:  Icons.straighten_outlined,
        subtitle: 'Optional — used for shipping calculations and storage planning.',
        children: [
          _TwoCol(
            left: TextFormField(
              controller: _weightCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Weight'),
            ),
            right: DropdownButtonFormField<String?>(
              value: _weightUom,
              decoration: const InputDecoration(labelText: 'Weight Unit'),
              items: const [
                DropdownMenuItem(value: null,  child: Text('—')),
                DropdownMenuItem(value: 'g',   child: Text('Grams (g)')),
                DropdownMenuItem(value: 'kg',  child: Text('Kilograms (kg)')),
                DropdownMenuItem(value: 'lb',  child: Text('Pounds (lb)')),
                DropdownMenuItem(value: 'oz',  child: Text('Ounces (oz)')),
              ],
              onChanged: (v) => setState(() => _weightUom = v),
            ),
          ),
          const SizedBox(height: 16),
          _TwoCol(
            left: TextFormField(
              controller: _volumeCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Volume'),
            ),
            right: DropdownButtonFormField<String?>(
              value: _volumeUom,
              decoration: const InputDecoration(labelText: 'Volume Unit'),
              items: const [
                DropdownMenuItem(value: null,     child: Text('—')),
                DropdownMenuItem(value: 'ml',     child: Text('Millilitres (ml)')),
                DropdownMenuItem(value: 'L',      child: Text('Litres (L)')),
                DropdownMenuItem(value: 'fl_oz',  child: Text('Fluid oz')),
                DropdownMenuItem(value: 'cm3',    child: Text('cm³')),
              ],
              onChanged: (v) => setState(() => _volumeUom = v),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _lengthCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Length'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _widthCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Width'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _heightCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Height'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _dimensionUom,
                  decoration: const InputDecoration(labelText: 'Unit'),
                  items: const [
                    DropdownMenuItem(value: null,   child: Text('—')),
                    DropdownMenuItem(value: 'mm',   child: Text('mm')),
                    DropdownMenuItem(value: 'cm',   child: Text('cm')),
                    DropdownMenuItem(value: 'inch', child: Text('inch')),
                    DropdownMenuItem(value: 'm',    child: Text('m')),
                  ],
                  onChanged: (v) => setState(() => _dimensionUom = v),
                ),
              ),
            ],
          ),
        ],
      );

  // ── Section 8: UOM Levels ──────────────────────────────────────────────────

  Widget _buildUomLevels(bool canSave) => _SectionCard(
        title: 'UOM Levels (Pack Sizes)',
        icon:  Icons.layers_outlined,
        subtitle: 'Add additional pack sizes — e.g. Carton (12 pcs), Pallet. '
            'Each can have its own barcode for scanning.',
        children: [
          if (_uomRows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No UOM levels added yet.',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
            )
          else
            Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(1.5),
                2: FlexColumnWidth(2),
                3: FixedColumnWidth(36),
                4: FixedColumnWidth(36),
                5: FixedColumnWidth(36),
                6: FixedColumnWidth(64),
              },
              children: [
                TableRow(
                  decoration: const BoxDecoration(color: AppColors.surfaceVariant),
                  children: const [
                    _TableHdr('UOM'),
                    _TableHdr('Factor'),
                    _TableHdr('Barcode'),
                    _TableHdr('Base'),
                    _TableHdr('Buy'),
                    _TableHdr('Sell'),
                    _TableHdr(''),
                  ],
                ),
                ..._uomRows.asMap().entries.map((entry) {
                  final i   = entry.key;
                  final row = entry.value;
                  return TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                        child: Text(row.uomName ?? row.uomId,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(row.conversionFactor.toString(),
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(row.barcode ?? '—',
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.textSecondary)),
                      ),
                      _BoolCell(row.isBaseUom),
                      _BoolCell(row.isPurchaseUom),
                      _BoolCell(row.isSalesUom),
                      if (canSave)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              onPressed: () => _addOrEditUomRow(existing: row, index: i),
                              tooltip: 'Edit',
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 16, color: AppColors.negative),
                              onPressed: () => _confirmDeleteUomRow(i),
                              tooltip: 'Remove',
                            ),
                          ],
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  );
                }),
              ],
            ),
          if (canSave) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _addOrEditUomRow(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add UOM Level'),
            ),
          ],
        ],
      );

  void _confirmDeleteUomRow(int index) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove UOM Level'),
        content: const Text('Remove this UOM level? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () { Navigator.pop(ctx, true); },
            child: const Text('Remove', style: TextStyle(color: AppColors.negative)),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) _deleteUomRow(index);
    });
  }

  // ── Section 9: Product Flags ───────────────────────────────────────────────

  Widget _buildFlags() => _SectionCard(
        title: 'Product Flags',
        icon:  Icons.toggle_on_outlined,
        subtitle: 'Configure via Setup › Product Flag Types.',
        children: [
          if (_flagTypes.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'No flag types configured. Go to Setup › Product Flag Types to add flags.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            )
          else
            ...List.generate(_flagTypes.length, (i) {
              final ft   = _flagTypes[i];
              final val  = _flags[ft.flagKey] ?? ft.defaultValue;
              return SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                dense:   true,
                title:   Text(ft.flagLabel,
                    style: const TextStyle(fontSize: 14)),
                value:   val,
                onChanged: (v) => setState(() => _flags[ft.flagKey] = v),
              );
            }),
        ],
      );

  // ── Section 10: Images ─────────────────────────────────────────────────────

  Widget _buildImages(bool canSave) {
    final visible = _mediaItems.where((m) => !m.toDelete).toList();
    return _SectionCard(
      title:    'Product Images',
      icon:     Icons.image_outlined,
      subtitle: 'First image is used as the product thumbnail.',
      children: [
        if (visible.isEmpty && !canSave)
          const Text('No images added.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        if (visible.isNotEmpty)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: List.generate(_mediaItems.length, (idx) {
              final m = _mediaItems[idx];
              if (m.toDelete) return const SizedBox.shrink();
              return _ImageCard(
                base64Data: m.base64Data,
                isPrimary:  m.isPrimary,
                caption:    m.caption,
                canEdit:    canSave,
                onSetPrimary: () => _setPrimaryImage(idx),
                onRemove:     () => _removeImage(idx),
              );
            }),
          ),
        if (canSave && visible.length < 8) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickImage,
            icon:  const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text('Add Image'),
          ),
        ],
      ],
    );
  }
}

// ── UOM Level Dialog ──────────────────────────────────────────────────────────

class _UomLevelDialog extends StatefulWidget {
  final ProductUomModel?        existing;
  final List<CommonMasterModel> uomOptions;
  final UserSession             session;

  const _UomLevelDialog({
    this.existing,
    required this.uomOptions,
    required this.session,
  });

  @override
  State<_UomLevelDialog> createState() => _UomLevelDialogState();
}

class _UomLevelDialogState extends State<_UomLevelDialog> {
  String?  _uomId;
  String?  _uomName;
  final _factorCtrl  = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  bool _isBase     = false;
  bool _isPurchase = false;
  bool _isSales    = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _uomId      = e.uomId;
      _uomName    = e.uomName;
      _factorCtrl.text  = e.conversionFactor.toString();
      _barcodeCtrl.text = e.barcode ?? '';
      _isBase     = e.isBaseUom;
      _isPurchase = e.isPurchaseUom;
      _isSales    = e.isSalesUom;
    } else {
      _factorCtrl.text = '1';
    }
  }

  @override
  void dispose() {
    _factorCtrl.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Add UOM Level' : 'Edit UOM Level'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String?>(
                value: _uomId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Unit of Measure *'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— Select UOM —')),
                  ...widget.uomOptions.map((u) =>
                      DropdownMenuItem(value: u.id, child: Text(u.description))),
                ],
                onChanged: (id) => setState(() {
                  _uomId   = id;
                  _uomName = id == null
                      ? null
                      : widget.uomOptions.firstWhere((u) => u.id == id).description;
                }),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _factorCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Conversion Factor *',
                    helperText: 'How many base units = 1 of this UOM'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _barcodeCtrl,
                decoration: const InputDecoration(
                    labelText: 'Barcode (optional)',
                    helperText: 'Barcode at this pack level'),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Base UOM', style: TextStyle(fontSize: 13)),
                value: _isBase,
                onChanged: (v) => setState(() => _isBase = v ?? false),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Default Purchase UOM',
                    style: TextStyle(fontSize: 13)),
                value: _isPurchase,
                onChanged: (v) => setState(() => _isPurchase = v ?? false),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Default Sales UOM',
                    style: TextStyle(fontSize: 13)),
                value: _isSales,
                onChanged: (v) => setState(() => _isSales = v ?? false),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _uomId == null ? null : _submit,
            child: const Text('Save'),
          ),
        ],
      );

  void _submit() {
    if (_uomId == null) return;
    final factor = double.tryParse(_factorCtrl.text);
    if (factor == null || factor <= 0) return;
    Navigator.pop(
      context,
      ProductUomModel(
        id:               widget.existing?.id,
        clientId:         widget.session.clientId,
        companyId:        widget.session.companyId,
        productId:        widget.existing?.productId,
        uomId:            _uomId!,
        uomName:          _uomName,
        conversionFactor: factor,
        barcode:          _barcodeCtrl.text.trim().isEmpty
            ? null
            : _barcodeCtrl.text.trim(),
        isBaseUom:        _isBase,
        isPurchaseUom:    _isPurchase,
        isSalesUom:       _isSales,
      ),
    );
  }
}

// ── Image card widget ─────────────────────────────────────────────────────────

class _ImageCard extends StatelessWidget {
  final String    base64Data;
  final bool      isPrimary;
  final String    caption;
  final bool      canEdit;
  final VoidCallback onSetPrimary;
  final VoidCallback onRemove;

  const _ImageCard({
    required this.base64Data,
    required this.isPrimary,
    required this.caption,
    required this.canEdit,
    required this.onSetPrimary,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width:  140,
      decoration: BoxDecoration(
        border: Border.all(
            color: isPrimary ? AppColors.primary : AppColors.border,
            width: isPrimary ? 2 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            child: base64Data.isNotEmpty
                ? Image.memory(
                    base64Decode(base64Data),
                    width: 140, height: 110,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image, size: 40, color: AppColors.textSecondary),
                  )
                : const SizedBox(
                    width: 140, height: 110,
                    child: Icon(Icons.image_outlined,
                        size: 40, color: AppColors.textSecondary)),
          ),
          if (isPrimary)
            Container(
              color: AppColors.primary,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: const Text('PRIMARY',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          if (canEdit)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (!isPrimary)
                  IconButton(
                    icon: const Icon(Icons.star_border, size: 16),
                    tooltip: 'Set as primary',
                    onPressed: onSetPrimary,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: AppColors.negative),
                  tooltip: 'Remove',
                  onPressed: onRemove,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ── Internal state model for media ───────────────────────────────────────────

class _MediaEntry {
  final String? id;
  final String  base64Data;
  final String  caption;
  final bool    isPrimary;
  final bool    isNew;
  final bool    toDelete;

  const _MediaEntry({
    this.id,
    required this.base64Data,
    this.caption   = '',
    this.isPrimary = false,
    this.isNew     = false,
    this.toDelete  = false,
  });

  _MediaEntry copyWith({bool? isPrimary, bool? toDelete}) => _MediaEntry(
        id:         id,
        base64Data: base64Data,
        caption:    caption,
        isPrimary:  isPrimary  ?? this.isPrimary,
        isNew:      isNew,
        toDelete:   toDelete   ?? this.toDelete,
      );
}

// ── Layout helpers ────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String       title;
  final IconData     icon;
  final String?      subtitle;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.border)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ]),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      );
}

// Two-column row for form fields
class _TwoCol extends StatelessWidget {
  final Widget left;
  final Widget right;
  const _TwoCol({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    if (Responsive.isMobile(context)) {
      return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [left, const SizedBox(height: 16), right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right),
      ],
    );
  }
}

// Table header cell
class _TableHdr extends StatelessWidget {
  final String text;
  const _TableHdr(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
                letterSpacing: 0.3)),
      );
}

// Boolean check cell for UOM table
class _BoolCell extends StatelessWidget {
  final bool value;
  const _BoolCell(this.value);
  @override
  Widget build(BuildContext context) => Center(
        child: Icon(
          value ? Icons.check : Icons.remove,
          size: 16,
          color: value ? AppColors.positive : AppColors.border,
        ),
      );
}

// Read-only cost display
class _ReadOnlyCost extends StatelessWidget {
  final String label;
  final double value;
  const _ReadOnlyCost(this.label, this.value);
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(value.toStringAsFixed(4),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
        ],
      );
}

// Error banner
class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.negative.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.negative.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.negative, size: 16),
            const SizedBox(width: 8),
            Expanded(
                child: Text(message,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.negative))),
          ],
        ),
      );
}

// Success banner
class _SuccessBanner extends StatelessWidget {
  final String message;
  const _SuccessBanner(this.message);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.positive.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.positive.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                color: AppColors.positive, size: 16),
            const SizedBox(width: 8),
            Expanded(
                child: Text(message,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.positive))),
          ],
        ),
      );
}

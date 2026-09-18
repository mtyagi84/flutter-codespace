import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../data/models/common_master_model.dart';
import '../../data/models/item_category_model.dart';
import '../../data/models/product_model.dart';
import '../providers/products_providers.dart';

class ProductListScreen extends ConsumerStatefulWidget {
  const ProductListScreen({super.key});

  @override
  ConsumerState<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends ConsumerState<ProductListScreen>
    with ScreenPermissionMixin<ProductListScreen>, ScreenHeaderMixin<ProductListScreen> {
  @override
  String get screenName => RouteNames.productMaster;

  @override
  ScreenHeaderInfo buildScreenHeader() {
    final offline = ref.read(sessionProvider)?.offlineMode ?? false;
    return ScreenHeaderInfo(
      title: 'Products',
      subtitle: 'Product and item master',
      actions: [
        if (!offline && canAdd && canExcelUpload) ...[
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton(
              icon: const Icon(Icons.download_outlined, size: 20),
              tooltip: 'Download Template',
              onPressed: _downloadProductsTemplate,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton(
              icon: _uploadingExcel
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file_outlined, size: 20),
              tooltip: 'Upload Excel',
              onPressed: _uploadingExcel ? null : _uploadProductsExcel,
            ),
          ),
        ],
        if (!offline && canAdd)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: () => _openEntry(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Product'),
            ),
          ),
      ],
    );
  }

  final _searchCtrl = TextEditingController();
  String  _search   = '';
  String? _nature;          // null = all
  bool?   _activeFilter;   // null = all

  List<ProductModel> _products  = [];
  bool    _loading   = true;
  bool    _loadingMore = false;
  bool    _hasMore   = true;
  String? _error;

  static const _pageSize = 50;
  int _offset = 0;
  bool _uploadingExcel = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final v = _searchCtrl.text.trim();
      if (v != _search) {
        _search = v;
        _reload();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _offset   = 0;
    _hasMore  = true;
    _products = [];
    await _load();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    if (mounted) setState(() { _loading = _offset == 0; _error = null; });
    try {
      final repo = ref.read(productsRepositoryProvider);
      final rows = await repo.getProducts(
        clientId:  session.clientId,
        companyId: session.companyId,
        search:    _search.isEmpty ? null : _search,
        nature:    _nature,
        isActive:  _activeFilter,
        limit:     _pageSize,
        offset:    _offset,
      );
      if (mounted) {
        setState(() {
          if (_offset == 0) {
            _products = rows;
          } else {
            _products = [..._products, ...rows];
          }
          _hasMore     = rows.length == _pageSize;
          _loading     = false;
          _loadingMore = false;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _loading     = false;
          _loadingMore = false;
          _error = e.response?.data?['message'] as String? ?? 'Failed to load products.';
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() { _loadingMore = true; });
    _offset += _pageSize;
    await _load();
  }

  Future<void> _openEntry({String? productId}) async {
    await context.push(RouteNames.productEntry,
        extra: productId != null ? {'productId': productId} : null);
    if (mounted) _reload();
  }

  // ── Bulk Excel upload — new products only, one product code per row ───────
  // Category/Sub Category/Unit/Brand are all resolved by NAME against
  // already-existing masters (created one-by-one first via their own
  // screens) — an unresolved name skips the row with an error, same
  // deferred-validation convention as every other upload in this app.
  // Every lookup is normalized (trim + uppercase) on both sides, since a
  // real duplicate-category bug (stray whitespace/case differences) was
  // found in the first real tenant's own source data.
  static const _uploadHeaders = [
    'Product Name', 'Category', 'Sub Category', 'Unit', 'Initial Cost', 'Brand',
  ];

  String _norm(String s) => s.trim().toUpperCase();

  Future<void> _downloadProductsTemplate() async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    sheet.appendRow(_uploadHeaders.map((h) => xls.TextCellValue(h)).toList());
    final bytes = workbook.encode();
    if (bytes == null) return;
    await _saveWorkbookBytes(bytes, 'product_master_template.xlsx', 'Save Product Master template');
  }

  Future<void> _saveWorkbookBytes(List<int> bytes, String filename, String dialogTitle) async {
    if (kIsWeb) {
      downloadBytesOnWeb(bytes, filename);
      return;
    }
    await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: filename,
      bytes: Uint8List.fromList(bytes),
      type: FileType.custom, allowedExtensions: ['xlsx'],
    );
  }

  Future<void> _uploadProductsExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['xlsx'], withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) {
      if (mounted) _showUploadSnack('Could not read the selected file.', AppColors.negative);
      return;
    }

    setState(() => _uploadingExcel = true);
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) { _showUploadSnack('The file has no sheets.', AppColors.negative); return; }
      final sheet = workbook.tables[workbook.tables.keys.first]!;
      if (sheet.maxRows < 2) { _showUploadSnack('No data rows found below the header.', AppColors.negative); return; }

      final session = ref.read(sessionProvider)!;
      final repo = ref.read(productsRepositoryProvider);

      final categories = await repo.getCategories(clientId: session.clientId, companyId: session.companyId);
      final masterSets = await repo.loadMasterSets(clientId: session.clientId, companyId: session.companyId);
      final brands = masterSets['BRAND'] ?? const [];
      final units  = masterSets['UNIT']  ?? const [];

      // Level-1 categories by normalized name; level-2 (sub) categories by
      // normalized name SCOPED to their level-1 parent (two products in
      // different top-level groups can legitimately share a sub-category
      // name, e.g. "Angles" under two different steel-shape groups).
      final level1ByName = <String, ItemCategoryModel>{
        for (final c in categories) if (c.levelNo == 1) _norm(c.categoryName): c,
      };
      final level2ByParentAndName = <String, ItemCategoryModel>{
        for (final c in categories) if (c.levelNo == 2) '${c.parentId}|${_norm(c.categoryName)}': c,
      };
      final brandByName = <String, CommonMasterModel>{ for (final b in brands) _norm(b.description): b };
      final unitByName  = <String, CommonMasterModel>{ for (final u in units)  _norm(u.description): u };

      final startingCode = await repo.generateProductCode(clientId: session.clientId, companyId: session.companyId);
      final startingNum = int.tryParse(startingCode.replaceAll('PRD-', '')) ?? 1;

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxName    = col('product name');
      final idxCat     = col('category');
      final idxSubCat  = col('sub category');
      final idxUnit    = col('unit');
      final idxCost    = col('initial cost');
      final idxBrand   = col('brand');

      if (idxName == -1 || idxUnit == -1) {
        _showUploadSnack('Missing required column(s): Product Name, Unit.', AppColors.negative);
        return;
      }

      String cellStr(List<xls.Data?> row, int idx) =>
          (idx == -1 || idx >= row.length) ? '' : (row[idx]?.value?.toString().trim() ?? '');

      var nextNum = startingNum;
      var created = 0;
      final errors = <String>[];

      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        final name = cellStr(row, idxName);
        if (name.isEmpty) continue;

        final unitName = cellStr(row, idxUnit);
        final unit = unitByName[_norm(unitName)];
        if (unit == null) { errors.add('Row ${r + 1}: unit "$unitName" not found.'); continue; }

        String? categoryId;
        final catName = cellStr(row, idxCat);
        if (catName.isNotEmpty) {
          final level1 = level1ByName[_norm(catName)];
          if (level1 == null) { errors.add('Row ${r + 1}: category "$catName" not found.'); continue; }
          categoryId = level1.id;
          final subCatName = cellStr(row, idxSubCat);
          if (subCatName.isNotEmpty) {
            final level2 = level2ByParentAndName['${level1.id}|${_norm(subCatName)}'];
            if (level2 == null) { errors.add('Row ${r + 1}: sub category "$subCatName" not found under "$catName".'); continue; }
            categoryId = level2.id;
          }
        }

        final brandName = cellStr(row, idxBrand);
        final brand = brandName.isEmpty ? null : brandByName[_norm(brandName)];
        if (brandName.isNotEmpty && brand == null) { errors.add('Row ${r + 1}: brand "$brandName" not found.'); continue; }

        final costStr = idxCost == -1 ? '' : cellStr(row, idxCost);
        final cost = double.tryParse(costStr) ?? 0;

        final productId = const Uuid().v4();
        final code = 'PRD-${nextNum.toString().padLeft(5, '0')}';
        nextNum++;

        try {
          await repo.saveProduct({
            'id':             productId,
            'client_id':      session.clientId,
            'company_id':     session.companyId,
            'product_code':   code,
            'product_name':   name,
            'product_nature': 'TRADING',
            if (categoryId != null) 'category_id': categoryId,
            if (brand != null)      'brand_id':    brand.id,
            'base_uom_id':    unit.id,
            'standard_cost':  cost,
            'tracking_type':  'NONE',
            'is_active':      true,
            'created_by':     session.userId,
          }, isNew: true);
          await repo.saveProductUom({
            'client_id':  session.clientId,
            'company_id': session.companyId,
            'product_id': productId,
            'uom_id':     unit.id,
            'conversion_factor': 1,
            'is_base_uom': true,
            'is_purchase_uom': true,
            'is_sales_uom': true,
            'sort_order': 0,
          });
          created++;
        } catch (e) {
          errors.add('Row ${r + 1} ("$name"): ${ErrorPresenter.format(e, action: "create this product")}');
        }
      }

      if (created > 0) await _reload();

      if (!mounted) return;
      if (errors.isNotEmpty) {
        _showUploadSnack('$created product(s) created, ${errors.length} row(s) skipped.', Colors.orange);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Rows skipped'),
            content: SizedBox(width: 420, height: 320, child: SingleChildScrollView(child: Text(errors.join('\n')))),
            actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('OK'))],
          ),
        );
      } else {
        _showUploadSnack('$created product(s) created.', AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('ProductMasterExcelUpload', e, st);
      if (mounted) _showUploadSnack(ErrorPresenter.format(e, action: 'upload this Excel file'), AppColors.negative);
    } finally {
      if (mounted) setState(() => _uploadingExcel = false);
    }
  }

  void _showUploadSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    // Title/subtitle/New-Product button live in the shared TopBar via
    // ScreenHeaderMixin — not rendered here as body content.
    refreshScreenHeader();

    return Column(
      children: [
        const OfflineBanner(),
        // ── Toolbar ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            children: [
              // Search + filters — the two dropdowns + refresh button are
              // fixed-intrinsic-width siblings of the search field's own
              // Expanded; on mobile their combined width doesn't leave room
              // for the search field's own minimum content width, so the
              // Row overflows. Stack search above a wrapped filter row on
              // mobile instead of forcing everything onto one line.
              if (Responsive.isMobile(context)) ...[
                _buildSearchField(),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _NatureFilter(
                      value: _nature,
                      onChanged: (v) { _nature = v; _reload(); },
                    ),
                    _ActiveFilter(
                      value: _activeFilter,
                      onChanged: (v) { _activeFilter = v; _reload(); },
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: _loading ? null : _reload,
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Expanded(child: _buildSearchField()),
                    const SizedBox(width: 10),
                    _NatureFilter(
                      value: _nature,
                      onChanged: (v) { _nature = v; _reload(); },
                    ),
                    const SizedBox(width: 8),
                    _ActiveFilter(
                      value: _activeFilter,
                      onChanged: (v) { _activeFilter = v; _reload(); },
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Refresh',
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: _loading ? null : _reload,
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // ── Body ─────────────────────────────────────────────────────────────
        Expanded(
          child: _error != null
              ? _buildError()
              : Column(children: [
                  Expanded(
                    child: SakalAdaptiveList<ProductModel>(
                      loading: _loading,
                      error: null,
                      rows: _products,
                      columns: const [
                        SakalListColumn('Code', flex: 2),
                        SakalListColumn('Product Name', flex: 3),
                        SakalListColumn('Nature', flex: 2),
                        SakalListColumn('Category', flex: 2),
                        SakalListColumn('Base UOM', flex: 1),
                        SakalListColumn('Active', flex: 1),
                      ],
                      rowBuilder: (p, i) => _buildTableRow(p),
                      cardBuilder: (p) => _ProductCard(
                          product: p, onTap: () => _openEntry(productId: p.id)),
                      emptyState: _buildEmpty(),
                    ),
                  ),
                  if (_hasMore && !_loading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: _loadingMore
                            ? const CircularProgressIndicator()
                            : OutlinedButton(
                                onPressed: _loadMore,
                                child: const Text('Load More'),
                              ),
                      ),
                    ),
                ]),
        ),
      ],
    );
  }

  Widget _buildSearchField() => SakalFieldCard(
        label: 'Search',
        editable: true,
        child: TextField(
          controller: _searchCtrl,
          style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
          decoration: SakalFieldCard.bareDecoration.copyWith(
            hintText: 'Search by code or name…',
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
            prefixIcon: const Icon(Icons.search, size: 16),
            suffixIcon: _search.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () { _searchCtrl.clear(); })
                : null,
          ),
        ),
      );

  Widget _buildError() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.negative, size: 40),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.negative)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );

  Widget _buildEmpty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined,
                size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              _search.isNotEmpty || _nature != null || _activeFilter != null
                  ? 'No products match the current filter.'
                  : 'No products yet.',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary),
            ),
            if (_search.isEmpty && _nature == null && canAdd) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _openEntry(),
                icon: const Icon(Icons.add),
                label: const Text('Add First Product'),
              ),
            ],
          ],
        ),
      );

  // ── Desktop table row (SakalAdaptiveList owns the loading/error/empty +
  // mobile-card/desktop-table switch and its own header; this only builds
  // one row's content, matching the column flex spec passed to it) ────────

  Widget _buildTableRow(ProductModel p) => InkWell(
        onTap: () => _openEntry(productId: p.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 2,
                child: Text(p.productCode,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.productName,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    if (p.shortName != null)
                      Text(p.shortName!,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Expanded(flex: 2, child: _NatureBadge(p.productNature)),
              Expanded(
                flex: 2,
                child: Text(
                  p.categoryName ?? '—',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(p.baseUomName ?? '—', style: const TextStyle(fontSize: 13)),
              ),
              Expanded(
                flex: 1,
                child: Icon(
                  p.isActive ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 18,
                  color: p.isActive ? AppColors.positive : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
}

// ── Mobile card ───────────────────────────────────────────────────────────────

class _ProductCard extends StatelessWidget {
  final ProductModel product;
  final VoidCallback onTap;
  const _ProductCard({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Nature colour strip
                Container(
                  width: 4,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _natureColor(product.productNature),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(product.productCode,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary)),
                          _NatureBadge(product.productNature),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(product.productName,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500)),
                      if (product.categoryName != null)
                        Text(product.categoryName!,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    size: 20, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      );

  static Color _natureColor(String nature) {
    switch (nature) {
      case 'SERVICE':       return AppColors.natureService;
      case 'RAW_MATERIAL':  return AppColors.natureRaw;
      case 'FINISHED_GOOD': return AppColors.positive;
      case 'PACKAGING':     return AppColors.naturePackaging;
      default:              return AppColors.primary;
    }
  }
}

// ── Nature badge ──────────────────────────────────────────────────────────────

class _NatureBadge extends StatelessWidget {
  final String nature;
  const _NatureBadge(this.nature);

  @override
  Widget build(BuildContext context) {
    final label = ProductModel.natureLabels[nature] ?? nature;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _bg(),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _fg())),
    );
  }

  Color _bg() {
    switch (nature) {
      case 'SERVICE':       return AppColors.natureServiceBg;
      case 'RAW_MATERIAL':  return AppColors.natureRawBg;
      case 'FINISHED_GOOD': return AppColors.natureFinishedBg;
      case 'PACKAGING':     return AppColors.naturePackagingBg;
      case 'CONSUMABLE':    return AppColors.natureConsumableBg;
      default:              return AppColors.surfaceVariant;
    }
  }

  Color _fg() {
    switch (nature) {
      case 'SERVICE':       return AppColors.natureService;
      case 'RAW_MATERIAL':  return AppColors.natureRaw;
      case 'FINISHED_GOOD': return AppColors.positive;
      case 'PACKAGING':     return AppColors.naturePackaging;
      case 'CONSUMABLE':    return AppColors.natureConsumable;
      default:              return AppColors.primary;
    }
  }
}

// ── Filter widgets ────────────────────────────────────────────────────────────

class _NatureFilter extends StatelessWidget {
  final String?               value;
  final ValueChanged<String?> onChanged;
  const _NatureFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButton<String?>(
            value:    value,
            hint:     const Text('All Types',
                          style: TextStyle(fontSize: 13)),
            isDense:  true,
            onChanged: onChanged,
            items: [
              const DropdownMenuItem(value: null, child: Text('All Types')),
              ...ProductModel.natureLabels.entries.map((e) =>
                  DropdownMenuItem(value: e.key, child: Text(e.value))),
            ],
          ),
        ),
      );
}

class _ActiveFilter extends StatelessWidget {
  final bool?               value;
  final ValueChanged<bool?> onChanged;
  const _ActiveFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButton<bool?>(
            value:    value,
            isDense:  true,
            onChanged: onChanged,
            items: const [
              DropdownMenuItem(value: null,  child: Text('All Status')),
              DropdownMenuItem(value: true,  child: Text('Active')),
              DropdownMenuItem(value: false, child: Text('Inactive')),
            ],
          ),
        ),
      );
}

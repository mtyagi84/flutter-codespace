import 'dart:typed_data';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/config/master_type_keys.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../../../core/widgets/sakal_scrollable_table.dart';
import '../../../../core/widgets/sakal_table_header_bar.dart';
import '../../data/models/common_master_model.dart';
import '../../data/models/item_category_model.dart';
import '../../data/models/product_model.dart';
import '../../data/models/tax_group_model.dart';
import '../providers/item_categories_providers.dart';
import '../providers/products_providers.dart';

/// Bulk Upload Products — a dedicated masters-adjacent screen (route
/// /master/bulk-upload-products, feature MST-BUP, Inventory Masters group)
/// distinct from the single-product entry screen. Unlike a plain "upload
/// and hope the masters already exist" import, this screen auto-creates
/// whatever Category/Sub-Category/Item Size/Item Color/Brand/Unit master
/// data a row needs — a Data Operator never has to stop mid-upload to go
/// set up a master by hand first. Tax Groups are the one deliberate
/// exception (see _resolveTaxGroups' own comment): they can't be
/// meaningfully synthesized from a bare name.
class BulkUploadProductsScreen extends ConsumerStatefulWidget {
  const BulkUploadProductsScreen({super.key});

  @override
  ConsumerState<BulkUploadProductsScreen> createState() => _BulkUploadProductsScreenState();
}

const _natureOptions = ['TRADING', 'FINISHED_GOOD', 'RAW_MATERIAL', 'PACKAGING', 'CONSUMABLE', 'SERVICE'];

class _BulkRow implements DisposableRow {
  final nameCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  String nature = 'TRADING';
  final hsnCtrl = TextEditingController();
  final cat1Ctrl = TextEditingController();
  final cat2Ctrl = TextEditingController();
  final cat3Ctrl = TextEditingController();
  final cat4Ctrl = TextEditingController();
  final sizeCtrl = TextEditingController();
  final colorCtrl = TextEditingController();
  final brandCtrl = TextEditingController();
  final unitCtrl = TextEditingController();
  final costCtrl = TextEditingController(text: '0');
  final currencyCtrl = TextEditingController();
  final varianceCtrl = TextEditingController(text: '0');
  final salesTaxCtrl = TextEditingController();
  final purchTaxCtrl = TextEditingController();

  @override
  void dispose() {
    for (final c in [nameCtrl, descCtrl, hsnCtrl, cat1Ctrl, cat2Ctrl, cat3Ctrl, cat4Ctrl,
        sizeCtrl, colorCtrl, brandCtrl, unitCtrl, costCtrl, currencyCtrl, varianceCtrl,
        salesTaxCtrl, purchTaxCtrl]) {
      c.dispose();
    }
  }
}

class _BulkUploadProductsScreenState extends ConsumerState<BulkUploadProductsScreen>
    with
        ScreenPermissionMixin<BulkUploadProductsScreen>,
        ScreenHeaderMixin<BulkUploadProductsScreen>,
        DeferredRowDisposal<BulkUploadProductsScreen> {
  @override
  String get screenName => RouteNames.bulkUploadProducts;

  List<_BulkRow> _lines = [];
  bool _uploadingExcel = false;
  bool _saving = false;

  static const _uploadHeaders = [
    'Product Name', 'Description', 'Product Nature', 'HSN/SAC Code',
    'Category L1', 'Category L2', 'Category L3', 'Category L4',
    'Item Size', 'Item Color', 'Brand', 'Unit of Measure', 'Unit Cost',
    'Maintain Price In', 'Allowed Cost Variance %', 'Sales Tax Group', 'Purchase Tax Group',
  ];

  String _norm(String s) => s.trim().toUpperCase();

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    disposeDeferredRows();
    super.dispose();
  }

  void _addLine() => setState(() => _lines.add(_BulkRow()));

  void _removeLine(_BulkRow row) {
    setState(() => _lines.remove(row));
    deferRowDisposal(row);
  }

  // ── Template / Upload ──────────────────────────────────────────────────

  Future<void> _downloadTemplate() async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    sheet.appendRow(_uploadHeaders.map((h) => xls.TextCellValue(h)).toList());
    final bytes = workbook.encode();
    if (bytes == null) return;
    await _saveWorkbookBytes(bytes, 'bulk_upload_products_template.xlsx', 'Save Bulk Upload Products template');
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

  Future<void> _uploadExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['xlsx'], withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) {
      _showSnack('Could not read the selected file.', AppColors.negative);
      return;
    }

    setState(() => _uploadingExcel = true);
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) { _showSnack('The file has no sheets.', AppColors.negative); return; }
      final sheet = workbook.tables[workbook.tables.keys.first]!;
      if (sheet.maxRows < 2) { _showSnack('No data rows found below the header.', AppColors.negative); return; }

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxName    = col('product name');
      final idxDesc    = col('description');
      final idxNature  = col('product nature');
      final idxHsn     = col('hsn/sac code');
      final idxCat1    = col('category l1');
      final idxCat2    = col('category l2');
      final idxCat3    = col('category l3');
      final idxCat4    = col('category l4');
      final idxSize    = col('item size');
      final idxColor   = col('item color');
      final idxBrand   = col('brand');
      final idxUnit    = col('unit of measure');
      final idxCost    = col('unit cost');
      final idxCurrency = col('maintain price in');
      final idxVariance = col('allowed cost variance %');
      final idxSalesTax = col('sales tax group');
      final idxPurchTax = col('purchase tax group');

      if (idxName == -1 || idxUnit == -1) {
        _showSnack('Missing required column(s): Product Name, Unit of Measure.', AppColors.negative);
        return;
      }

      String cellStr(List<xls.Data?> row, int idx) =>
          (idx == -1 || idx >= row.length) ? '' : (row[idx]?.value?.toString().trim() ?? '');

      // Replace, not append — this template is upload-only (no round-trip
      // export like Opening Balance's own re-fillable template), matching
      // Opening Stock's simpler blank-shell convention. Minimal validation
      // here (required columns only) — everything else is deferred to
      // Save, same as every other upload in this app: the user reviews and
      // edits the loaded grid before anything is actually created.
      final parsed = <_BulkRow>[];
      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        final name = cellStr(row, idxName);
        if (name.isEmpty) continue;
        final line = _BulkRow();
        line.nameCtrl.text = name;
        line.descCtrl.text = idxDesc == -1 ? '' : cellStr(row, idxDesc);
        final rawNature = idxNature == -1 ? '' : cellStr(row, idxNature).toUpperCase();
        line.nature = _natureOptions.contains(rawNature) ? rawNature : 'TRADING';
        line.hsnCtrl.text = idxHsn == -1 ? '' : cellStr(row, idxHsn);
        line.cat1Ctrl.text = idxCat1 == -1 ? '' : cellStr(row, idxCat1);
        line.cat2Ctrl.text = idxCat2 == -1 ? '' : cellStr(row, idxCat2);
        line.cat3Ctrl.text = idxCat3 == -1 ? '' : cellStr(row, idxCat3);
        line.cat4Ctrl.text = idxCat4 == -1 ? '' : cellStr(row, idxCat4);
        line.sizeCtrl.text = idxSize == -1 ? '' : cellStr(row, idxSize);
        line.colorCtrl.text = idxColor == -1 ? '' : cellStr(row, idxColor);
        line.brandCtrl.text = idxBrand == -1 ? '' : cellStr(row, idxBrand);
        line.unitCtrl.text = cellStr(row, idxUnit);
        final costStr = idxCost == -1 ? '' : cellStr(row, idxCost);
        line.costCtrl.text = costStr.isEmpty ? '0' : costStr;
        line.currencyCtrl.text = idxCurrency == -1 ? '' : cellStr(row, idxCurrency);
        final varStr = idxVariance == -1 ? '' : cellStr(row, idxVariance);
        line.varianceCtrl.text = varStr.isEmpty ? '0' : varStr;
        line.salesTaxCtrl.text = idxSalesTax == -1 ? '' : cellStr(row, idxSalesTax);
        line.purchTaxCtrl.text = idxPurchTax == -1 ? '' : cellStr(row, idxPurchTax);
        parsed.add(line);
      }

      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() => _lines = parsed);
      _showSnack('${parsed.length} row(s) loaded from Excel. Review below, then Save.', AppColors.positive);
    } catch (e, st) {
      AppLogger.error('BulkUploadProductsExcelUpload', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'upload this Excel file'), AppColors.negative);
    } finally {
      if (mounted) setState(() => _uploadingExcel = false);
    }
  }

  // ── Save — the full per-row pipeline ────────────────────────────────────

  Future<void> _save() async {
    if (_lines.isEmpty) {
      _showSnack('Upload a file or add at least one row first.', AppColors.negative);
      return;
    }
    setState(() => _saving = true);
    final session = ref.read(sessionProvider)!;
    final productsRepo  = ref.read(productsRepositoryProvider);
    final categoriesRepo = ref.read(itemCategoriesRepositoryProvider);

    try {
      // ── 1. Fetch once, up front ─────────────────────────────────────────
      final existingProducts = await DioClient.instance.get('/rim_products', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'select': 'product_name', 'limit': '20000',
      });
      final existingNames = <String>{
        for (final p in (existingProducts.data as List)) _norm((p as Map<String, dynamic>)['product_name'] as String),
      };

      // Categories/common masters fetched REGARDLESS of is_deleted — a
      // plain (non-partial) UNIQUE constraint on both tables means a
      // soft-deleted row with the same name must be found and REUSED
      // (undeleted), never re-inserted, or the insert 409s.
      final allCategoriesRes = await DioClient.instance.get('/rim_item_categories', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}', 'limit': '5000',
      });
      final categories = (allCategoriesRes.data as List)
          .map((e) => ItemCategoryModel.fromJson(e as Map<String, dynamic>)).toList();

      final typesRes = await DioClient.instance.get('/rim_common_master_types', queryParameters: {
        'type_key': 'in.(${MasterTypeKey.brand},${MasterTypeKey.unit},${MasterTypeKey.itemSize},${MasterTypeKey.color})',
        'select': 'id,type_key',
      });
      final typeIdByKey = <String, String>{
        for (final t in (typesRes.data as List)) (t as Map<String, dynamic>)['type_key'] as String: t['id'] as String,
      };
      final allMastersRes = await DioClient.instance.get('/rim_common_masters', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'type_id': 'in.(${typeIdByKey.values.join(',')})', 'limit': '5000',
      });
      final allMasters = (allMastersRes.data as List)
          .map((e) => CommonMasterModel.fromJson(e as Map<String, dynamic>)).toList();

      final taxGroups = await productsRepo.getTaxGroups(clientId: session.clientId, companyId: session.companyId);
      final baseCurrencies = await productsRepo.getCurrencies(session.clientId);

      var flagTypes = await categoriesRepo.getFlagTypes(clientId: session.clientId, companyId: session.companyId);
      if (flagTypes.isEmpty) {
        await categoriesRepo.loadDefaultFlags(clientId: session.clientId, companyId: session.companyId);
        flagTypes = await categoriesRepo.getFlagTypes(clientId: session.clientId, companyId: session.companyId);
      }
      final defaultFlags = { for (final f in flagTypes) f.flagKey: f.defaultValue };

      var categoryLevels = await categoriesRepo.getLevels(clientId: session.clientId, companyId: session.companyId);

      // Base currency — "Maintain Price In" defaults here when blank.
      final companyRes = await DioClient.instance.get('/ric_companies', queryParameters: {
        'id': 'eq.${session.companyId}', 'select': 'base_currency', 'limit': '1',
      });
      final baseCurrencyCode = (companyRes.data as List).isNotEmpty
          ? ((companyRes.data as List).first as Map<String, dynamic>)['base_currency'] as String? : null;
      final baseCurrencyRow = baseCurrencies.firstWhere(
        (c) => c['currency_id'] == baseCurrencyCode, orElse: () => const {});
      final baseCurrencyId = baseCurrencyRow['id'] as String?;

      // Mutable, in-memory caches — updated as this run creates/reuses
      // masters, so row 2 sees what row 1 just created without a re-fetch.
      final categoriesByKey = <String, ItemCategoryModel>{
        for (final c in categories) '${c.parentId}|${c.levelNo}|${_norm(c.categoryName)}': c,
      };
      final mastersByKey = <String, CommonMasterModel>{
        for (final m in allMasters) '${m.typeId}|${_norm(m.description)}': m,
      };
      final levelLabelSet = { for (final l in categoryLevels) l.levelNo };
      final taxGroupByKey = <String, TaxGroupModel>{
        for (final g in taxGroups) if (!g.isDeleted && g.isActive) '${_norm(g.groupName)}|${g.applicableOn}': g,
      };

      final createdCategoryIds = <String>{};
      final createdMasterIds = <String>{};
      final committedNamesThisRun = <String>{};
      final rowErrors = <String>[];
      final unmatchedTaxRows = <_BulkRow>[]; // rows with >=1 unmatched tax group name
      final readyRows = <_BulkRow>[];
      final resolvedByRow = <_BulkRow, Map<String, dynamic>>{};

      // ── 2. Per-row resolution (no commits yet) ──────────────────────────
      for (final row in _lines) {
        final name = row.nameCtrl.text.trim();
        if (name.isEmpty) continue;
        final normName = _norm(name);
        if (existingNames.contains(normName) || !committedNamesThisRun.add(normName)) {
          rowErrors.add('"$name": a product with this name already exists (or is duplicated in this file).');
          continue;
        }

        final unitName = row.unitCtrl.text.trim();
        if (unitName.isEmpty) { rowErrors.add('"$name": Unit of Measure is required.'); continue; }
        final unit = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.unit]!, unitName, mastersByKey, createdMasterIds, session,
        );

        // Category chain L1..L4 — L1 required if ANY level given; a gap
        // (L3 given but L2 blank) is a row error, not a silent skip-ahead.
        String? categoryId;
        final catNames = [row.cat1Ctrl.text.trim(), row.cat2Ctrl.text.trim(), row.cat3Ctrl.text.trim(), row.cat4Ctrl.text.trim()];
        if (catNames.any((c) => c.isNotEmpty)) {
          if (catNames[0].isEmpty) { rowErrors.add('"$name": Category L1 is required when any category level is given.'); continue; }
          String? parentId;
          var gapFound = false;
          for (var lvl = 0; lvl < 4; lvl++) {
            final cName = catNames[lvl];
            if (cName.isEmpty) {
              if (catNames.sublist(lvl + 1).any((c) => c.isNotEmpty)) {
                rowErrors.add('"$name": Category L${lvl + 1} is blank but a deeper level is given.');
                gapFound = true;
              }
              break;
            }
            final cat = await _resolveOrCreateCategory(
              parentId, lvl + 1, cName, categoriesByKey, createdCategoryIds, levelLabelSet, session,
            );
            categoryId = cat.id;
            parentId = cat.id;
          }
          if (gapFound) continue;
        }

        final size = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.itemSize]!,
          row.sizeCtrl.text.trim().isEmpty ? 'N/A' : row.sizeCtrl.text.trim(),
          mastersByKey, createdMasterIds, session,
        );
        final color = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.color]!,
          row.colorCtrl.text.trim().isEmpty ? 'N/A' : row.colorCtrl.text.trim(),
          mastersByKey, createdMasterIds, session,
        );
        final brand = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.brand]!,
          row.brandCtrl.text.trim().isEmpty ? 'N/A' : row.brandCtrl.text.trim(),
          mastersByKey, createdMasterIds, session,
        );

        String? costCurrencyId = baseCurrencyId;
        final currencyName = row.currencyCtrl.text.trim();
        if (currencyName.isNotEmpty) {
          final match = baseCurrencies.firstWhere(
            (c) => _norm(c['currency_id'] as String? ?? '') == _norm(currencyName), orElse: () => const {});
          if (match['id'] == null) { rowErrors.add('"$name": currency "$currencyName" not found.'); continue; }
          costCurrencyId = match['id'] as String;
        }

        String? salesTaxId;
        final salesTaxName = row.salesTaxCtrl.text.trim();
        var hasUnmatchedTax = false;
        if (salesTaxName.isNotEmpty) {
          final g = taxGroupByKey['${_norm(salesTaxName)}|SALES'] ?? taxGroupByKey['${_norm(salesTaxName)}|BOTH'];
          if (g == null) { hasUnmatchedTax = true; } else { salesTaxId = g.id; }
        }
        String? purchTaxId;
        final purchTaxName = row.purchTaxCtrl.text.trim();
        if (purchTaxName.isNotEmpty) {
          final g = taxGroupByKey['${_norm(purchTaxName)}|PURCHASE'] ?? taxGroupByKey['${_norm(purchTaxName)}|BOTH'];
          if (g == null) { hasUnmatchedTax = true; } else { purchTaxId = g.id; }
        }

        resolvedByRow[row] = {
          'name': name, 'description': row.descCtrl.text.trim().nullIfEmptyB,
          'nature': row.nature, 'hsn': row.hsnCtrl.text.trim().nullIfEmptyB,
          'category_id': categoryId, 'size_id': size.id, 'color_id': color.id, 'brand_id': brand.id,
          'unit_id': unit.id, 'cost': double.tryParse(row.costCtrl.text.trim()) ?? 0,
          'cost_currency_id': costCurrencyId,
          'variance': double.tryParse(row.varianceCtrl.text.trim()) ?? 0,
          'sales_tax_id': salesTaxId, 'purch_tax_id': purchTaxId,
          'sales_tax_name': salesTaxName, 'purch_tax_name': purchTaxName,
        };
        if (hasUnmatchedTax) {
          unmatchedTaxRows.add(row);
        } else {
          readyRows.add(row);
        }
      }

      // ── 3. Batch tax-group confirmation ──────────────────────────────────
      var dropUnmatchedTaxRows = true;
      if (unmatchedTaxRows.isNotEmpty && mounted) {
        final missingNames = <String>{};
        for (final row in unmatchedTaxRows) {
          final r = resolvedByRow[row]!;
          if (r['sales_tax_id'] == null && (r['sales_tax_name'] as String).isNotEmpty) missingNames.add(r['sales_tax_name'] as String);
          if (r['purch_tax_id'] == null && (r['purch_tax_name'] as String).isNotEmpty) missingNames.add(r['purch_tax_name'] as String);
        }
        final choice = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: const Text('Some Tax Groups don\'t exist yet'),
            content: SizedBox(
              width: 440,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${unmatchedTaxRows.length} row(s) reference a Tax Group that doesn\'t exist:'),
                const SizedBox(height: 8),
                ...missingNames.map((n) => Text('• $n', style: const TextStyle(fontWeight: FontWeight.w600))),
                const SizedBox(height: 12),
                const Text('Tax Groups can\'t be auto-created (they need real tax rates and GL accounts set up first via Tax Master). What should happen to these rows?'),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Skip these rows')),
              FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Create anyway, no tax')),
            ],
          ),
        );
        dropUnmatchedTaxRows = choice ?? true;
      }

      final toCommit = [...readyRows];
      if (!dropUnmatchedTaxRows) {
        toCommit.addAll(unmatchedTaxRows);
      } else {
        for (final row in unmatchedTaxRows) {
          final r = resolvedByRow[row]!;
          rowErrors.add('"${r['name']}": skipped — unmatched Tax Group ("${r['sales_tax_name']}"/"${r['purch_tax_name']}").');
        }
      }

      // ── 4. Commit ────────────────────────────────────────────────────────
      var created = 0;
      for (final row in toCommit) {
        final r = resolvedByRow[row]!;
        final productId = const Uuid().v4();
        final code = await productsRepo.generateProductCode(clientId: session.clientId, companyId: session.companyId);
        try {
          await productsRepo.saveProduct({
            'id': productId, 'client_id': session.clientId, 'company_id': session.companyId,
            'product_code': code, 'product_name': r['name'],
            if (r['description'] != null) 'description': r['description'],
            'product_nature': r['nature'],
            if (r['hsn'] != null) 'hsn_sac_code': r['hsn'],
            if (r['category_id'] != null) 'category_id': r['category_id'],
            'item_size_id': r['size_id'], 'item_color_id': r['color_id'], 'brand_id': r['brand_id'],
            'base_uom_id': r['unit_id'], 'standard_cost': r['cost'],
            if (r['cost_currency_id'] != null) 'cost_currency_id': r['cost_currency_id'],
            'allowed_cost_variance': r['variance'],
            if (r['sales_tax_id'] != null) 'sales_tax_group_id': r['sales_tax_id'],
            if (r['purch_tax_id'] != null) 'purchase_tax_group_id': r['purch_tax_id'],
            'tracking_type': 'NONE', 'is_active': true, 'flags': defaultFlags,
            'created_by': session.userId,
          }, isNew: true);
          await productsRepo.saveProductUom({
            'client_id': session.clientId, 'company_id': session.companyId, 'product_id': productId,
            'uom_id': r['unit_id'], 'conversion_factor': 1,
            'is_base_uom': true, 'is_purchase_uom': true, 'is_sales_uom': true, 'sort_order': 0,
          });
          created++;
        } catch (e) {
          rowErrors.add('"${r['name']}": ${ErrorPresenter.format(e, action: "create this product")}');
        }
      }

      // ── 5. Cleanup — soft-delete any auto-created master this run left
      // completely unreferenced (e.g. its own row later errored out) ──────
      var cleanedUp = 0;
      if (createdCategoryIds.isNotEmpty || createdMasterIds.isNotEmpty) {
        final refsRes = await DioClient.instance.get('/rim_products', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'select': 'category_id,item_size_id,item_color_id,brand_id', 'limit': '20000',
        });
        final referenced = <String>{};
        for (final p in (refsRes.data as List)) {
          final m = p as Map<String, dynamic>;
          for (final k in ['category_id', 'item_size_id', 'item_color_id', 'brand_id']) {
            final v = m[k] as String?;
            if (v != null) referenced.add(v);
          }
        }
        for (final id in createdCategoryIds) {
          if (!referenced.contains(id)) {
            await categoriesRepo.softDeleteCategory(id: id, userId: session.userId);
            cleanedUp++;
          }
        }
        for (final id in createdMasterIds) {
          if (!referenced.contains(id)) {
            await DioClient.instance.patch('/rim_common_masters', queryParameters: {'id': 'eq.$id'},
                data: {'is_deleted': true, 'is_active': false, 'updated_by': session.userId});
            cleanedUp++;
          }
        }
      }

      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() { _lines = []; _saving = false; });

      final summary = StringBuffer('$created product(s) created.');
      if (createdCategoryIds.isNotEmpty || createdMasterIds.isNotEmpty) {
        summary.write(' ${createdCategoryIds.length + createdMasterIds.length} master(s) auto-created.');
      }
      if (cleanedUp > 0) summary.write(' $cleanedUp unused auto-created master(s) cleaned up.');
      if (rowErrors.isEmpty) {
        _showSnack(summary.toString(), AppColors.positive);
      } else {
        summary.write(' ${rowErrors.length} row(s) skipped.');
        _showSnack(summary.toString(), Colors.orange);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Rows skipped'),
            content: SizedBox(width: 440, height: 320, child: SingleChildScrollView(child: Text(rowErrors.join('\n')))),
            actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('OK'))],
          ),
        );
      }
    } catch (e, st) {
      AppLogger.error('BulkUploadProductsSave', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'save these products'), AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Looks up an existing Category (any is_deleted state) by normalized
  /// name under the given parent+level; reuses (undeleting if needed)
  /// rather than ever inserting a duplicate name — required because
  /// `rim_item_categories`'s UNIQUE constraint is NOT partial on
  /// is_deleted. Also ensures a `rim_category_levels` row exists for this
  /// level (generic "Level N" label) so the ordinary Item Categories
  /// screen stays usable for what this screen creates.
  Future<ItemCategoryModel> _resolveOrCreateCategory(
    String? parentId, int levelNo, String name,
    Map<String, ItemCategoryModel> cache, Set<String> createdIds,
    Set<int> levelLabelSet, dynamic session,
  ) async {
    final key = '$parentId|$levelNo|${_norm(name)}';
    final existing = cache[key];
    final categoriesRepo = ref.read(itemCategoriesRepositoryProvider);
    if (!levelLabelSet.contains(levelNo)) {
      await categoriesRepo.saveLevel({
        'client_id': session.clientId, 'company_id': session.companyId,
        'level_no': levelNo, 'level_label': 'Level $levelNo',
        'is_mandatory': false, 'is_active': true,
      });
      levelLabelSet.add(levelNo);
    }
    if (existing != null) {
      if (existing.isDeleted) {
        await categoriesRepo.saveCategory({
          'id': existing.id, 'client_id': session.clientId, 'company_id': session.companyId,
          if (parentId != null) 'parent_id': parentId, 'level_no': levelNo, 'category_name': name,
          'is_active': true, 'is_deleted': false, 'updated_by': session.userId,
        });
      }
      return existing;
    }
    final id = const Uuid().v4();
    await categoriesRepo.saveCategory({
      'id': id, 'client_id': session.clientId, 'company_id': session.companyId,
      if (parentId != null) 'parent_id': parentId, 'level_no': levelNo, 'category_name': name,
      'flags': const {}, 'sort_order': 0, 'is_active': true, 'is_deleted': false,
      'created_by': session.userId,
    });
    final created = ItemCategoryModel(
      id: id, clientId: session.clientId, companyId: session.companyId, parentId: parentId,
      levelNo: levelNo, categoryName: name, sortOrder: 0, isActive: true, isDeleted: false, flags: const {},
    );
    cache[key] = created;
    createdIds.add(id);
    return created;
  }

  /// Same reuse-soft-deleted-first pattern for Unit/Brand/Item Size/Color
  /// (all `rim_common_masters` type rows).
  Future<CommonMasterModel> _resolveOrCreateMaster(
    String typeId, String description,
    Map<String, CommonMasterModel> cache, Set<String> createdIds, dynamic session,
  ) async {
    final key = '$typeId|${_norm(description)}';
    final existing = cache[key];
    if (existing != null) {
      if (existing.isDeleted) {
        await DioClient.instance.patch('/rim_common_masters', queryParameters: {'id': 'eq.${existing.id}'},
            data: {'is_active': true, 'is_deleted': false, 'updated_by': session.userId});
      }
      return existing;
    }
    final id = const Uuid().v4();
    await DioClient.instance.post('/rim_common_masters', data: {
      'id': id, 'client_id': session.clientId, 'company_id': session.companyId,
      'type_id': typeId, 'description': description, 'sort_order': 0,
      'is_active': true, 'is_deleted': false, 'created_by': session.userId,
    });
    final created = CommonMasterModel(
      id: id, clientId: session.clientId, companyId: session.companyId, typeId: typeId,
      description: description, sortOrder: 0, isActive: true, isDeleted: false,
    );
    cache[key] = created;
    createdIds.add(id);
    return created;
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  ScreenHeaderInfo buildScreenHeader() {
    final showDesktopActions = !Responsive.isMobile(context);
    return ScreenHeaderInfo(
      title: 'Bulk Upload Products',
      helpText: 'Upload an Excel file of new products — Category/Sub-Category/Item Size/Item '
          'Color/Brand/Unit master data is created automatically if it doesn\'t exist yet. '
          'Review the loaded rows below, edit anything that needs fixing, then Save.',
      actions: showDesktopActions
          ? [
              if (canExcelUpload)
                SakalHeaderActionButton(
                  label: 'Template', icon: Icons.download_outlined, kind: SakalActionKind.neutral,
                  onPressed: _downloadTemplate,
                ),
              if (canExcelUpload)
                SakalHeaderActionButton(
                  label: 'Upload Excel', icon: Icons.upload_file_outlined, kind: SakalActionKind.neutral,
                  loading: _uploadingExcel, onPressed: _uploadingExcel ? null : _uploadExcel,
                ),
              SakalHeaderActionButton(
                label: 'Save', icon: Icons.save_outlined, kind: SakalActionKind.save,
                loading: _saving, onPressed: (_saving || _lines.isEmpty) ? null : _save,
              ),
            ]
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    final isMobile = Responsive.isMobile(context);
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isMobile)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (canExcelUpload) OutlinedButton.icon(onPressed: _downloadTemplate, icon: const Icon(Icons.download_outlined, size: 16), label: const Text('Template')),
              if (canExcelUpload) OutlinedButton.icon(onPressed: _uploadingExcel ? null : _uploadExcel, icon: const Icon(Icons.upload_file_outlined, size: 16), label: const Text('Upload Excel')),
              FilledButton.icon(
                onPressed: (_saving || _lines.isEmpty) ? null : _save,
                icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined),
                label: const Text('Save'),
              ),
            ]),
          ),
        Expanded(
          child: _lines.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.upload_file_outlined, size: 48, color: AppColors.textSecondary),
                    const SizedBox(height: 12),
                    const Text('Upload an Excel file to get started.', style: TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Or add a row manually')),
                  ]),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: isMobile
                      ? ListView.separated(
                          itemCount: _lines.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) => _buildLine(_lines[i], true, bare, style),
                        )
                      : SakalScrollableTable(
                          header: _buildHeader(),
                          rows: _lines.map((l) => _buildLine(l, false, bare, style)).toList(),
                        ),
                ),
        ),
        if (_lines.isNotEmpty && !isMobile)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Row')),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader() => SakalTableHeaderBar(cells: [
        SizedBox(width: 200, child: SakalTableHeaderBar.label('Product Name')),
        const SizedBox(width: 8),
        SizedBox(width: 160, child: SakalTableHeaderBar.label('Description')),
        const SizedBox(width: 8),
        SizedBox(width: 130, child: SakalTableHeaderBar.label('Nature')),
        const SizedBox(width: 8),
        SizedBox(width: 100, child: SakalTableHeaderBar.label('HSN/SAC')),
        const SizedBox(width: 8),
        SizedBox(width: 130, child: SakalTableHeaderBar.label('Category L1')),
        const SizedBox(width: 8),
        SizedBox(width: 130, child: SakalTableHeaderBar.label('Category L2')),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: SakalTableHeaderBar.label('Category L3')),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: SakalTableHeaderBar.label('Category L4')),
        const SizedBox(width: 8),
        SizedBox(width: 100, child: SakalTableHeaderBar.label('Item Size')),
        const SizedBox(width: 8),
        SizedBox(width: 100, child: SakalTableHeaderBar.label('Item Color')),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: SakalTableHeaderBar.label('Brand')),
        const SizedBox(width: 8),
        SizedBox(width: 90, child: SakalTableHeaderBar.label('Unit')),
        const SizedBox(width: 8),
        SizedBox(width: 100, child: SakalTableHeaderBar.label('Unit Cost')),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: SakalTableHeaderBar.label('Price In')),
        const SizedBox(width: 8),
        SizedBox(width: 100, child: SakalTableHeaderBar.label('Variance %')),
        const SizedBox(width: 8),
        SizedBox(width: 140, child: SakalTableHeaderBar.label('Sales Tax Group')),
        const SizedBox(width: 8),
        SizedBox(width: 140, child: SakalTableHeaderBar.label('Purchase Tax Group')),
        const SizedBox(width: 40),
      ]);

  Widget _textField(TextEditingController ctrl, InputDecoration bare, {TextInputType? keyboardType}) => TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: bare,
      );

  Widget _buildLine(_BulkRow row, bool isMobile, InputDecoration bare, TextStyle style) {
    final natureField = DropdownButtonFormField<String>(
      initialValue: row.nature,
      isExpanded: true, isDense: true, itemHeight: null,
      decoration: bare,
      items: _natureOptions.map((n) => DropdownMenuItem(value: n, child: Text(ProductModel.natureLabels[n] ?? n, style: const TextStyle(fontSize: 12)))).toList(),
      onChanged: (v) => setState(() => row.nature = v ?? 'TRADING'),
    );
    final fields = <Widget>[
      SizedBox(width: 200, child: _textField(row.nameCtrl, bare)),
      SizedBox(width: 160, child: _textField(row.descCtrl, bare)),
      SizedBox(width: 130, child: natureField),
      SizedBox(width: 100, child: _textField(row.hsnCtrl, bare)),
      SizedBox(width: 130, child: _textField(row.cat1Ctrl, bare)),
      SizedBox(width: 130, child: _textField(row.cat2Ctrl, bare)),
      SizedBox(width: 110, child: _textField(row.cat3Ctrl, bare)),
      SizedBox(width: 110, child: _textField(row.cat4Ctrl, bare)),
      SizedBox(width: 100, child: _textField(row.sizeCtrl, bare)),
      SizedBox(width: 100, child: _textField(row.colorCtrl, bare)),
      SizedBox(width: 110, child: _textField(row.brandCtrl, bare)),
      SizedBox(width: 90, child: _textField(row.unitCtrl, bare)),
      SizedBox(width: 100, child: _textField(row.costCtrl, bare, keyboardType: const TextInputType.numberWithOptions(decimal: true))),
      SizedBox(width: 110, child: _textField(row.currencyCtrl, bare)),
      SizedBox(width: 100, child: _textField(row.varianceCtrl, bare, keyboardType: const TextInputType.numberWithOptions(decimal: true))),
      SizedBox(width: 140, child: _textField(row.salesTaxCtrl, bare)),
      SizedBox(width: 140, child: _textField(row.purchTaxCtrl, bare)),
    ];

    if (isMobile) {
      return SakalLineItemCard(
        title: row.nameCtrl.text.isEmpty ? 'New Product' : row.nameCtrl.text,
        onDelete: () => _removeLine(row),
        fields: const [],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final f in fields) ...[f, const SizedBox(height: 8)]],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final f in fields) ...[f, const SizedBox(width: 8)],
        SizedBox(width: 40, child: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeLine(row), tooltip: 'Remove row')),
      ]),
    );
  }
}

extension _NullIfEmptyB on String {
  String? get nullIfEmptyB => isEmpty ? null : this;
}

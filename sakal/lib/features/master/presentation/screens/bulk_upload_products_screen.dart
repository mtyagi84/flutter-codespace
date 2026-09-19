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
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
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
/// exception (see _save's own comment on the batch-confirmation step):
/// they can't be meaningfully synthesized from a bare name.
class BulkUploadProductsScreen extends ConsumerStatefulWidget {
  const BulkUploadProductsScreen({super.key});

  @override
  ConsumerState<BulkUploadProductsScreen> createState() => _BulkUploadProductsScreenState();
}

const _natureOptions = ['TRADING', 'FINISHED_GOOD', 'RAW_MATERIAL', 'PACKAGING', 'CONSUMABLE', 'SERVICE'];

// Compact grid metrics — ~20% smaller than this app's usual field-card
// defaults, per direct user feedback that the original row height/font
// felt too large for a dense data-entry grid like this one.
const _gridFontSize = 11.0;
const _gridRowVPad = 5.0;
final _gridCellDecoration = BoxDecoration(border: Border.all(color: AppColors.border, width: 0.6));

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

  Map<String, dynamic> snapshot() => {
        'name': nameCtrl.text.trim(), 'description': descCtrl.text.trim(),
        'nature': nature, 'hsn': hsnCtrl.text.trim(),
        'cat1': cat1Ctrl.text.trim(), 'cat2': cat2Ctrl.text.trim(),
        'cat3': cat3Ctrl.text.trim(), 'cat4': cat4Ctrl.text.trim(),
        'size': sizeCtrl.text.trim(), 'color': colorCtrl.text.trim(), 'brand': brandCtrl.text.trim(),
        'unit': unitCtrl.text.trim(), 'cost': costCtrl.text.trim(), 'currency': currencyCtrl.text.trim(),
        'variance': varianceCtrl.text.trim(), 'salesTax': salesTaxCtrl.text.trim(), 'purchTax': purchTaxCtrl.text.trim(),
      };

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
  String? _progressText;

  // Reset-and-reupload — see fn_can_reset_all_products/fn_reset_all_products
  // (migration 192). Company-wide gate: only offered when NO product in the
  // company has ANY transaction yet (checked live when the checkbox is
  // ticked, then re-checked authoritatively server-side at Save — never
  // trust the client-side check still holds by the time Save actually runs).
  bool _resetFirst = false;
  bool _checkingReset = false;

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
    _vController.dispose();
    _hHeaderController.dispose();
    _hBodyController.dispose();
    super.dispose();
  }

  void _addLine() => setState(() => _lines.add(_BulkRow()));

  void _removeLine(_BulkRow row) {
    if (_saving || _uploadingExcel) return;
    setState(() => _lines.remove(row));
    deferRowDisposal(row);
  }

  Future<void> _onResetToggleChanged(bool? checked) async {
    if (checked != true) { setState(() => _resetFirst = false); return; }
    setState(() => _checkingReset = true);
    try {
      final session = ref.read(sessionProvider)!;
      final productsRepo = ref.read(productsRepositoryProvider);
      final reason = await productsRepo.canResetAllProducts(
        clientId: session.clientId, companyId: session.companyId,
      );
      if (reason != null) {
        _showSnack(reason, AppColors.negative);
        if (mounted) setState(() => _resetFirst = false);
        return;
      }
      if (mounted) setState(() => _resetFirst = true);
    } catch (e, st) {
      AppLogger.error('BulkUploadProductsResetCheck', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'check whether products can be reset'), AppColors.negative);
      if (mounted) setState(() => _resetFirst = false);
    } finally {
      if (mounted) setState(() => _checkingReset = false);
    }
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

    setState(() { _uploadingExcel = true; _progressText = 'Reading file…'; });
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
      if (mounted) setState(() { _uploadingExcel = false; _progressText = null; });
    }
  }

  // ── Save — the full per-row pipeline ────────────────────────────────────
  //
  // Every row's field VALUES are read into a plain snapshot map up front,
  // before any `await` — the whole rest of this method (and everything it
  // calls) only ever touches those plain maps, never `_BulkRow`/its
  // TextEditingControllers again. This matters because Save can take
  // several minutes for a large file; if the user navigates away from this
  // screen mid-save, Flutter disposes this State's controllers immediately
  // (see `dispose()` above) while the in-flight async pipeline keeps
  // running in the background — touching a disposed TextEditingController
  // at that point would throw. Working from a snapshot instead means a
  // navigate-away mid-save can't crash the save itself (network calls
  // already in flight complete normally); what it CANNOT protect against
  // is the risk of leaving this screen while Save is still writing to the
  // database — see the blocking overlay + PopScope below, which is this
  // screen's actual defense against that.
  Future<void> _save() async {
    if (_lines.isEmpty) {
      _showSnack('Upload a file or add at least one row first.', AppColors.negative);
      return;
    }
    if (_resetFirst) {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Delete existing products?'),
          content: const Text(
            'This will permanently delete EVERY existing product in this company before '
            'uploading this file. This cannot be undone. Continue?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
              child: const Text('Delete & Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final rowSnapshots = _lines.map((l) => l.snapshot()).toList();
    setState(() { _saving = true; _progressText = 'Preparing…'; });
    final session = ref.read(sessionProvider)!;
    final productsRepo  = ref.read(productsRepositoryProvider);
    final categoriesRepo = ref.read(itemCategoriesRepositoryProvider);
    var resetDeletedCount = 0;

    try {
      // ── 0. Reset (optional) — re-checked authoritatively server-side by
      // fn_reset_all_products itself, never trusting that the earlier
      // checkbox-time check still holds. Runs BEFORE the existing-products
      // fetch below so that fetch correctly sees an empty table afterward.
      if (_resetFirst) {
        setState(() => _progressText = 'Deleting existing products…');
        resetDeletedCount = await productsRepo.resetAllProducts(
          clientId: session.clientId, companyId: session.companyId,
        );
        if (mounted) setState(() => _resetFirst = false); // one-shot, doesn't reapply on a later Save
      }

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

      // Starting product-code number, fetched ONCE — every subsequent code
      // is computed locally (nextNum++) rather than re-querying the count
      // per row. Calling generateProductCode() inside the per-row loop was
      // a real performance bug found live (a ~500-row file took 5-6
      // minutes, dominated by this one avoidable extra round-trip per row).
      final startingCode = await productsRepo.generateProductCode(clientId: session.clientId, companyId: session.companyId);
      var nextProductNum = int.tryParse(startingCode.replaceAll('PRD-', '')) ?? 1;

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
      final unmatchedTaxRows = <Map<String, dynamic>>[];
      final readyRows = <Map<String, dynamic>>[];

      // ── 2. Per-row resolution (no commits yet) ──────────────────────────
      var rowIdx = 0;
      for (final row in rowSnapshots) {
        rowIdx++;
        final name = row['name'] as String;
        if (name.isEmpty) continue;
        // Throttled to every 5th row — updating on every single row adds
        // up to ~500 extra rebuilds across a large file for no visible
        // benefit (a human can't read text changing that fast anyway).
        if (mounted && (rowIdx % 5 == 0 || rowIdx == 1)) {
          setState(() => _progressText = 'Resolving row $rowIdx of ${rowSnapshots.length}: $name');
        }

        final normName = _norm(name);
        if (existingNames.contains(normName) || !committedNamesThisRun.add(normName)) {
          rowErrors.add('"$name": a product with this name already exists (or is duplicated in this file).');
          continue;
        }

        final unitName = row['unit'] as String;
        if (unitName.isEmpty) { rowErrors.add('"$name": Unit of Measure is required.'); continue; }
        final unit = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.unit]!, unitName, mastersByKey, createdMasterIds, session,
        );

        // Category chain L1..L4 — L1 required if ANY level given; a gap
        // (L3 given but L2 blank) is a row error, not a silent skip-ahead.
        String? categoryId;
        final catNames = [row['cat1'] as String, row['cat2'] as String, row['cat3'] as String, row['cat4'] as String];
        var skipRow = false;
        if (catNames.any((c) => c.isNotEmpty)) {
          if (catNames[0].isEmpty) { rowErrors.add('"$name": Category L1 is required when any category level is given.'); continue; }
          String? parentId;
          for (var lvl = 0; lvl < 4; lvl++) {
            final cName = catNames[lvl];
            if (cName.isEmpty) {
              if (catNames.sublist(lvl + 1).any((c) => c.isNotEmpty)) {
                rowErrors.add('"$name": Category L${lvl + 1} is blank but a deeper level is given.');
                skipRow = true;
              }
              break;
            }
            final cat = await _resolveOrCreateCategory(
              parentId, lvl + 1, cName, categoriesByKey, createdCategoryIds, levelLabelSet, session,
            );
            categoryId = cat.id;
            parentId = cat.id;
          }
          if (skipRow) continue;
        }

        final size = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.itemSize]!,
          (row['size'] as String).isEmpty ? 'N/A' : row['size'] as String,
          mastersByKey, createdMasterIds, session,
        );
        final color = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.color]!,
          (row['color'] as String).isEmpty ? 'N/A' : row['color'] as String,
          mastersByKey, createdMasterIds, session,
        );
        final brand = await _resolveOrCreateMaster(
          typeIdByKey[MasterTypeKey.brand]!,
          (row['brand'] as String).isEmpty ? 'N/A' : row['brand'] as String,
          mastersByKey, createdMasterIds, session,
        );

        String? costCurrencyId = baseCurrencyId;
        final currencyName = row['currency'] as String;
        if (currencyName.isNotEmpty) {
          final match = baseCurrencies.firstWhere(
            (c) => _norm(c['currency_id'] as String? ?? '') == _norm(currencyName), orElse: () => const {});
          if (match['id'] == null) { rowErrors.add('"$name": currency "$currencyName" not found.'); continue; }
          costCurrencyId = match['id'] as String;
        }

        String? salesTaxId;
        final salesTaxName = row['salesTax'] as String;
        var hasUnmatchedTax = false;
        if (salesTaxName.isNotEmpty) {
          final g = taxGroupByKey['${_norm(salesTaxName)}|SALES'] ?? taxGroupByKey['${_norm(salesTaxName)}|BOTH'];
          if (g == null) { hasUnmatchedTax = true; } else { salesTaxId = g.id; }
        }
        String? purchTaxId;
        final purchTaxName = row['purchTax'] as String;
        if (purchTaxName.isNotEmpty) {
          final g = taxGroupByKey['${_norm(purchTaxName)}|PURCHASE'] ?? taxGroupByKey['${_norm(purchTaxName)}|BOTH'];
          if (g == null) { hasUnmatchedTax = true; } else { purchTaxId = g.id; }
        }

        final resolved = {
          'name': name, 'description': (row['description'] as String).nullIfEmptyB,
          'nature': row['nature'], 'hsn': (row['hsn'] as String).nullIfEmptyB,
          'category_id': categoryId, 'size_id': size.id, 'color_id': color.id, 'brand_id': brand.id,
          'unit_id': unit.id, 'cost': double.tryParse(row['cost'] as String) ?? 0,
          'cost_currency_id': costCurrencyId,
          'variance': double.tryParse(row['variance'] as String) ?? 0,
          'sales_tax_id': salesTaxId, 'purch_tax_id': purchTaxId,
          'sales_tax_name': salesTaxName, 'purch_tax_name': purchTaxName,
        };
        if (hasUnmatchedTax) {
          unmatchedTaxRows.add(resolved);
        } else {
          readyRows.add(resolved);
        }
      }

      // ── 3. Batch tax-group confirmation ──────────────────────────────────
      var dropUnmatchedTaxRows = true;
      if (unmatchedTaxRows.isNotEmpty && mounted) {
        final missingNames = <String>{};
        for (final r in unmatchedTaxRows) {
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
        for (final r in unmatchedTaxRows) {
          rowErrors.add('"${r['name']}": skipped — unmatched Tax Group ("${r['sales_tax_name']}"/"${r['purch_tax_name']}").');
        }
      }

      // ── 4. Commit ────────────────────────────────────────────────────────
      var created = 0;
      var commitIdx = 0;
      for (final r in toCommit) {
        commitIdx++;
        if (mounted && (commitIdx % 5 == 0 || commitIdx == 1)) {
          setState(() => _progressText = 'Creating product $commitIdx of ${toCommit.length}: ${r['name']}');
        }
        final productId = const Uuid().v4();
        final code = 'PRD-${nextProductNum.toString().padLeft(5, '0')}';
        nextProductNum++;
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
        if (mounted) setState(() => _progressText = 'Cleaning up unused auto-created masters…');
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
      setState(() { _lines = []; _saving = false; _progressText = null; });

      final summary = StringBuffer();
      if (resetDeletedCount > 0) summary.write('$resetDeletedCount existing product(s) deleted. ');
      summary.write('$created product(s) created.');
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
      if (mounted) setState(() { _saving = false; _progressText = null; });
    }
  }

  /// Looks up an existing Category (any is_deleted state) by normalized
  /// name under the given parent+level; reuses (undeleting if needed)
  /// rather than ever inserting a duplicate name — required because
  /// `rim_item_categories`'s UNIQUE constraint is NOT partial on
  /// is_deleted. Also ensures a `rim_category_levels` row exists for this
  /// level (generic "Level N" label) so the ordinary Item Categories
  /// screen stays usable for what this screen creates.
  ///
  /// IMPORTANT: new-category creation goes through a PLAIN PostgREST POST
  /// (`DioClient.instance.post`), never `ItemCategoriesRepository.
  /// saveCategory()` — a real bug found live: that repo method branches
  /// purely on "does the payload contain an 'id' key" to decide POST vs
  /// PATCH, so passing a client-generated id for a NEW row silently turned
  /// into a PATCH against a row that didn't exist yet (PostgREST returns
  /// 200 with zero rows affected, not an error) — the category was never
  /// actually created, and every product referencing it then failed a
  /// foreign-key check at insert time. `saveCategory()` is still correct
  /// (and still used below) for the genuine UPDATE case — reusing an
  /// already-existing soft-deleted row.
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
    await DioClient.instance.post('/rim_item_categories', data: {
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
  /// (all `rim_common_masters` type rows) — already a plain POST, not
  /// affected by the saveCategory bug above.
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
    final busy = _saving || _uploadingExcel;
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
                  onPressed: busy ? null : _downloadTemplate,
                ),
              if (canExcelUpload)
                SakalHeaderActionButton(
                  label: 'Upload Excel', icon: Icons.upload_file_outlined, kind: SakalActionKind.neutral,
                  loading: _uploadingExcel, onPressed: busy ? null : _uploadExcel,
                ),
              SakalHeaderActionButton(
                label: 'Save', icon: Icons.save_outlined, kind: SakalActionKind.save,
                loading: _saving, onPressed: (busy || _lines.isEmpty) ? null : _save,
              ),
            ]
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    final isMobile = Responsive.isMobile(context);
    final busy = _saving || _uploadingExcel;

    // Blocks the Flutter back gesture/route pop while a save or upload is
    // in flight — the strongest guard this single screen can offer against
    // navigating away mid-write. It cannot lock the shared TopBar/sidebar
    // chrome (those live outside this screen's own widget tree), so the
    // full-screen overlay below is the other half of this mitigation:
    // together they make leaving mid-save deliberately hard, not
    // impossible — see the long comment on _save() for what IS and isn't
    // protected either way.
    return PopScope(
      canPop: !busy,
      child: Stack(children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            if (isMobile)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  if (canExcelUpload) OutlinedButton.icon(onPressed: busy ? null : _downloadTemplate, icon: const Icon(Icons.download_outlined, size: 16), label: const Text('Template')),
                  if (canExcelUpload) OutlinedButton.icon(onPressed: busy ? null : _uploadExcel, icon: const Icon(Icons.upload_file_outlined, size: 16), label: const Text('Upload Excel')),
                  FilledButton.icon(
                    onPressed: (busy || _lines.isEmpty) ? null : _save,
                    icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ]),
              ),
            if (canExcelUpload)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 16, 4),
                child: Row(children: [
                  Checkbox(
                    value: _resetFirst,
                    onChanged: (busy || _checkingReset) ? null : _onResetToggleChanged,
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: (busy || _checkingReset) ? null : () => _onResetToggleChanged(!_resetFirst),
                      child: Text(
                        _checkingReset
                            ? 'Checking existing products…'
                            : 'Delete ALL existing products first, then upload this file '
                                '(only allowed if no product has any transaction yet)',
                        style: TextStyle(
                          fontSize: 12,
                          color: _resetFirst ? AppColors.negative : AppColors.textSecondary,
                          fontWeight: _resetFirst ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            if (_lines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text('${_lines.length} product(s) loaded', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
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
                              itemBuilder: (_, i) => _buildLine(_lines[i], i, true),
                            )
                          : _buildDesktopGrid(),
                    ),
            ),
            if (_lines.isNotEmpty && !isMobile)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(onPressed: busy ? null : _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Row')),
                ),
              ),
          ],
        ),
        if (busy) _buildBusyOverlay(),
      ]),
    );
  }

  Widget _buildBusyOverlay() => Positioned.fill(
        child: Container(
          color: Colors.black.withValues(alpha: 0.35),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(height: 14),
                Text(
                  _progressText ?? (_uploadingExcel ? 'Reading Excel file…' : 'Saving…'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                const Text('Please don\'t close or navigate away from this screen.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ]),
            ),
          ),
        ),
      );

  // Vertical scroll (with a persistent visible thumb) wraps the whole
  // Vertical scroll (ListView.builder — lazily builds only visible rows,
  // see the fix note below) has a persistent visible thumb; horizontal
  // scroll is split into a HEADER controller and a BODY controller kept
  // in sync via listeners, so the header stays pinned at the top (never
  // scrolls away vertically) while columns still stay aligned when
  // scrolling sideways. SakalScrollableTable itself only ever provided a
  // single combined header+body horizontal scroll with no sticky-header
  // behavior, which is what caused the header to scroll out of view.
  final _vController = ScrollController();
  final _hHeaderController = ScrollController();
  final _hBodyController = ScrollController();
  bool _syncingHScroll = false;

  @override
  void initState() {
    super.initState();
    _hHeaderController.addListener(() => _syncHScroll(_hHeaderController, _hBodyController));
    _hBodyController.addListener(() => _syncHScroll(_hBodyController, _hHeaderController));
  }

  void _syncHScroll(ScrollController source, ScrollController target) {
    if (_syncingHScroll || !target.hasClients) return;
    _syncingHScroll = true;
    target.jumpTo(source.offset);
    _syncingHScroll = false;
  }

  static const _colWidths = <double>[
    44, 190, 150, 170, 90, 120, 120, 100, 100, 90, 90, 100, 80, 90, 100, 90, 130, 130, 36,
  ];
  static final _gridTotalWidth = _colWidths.fold<double>(0, (a, b) => a + b);

  // Real perf bug found live: building all ~487 rows × 17 fields (8000+
  // live TextEditingController-backed widgets) eagerly in one Column made
  // the page hang well before reaching the end of a large file, and made
  // Tab-key focus traversal slow (Flutter has to walk the whole built
  // tree to find the next focus node). ListView.builder only builds rows
  // actually visible (plus a small cache extent) at any moment, exactly
  // like every other long list in this app already does.
  Widget _buildDesktopGrid() {
    // Each Scrollbar is given the SAME controller as the scrollable it
    // sits directly on top of — matching sakal_scrollable_table.dart's own
    // proven pattern exactly — rather than relying on ScrollNotification
    // depth-matching, which gets genuinely ambiguous once a horizontal and
    // a vertical scrollable are nested inside each other.
    return Column(children: [
      SingleChildScrollView(
        controller: _hHeaderController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(), // dragging the header itself would fight the sync; drag the body instead
        child: SizedBox(width: _gridTotalWidth, child: _buildHeaderRow(_colWidths)),
      ),
      Expanded(
        child: Scrollbar(
          controller: _hBodyController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _hBodyController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _gridTotalWidth,
              child: Scrollbar(
                controller: _vController,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _vController,
                  itemCount: _lines.length,
                  itemExtent: 34,
                  itemBuilder: (_, i) => _buildLine(_lines[i], i, false, colWidths: _colWidths),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _headerCell(String label, double width) => Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: _gridRowVPad),
        decoration: BoxDecoration(color: AppColors.primary, border: Border.all(color: AppColors.primary)),
        child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: _gridFontSize, fontWeight: FontWeight.w700)),
      );

  Widget _buildHeaderRow(List<double> w) => Row(children: [
        _headerCell('#', w[0]),
        _headerCell('Product Name', w[1]),
        _headerCell('Description', w[2]),
        _headerCell('Nature', w[3]),
        _headerCell('HSN/SAC', w[4]),
        _headerCell('Category L1', w[5]),
        _headerCell('Category L2', w[6]),
        _headerCell('Category L3', w[7]),
        _headerCell('Category L4', w[8]),
        _headerCell('Item Size', w[9]),
        _headerCell('Item Color', w[10]),
        _headerCell('Brand', w[11]),
        _headerCell('Unit', w[12]),
        _headerCell('Unit Cost', w[13]),
        _headerCell('Price In', w[14]),
        _headerCell('Variance %', w[15]),
        _headerCell('Sales Tax', w[16]),
        _headerCell('Purch. Tax', w[17]),
        _headerCell('', w[18]),
      ]);

  InputDecoration get _cellInputDecoration => const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        border: InputBorder.none,
      );

  Widget _cell(Widget child, double width) => Container(
        width: width,
        decoration: _gridCellDecoration,
        child: child,
      );

  Widget _textField(TextEditingController ctrl, {TextInputType? keyboardType, TextAlign align = TextAlign.left}) => TextFormField(
        controller: ctrl,
        enabled: !_saving && !_uploadingExcel,
        keyboardType: keyboardType,
        textAlign: align,
        style: const TextStyle(fontSize: _gridFontSize),
        decoration: _cellInputDecoration,
      );

  Widget _buildLine(_BulkRow row, int index, bool isMobile, {List<double>? colWidths}) {
    final natureField = DropdownButtonFormField<String>(
      initialValue: row.nature,
      isExpanded: true, isDense: true, itemHeight: null,
      style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textPrimary),
      decoration: _cellInputDecoration,
      // selectedItemBuilder controls what's shown when COLLAPSED — the
      // plain `items` Text alone only governs the open dropdown menu.
      // Without this, a long label like "Trading / Resale" wraps onto a
      // second line in the collapsed field and silently makes the whole
      // grid row taller than its neighbors (a real bug found live).
      selectedItemBuilder: (_) => _natureOptions
          .map((n) => Align(
                alignment: Alignment.centerLeft,
                child: Text(ProductModel.natureLabels[n] ?? n, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: const TextStyle(fontSize: _gridFontSize)),
              ))
          .toList(),
      items: _natureOptions.map((n) => DropdownMenuItem(value: n, child: Text(ProductModel.natureLabels[n] ?? n, style: const TextStyle(fontSize: _gridFontSize)))).toList(),
      onChanged: (_saving || _uploadingExcel) ? null : (v) => setState(() => row.nature = v ?? 'TRADING'),
    );

    if (isMobile) {
      final fields = <Widget>[
        _textField(row.nameCtrl), _textField(row.descCtrl), natureField, _textField(row.hsnCtrl),
        _textField(row.cat1Ctrl), _textField(row.cat2Ctrl), _textField(row.cat3Ctrl), _textField(row.cat4Ctrl),
        _textField(row.sizeCtrl), _textField(row.colorCtrl), _textField(row.brandCtrl), _textField(row.unitCtrl),
        _textField(row.costCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right),
        _textField(row.currencyCtrl),
        _textField(row.varianceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right),
        _textField(row.salesTaxCtrl), _textField(row.purchTaxCtrl),
      ];
      return SakalLineItemCard(
        title: row.nameCtrl.text.isEmpty ? 'New Product (#${index + 1})' : row.nameCtrl.text,
        onDelete: (_saving || _uploadingExcel) ? null : () => _removeLine(row),
        fields: const [],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final f in fields) ...[f, const SizedBox(height: 8)]],
        ),
      );
    }

    final w = colWidths!;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        width: w[0], alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: _gridRowVPad),
        decoration: _gridCellDecoration,
        child: Text('${index + 1}', style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textSecondary)),
      ),
      _cell(_textField(row.nameCtrl), w[1]),
      _cell(_textField(row.descCtrl), w[2]),
      _cell(natureField, w[3]),
      _cell(_textField(row.hsnCtrl), w[4]),
      _cell(_textField(row.cat1Ctrl), w[5]),
      _cell(_textField(row.cat2Ctrl), w[6]),
      _cell(_textField(row.cat3Ctrl), w[7]),
      _cell(_textField(row.cat4Ctrl), w[8]),
      _cell(_textField(row.sizeCtrl), w[9]),
      _cell(_textField(row.colorCtrl), w[10]),
      _cell(_textField(row.brandCtrl), w[11]),
      _cell(_textField(row.unitCtrl), w[12]),
      _cell(_textField(row.costCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), w[13]),
      _cell(_textField(row.currencyCtrl), w[14]),
      _cell(_textField(row.varianceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), w[15]),
      _cell(_textField(row.salesTaxCtrl), w[16]),
      _cell(_textField(row.purchTaxCtrl), w[17]),
      Container(
        width: w[18], decoration: _gridCellDecoration,
        child: (_saving || _uploadingExcel)
            ? null
            : IconButton(
                padding: EdgeInsets.zero, iconSize: 14,
                icon: const Icon(Icons.close),
                onPressed: () => _removeLine(row),
                tooltip: 'Remove row',
              ),
      ),
    ]);
  }
}

extension _NullIfEmptyB on String {
  String? get nullIfEmptyB => isEmpty ? null : this;
}

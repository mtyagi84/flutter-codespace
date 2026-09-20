import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../domain/repositories/opening_stock_repository.dart';
import '../providers/opening_stock_providers.dart';

/// One physical lot/unit — the module's own deliberate divergence from
/// every other module's "line + child batch/serial table" shape. Batch,
/// expiry and serial live flat on the row; there is no direction flag
/// (Opening Stock only ever establishes NEW lots, GRN-style).
///
/// 2026-09-20: merged with the (now-retired) Opening Stock Value Upload
/// screen — see docs/screens/plan_merge_opening_stock_screens.md. This one
/// screen now covers manual/scan entry AND bulk-upload-from-Product-Master
/// AND an optional GL-posting path, instead of two near-duplicate screens.
class _OpeningLineRow {
  String? productId;
  String  productDisplay = '';
  String  trackingType = 'NONE';
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  final TextEditingController batchNoCtrl  = TextEditingController();
  DateTime? expiryDate;
  DateTime? manufacturingDate;
  final TextEditingController serialNoCtrl  = TextEditingController();
  final TextEditingController unitCostCtrl  = TextEditingController(text: '0');
  // Optional — "Price in Product Currency". When left blank, Approve
  // derives it from unit_cost via the product's own cost-currency exchange
  // rate, exactly as before this merge; when supplied, that derivation is
  // skipped and this value is used directly (migration 193's own extension).
  final TextEditingController unitCostSpecificCtrl = TextEditingController();
  final TextEditingController remarksCtrl   = TextEditingController();
  String? matchedBarcode;
  num? currentStock;
  num? currentCost;

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get baseQty  => qtyPack * uomConversionFactor + qtyLoose;
  double get unitCost => double.tryParse(unitCostCtrl.text) ?? 0;
  double? get unitCostSpecific => double.tryParse(unitCostSpecificCtrl.text);

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  /// Advisory only — the real OPENING_STOCK_ALREADY_ESTABLISHED guard is
  /// server-side, at Approve.
  bool get alreadyEstablished => (currentStock ?? 0) != 0 || (currentCost ?? 0) != 0;

  void dispose() {
    for (final c in [qtyPackCtrl, qtyLooseCtrl, batchNoCtrl, serialNoCtrl, unitCostCtrl, unitCostSpecificCtrl, remarksCtrl]) {
      c.dispose();
    }
  }
}

const _gridFontSize = 11.0;
const _gridRowVPad = 5.0;
final _gridCellDecoration = BoxDecoration(border: Border.all(color: AppColors.border, width: 0.6));

class OpeningStockEntryScreen extends ConsumerStatefulWidget {
  final String? editOpeningNo;
  final String? editOpeningDate;
  const OpeningStockEntryScreen({super.key, this.editOpeningNo, this.editOpeningDate});

  @override
  ConsumerState<OpeningStockEntryScreen> createState() => _OpeningStockEntryScreenState();
}

class _OpeningStockEntryScreenState extends ConsumerState<OpeningStockEntryScreen>
    with ScreenPermissionMixin<OpeningStockEntryScreen>, ScreenHeaderMixin<OpeningStockEntryScreen> {
  @override String get screenName => RouteNames.openingStock;

  @override
  ScreenHeaderInfo buildScreenHeader() {
    final locked = _status != 'DRAFT';
    final isOffline = ref.read(sessionProvider)?.offlineMode ?? false;
    final canSaveNow = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final canApproveNow = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;
    final showDesktopActions = !Responsive.isMobile(context);
    return ScreenHeaderInfo(
      title: _openingNo != null ? 'Opening Stock · $_openingNo' : 'New Opening Stock',
      subtitle: locked ? null : (_openingNo != null ? 'Draft' : 'Unsaved draft'),
      badgeText: locked ? _status : null,
      badgeColor: locked ? AppColors.positive : null,
      trailingBadge: _openingNo != null ? PendingSyncBadge(documentType: 'OPENING_STOCK', documentId: _openingNo!) : null,
      actions: showDesktopActions
          ? [
              if (canSaveNow) SakalHeaderActionButton(label: 'Save Draft', icon: Icons.save_outlined, kind: SakalActionKind.save, loading: _saving, onPressed: _saving ? null : () => _saveDraft()),
              if (canApproveNow) SakalHeaderActionButton(label: 'Approve', icon: Icons.check_circle_outline, kind: SakalActionKind.approve, loading: _approving, onPressed: _approving ? null : _approveOpeningStock),
              if (_openingNo != null) SakalHeaderActionButton(label: 'Print', icon: Icons.print_outlined, kind: SakalActionKind.neutral, loading: _printing, onPressed: _printing ? null : _printOpeningStock),
            ]
          : (_openingNo != null ? [_buildPrintButton()] : const []),
    );
  }

  OpeningStockRepository get _ds => ref.read(openingStockRepositoryProvider);

  String?  _openingNo;
  DateTime _openingDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  final _remarksCtrl = TextEditingController();
  final _scanCtrl = TextEditingController();

  // GL posting — optional, header-level. Locks the date to the financial
  // year start while on (same reconciliation reasoning migration 193
  // introduced), and gates the Approve confirmation wording. Both this
  // screen's "IN-OPN" feature permission governs Approve regardless of
  // whether GL posting is on — the separate "IN-OSV" permission from the
  // now-retired Value Upload screen is gone; see migration 199.
  bool _postGl = false;
  DateTime? _fyStartDate;

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _allProducts = [];
  final List<_OpeningLineRow> _lines = [];

  // Resolved once in _init (against _users, already loaded before it) —
  // print's "Prepared By"/"Authorised Signatory" data supply.
  String? _preparedByName;
  String? _authorisedByName;

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _printing = false;
  bool    _uploadingExcel = false;
  bool    _checkingExisting = false;

  bool get _isNew => _openingNo == null;

  @override
  void initState() {
    super.initState();
    _hHeaderController.addListener(() => _syncHScroll(_hHeaderController, _hBodyController));
    _hBodyController.addListener(() => _syncHScroll(_hBodyController, _hHeaderController));
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    _scanCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    _vController.dispose();
    _hHeaderController.dispose();
    _hBodyController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _locations = await _ds.getLocations(clientId: session.clientId, companyId: session.companyId);
      _users = await _ds.getUsers(clientId: session.clientId, companyId: session.companyId);

      // Full active product list — powers the pre-filled Excel template AND
      // Excel-upload matching. Fetched once, not via getProductsForPicker
      // (that method caps at 500 rows for autocomplete use, too low for a
      // full-catalog export).
      try {
        final productsRes = await DioClient.instance.get('/rim_products', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'is_active': 'eq.true',
          'select': 'id,product_code,product_name,base_uom_id,tracking_type,'
              'uom:rim_common_masters!base_uom_id(description)',
          'order': 'product_code.asc', 'limit': '20000',
        });
        _allProducts = List<Map<String, dynamic>>.from(productsRes.data as List);
      } catch (_) {
        // Non-fatal — only the Template/Upload actions need this; manual
        // add/scan entry still works via getProductsForPicker.
      }

      // Financial year start — only needed if/when the user turns on GL
      // posting; a company with no FY configured yet can still use this
      // screen normally with GL posting off.
      try {
        final fys = await ref.read(financialYearsProvider.future);
        if (fys.isNotEmpty) {
          final active = fys.where((f) => f['is_active'] == true).toList();
          final chosen = active.isNotEmpty ? active.first : fys.last; // fys is fy_start_date DESC, so .last is the earliest
          _fyStartDate = DateTime.tryParse(chosen['fy_start_date'] as String);
        }
      } catch (_) {
        // advisory only — see _postGl checkbox's own disabled state
      }

      if (widget.editOpeningNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          openingNo: widget.editOpeningNo!, openingDate: widget.editOpeningDate,
        );
        if (header != null) {
          _openingNo    = header['opening_no'] as String;
          _openingDate  = DateTime.parse(header['opening_date'] as String);
          _status       = header['status'] as String;
          _locationId   = header['location_id'] as String?;
          _postGl       = header['post_gl'] as bool? ?? false;
          _remarksCtrl.text = header['remarks'] as String? ?? '';
          _preparedByName   = _resolveUserName(header['created_by'] as String?);
          _authorisedByName = _resolveUserName(header['approved_by'] as String?);

          final savedLines = await _ds.getLines(
            clientId: session.clientId, companyId: session.companyId,
            openingNo: _openingNo!, openingDate: _fmtDate(_openingDate),
          );
          for (final l in _lines) { l.dispose(); }
          _lines.clear();
          for (final sl in savedLines) {
            final product = sl['product'] as Map<String, dynamic>?;
            final uom     = sl['uom'] as Map<String, dynamic>?;
            final row = _OpeningLineRow()
              ..productId = sl['product_id'] as String?
              ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
              ..trackingType = product?['tracking_type'] as String? ?? 'NONE'
              ..uomId = sl['uom_id'] as String?
              ..uomLabel = uom?['description'] as String?
              ..uomConversionFactor = (sl['uom_conversion_factor'] as num? ?? 1).toDouble()
              ..matchedBarcode = sl['barcode'] as String?
              ..expiryDate = (sl['expiry_date'] as String?)?.isNotEmpty == true ? DateTime.tryParse(sl['expiry_date'] as String) : null
              ..manufacturingDate = (sl['manufacturing_date'] as String?)?.isNotEmpty == true ? DateTime.tryParse(sl['manufacturing_date'] as String) : null;
            row.qtyPackCtrl.text = ((sl['pack_qty'] as num?) ?? 0).toString();
            row.qtyLooseCtrl.text = ((sl['loose_qty'] as num?) ?? 0).toString();
            row.batchNoCtrl.text = sl['batch_no'] as String? ?? '';
            row.serialNoCtrl.text = sl['serial_no'] as String? ?? '';
            row.unitCostCtrl.text = ((sl['unit_cost'] as num?) ?? 0).toString();
            final ucs = sl['unit_cost_specific'] as num?;
            if (ucs != null) row.unitCostSpecificCtrl.text = ucs.toString();
            row.remarksCtrl.text = sl['remarks'] as String? ?? '';
            _lines.add(row);
          }
          unawaited(_refreshAllAlreadyEstablished());
        }
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  void _addLine() => setState(() => _lines.add(_OpeningLineRow()));
  void _removeLine(_OpeningLineRow row) => setState(() { _lines.remove(row); row.dispose(); });

  // ── Batched "already established" advisory check ────────────────────────
  // Replaces the old per-row live query (one call per line added) with a
  // single batched call for every product currently on the grid — avoids
  // N+1 calls once this screen also handles a large bulk import.
  Future<void> _refreshAllAlreadyEstablished() async {
    final ids = _lines.map((l) => l.productId).whereType<String>().toSet();
    if (_locationId == null || ids.isEmpty) return;
    setState(() => _checkingExisting = true);
    try {
      final session = ref.read(sessionProvider)!;
      final res = await DioClient.instance.get('/rim_product_location', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'location_id': 'eq.$_locationId', 'product_id': 'in.(${ids.join(',')})',
        'select': 'product_id,current_stock,cost_price',
      });
      final byProduct = {
        for (final r in (res.data as List)) (r as Map<String, dynamic>)['product_id'] as String: r,
      };
      if (!mounted) return;
      setState(() {
        for (final l in _lines) {
          final m = l.productId == null ? null : byProduct[l.productId];
          l.currentStock = m?['current_stock'] as num? ?? 0;
          l.currentCost = m?['cost_price'] as num? ?? 0;
        }
      });
    } catch (_) {
      // advisory only
    } finally {
      if (mounted) setState(() => _checkingExisting = false);
    }
  }

  Future<void> _onProductSelected(_OpeningLineRow row, Map<String, dynamic> product) async {
    setState(() {
      row.productId = product['id'] as String;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.uomId = product['base_uom_id'] as String?;
      final uom = product['uom'] as Map<String, dynamic>?;
      row.uomLabel = uom?['description'] as String?;
      row.trackingType = product['tracking_type'] as String? ?? 'NONE';
    });
    unawaited(_refreshAllAlreadyEstablished());
  }

  _OpeningLineRow _addLineFromProduct(
    Map<String, dynamic> product, {
    String? matchedCode,
    String? batchNo,
    String? expiryDateStr,
    String? manufacturingDateStr,
    String? serialNo,
    double? packQty,
    double? looseQty,
    double? unitCost,
    double? unitCostSpecific,
    String? remarks,
  }) {
    final row = _OpeningLineRow()
      ..productId = product['id'] as String
      ..productDisplay = '[${product['product_code']}] ${product['product_name']}'
      ..uomId = product['base_uom_id'] as String?
      ..trackingType = product['tracking_type'] as String? ?? 'NONE'
      ..matchedBarcode = matchedCode;
    final uom = product['uom'] as Map<String, dynamic>?;
    row.uomLabel = uom?['description'] as String?;
    if (batchNo != null && batchNo.isNotEmpty) row.batchNoCtrl.text = batchNo;
    if (expiryDateStr != null && expiryDateStr.isNotEmpty) row.expiryDate = DateTime.tryParse(expiryDateStr);
    if (manufacturingDateStr != null && manufacturingDateStr.isNotEmpty) row.manufacturingDate = DateTime.tryParse(manufacturingDateStr);
    if (serialNo != null && serialNo.isNotEmpty) row.serialNoCtrl.text = serialNo;
    if (packQty != null) row.qtyPackCtrl.text = packQty.toString();
    if (looseQty != null) row.qtyLooseCtrl.text = looseQty.toString();
    if (unitCost != null) row.unitCostCtrl.text = unitCost.toString();
    if (unitCostSpecific != null) row.unitCostSpecificCtrl.text = unitCostSpecific.toString();
    if (remarks != null && remarks.isNotEmpty) row.remarksCtrl.text = remarks;
    setState(() => _lines.add(row));
    return row;
  }

  /// Supermarket-style scan-to-add: resolves by product only, ignoring
  /// batch/serial. An existing line for the same product prompts
  /// Create-new-vs-Update-existing rather than silently guessing.
  Future<void> _onScanSubmitted(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    Map<String, dynamic>? match;
    try {
      match = await _ds.getProductByCode(
        clientId: session.clientId, companyId: session.companyId,
        code: code, tryPartNumber: session.enablePartNumber,
      );
    } catch (e, st) {
      AppLogger.error('OpeningStockScanLookup', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'look up this barcode/part number'), color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    if (match == null) { _showSnack('No product found for "$code".', color: AppColors.negative); _scanCtrl.clear(); return; }
    final matchedProduct = match;

    final existing = _lines.where((l) => l.productId == matchedProduct['id']).toList();
    if (existing.isEmpty) {
      _addLineFromProduct(matchedProduct, matchedCode: code);
      unawaited(_refreshAllAlreadyEstablished());
      _scanCtrl.clear();
      return;
    }

    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Product already in this list'),
        content: Text('[${matchedProduct['product_code']}] ${matchedProduct['product_name']} is already selected. '
            'Create a new line, or update the existing one?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(null), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop('create'), child: const Text('Create New')),
          FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop('update'), child: const Text('Update Existing')),
        ],
      ),
    );
    if (choice == 'update') {
      final row = existing.last; // most-recently-touched line for this product
      setState(() => row.qtyPackCtrl.text = (row.qtyPack + 1).toString());
    } else if (choice == 'create') {
      _addLineFromProduct(matchedProduct, matchedCode: code);
      unawaited(_refreshAllAlreadyEstablished());
    }
    _scanCtrl.clear();
  }

  // ── Excel template / upload — always pre-filled from Product Master ────
  // (adopted from the retired Value Upload screen — strictly better than a
  // blank-header template for every use case, including a quick manual
  // top-up: delete the rows you don't need, or just use Add Line/Scan).

  Future<void> _downloadTemplate() async {
    final session = ref.read(sessionProvider)!;
    final showLoose = (session.qtyEntryMode) != 'PACK_ONLY';
    final headers = [
      'Product Code', 'Product Name', 'Unit',
      showLoose ? 'Qty Pack' : 'Quantity', if (showLoose) 'Qty Loose',
      'Batch No', 'Expiry Date', 'Manufacturing Date', 'Serial No',
      'Unit Cost', 'Unit Cost (Product Currency)', 'Remarks',
    ];
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    sheet.appendRow(headers.map((h) => xls.TextCellValue(h)).toList());
    for (final p in _allProducts) {
      final uom = p['uom'] as Map<String, dynamic>?;
      final row = <xls.CellValue>[
        xls.TextCellValue(p['product_code'] as String? ?? ''),
        xls.TextCellValue(p['product_name'] as String? ?? ''),
        xls.TextCellValue(uom?['description'] as String? ?? ''),
      ];
      for (var i = 0; i < headers.length - 3; i++) {
        row.add(xls.TextCellValue(''));
      }
      sheet.appendRow(row);
    }
    final bytes = workbook.encode();
    if (bytes == null) return;
    await _saveWorkbookBytes(bytes, 'opening_stock_template.xlsx', 'Save Opening Stock template');
  }

  // FilePicker.platform.saveFile() goes through Chrome's File System Access
  // API on web, which requires a still-valid "user activation" — timing-
  // sensitive enough that it silently failed here (real bug, caught live).
  // Same fix already proven in lib/core/reporting/report_excel_export.dart:
  // a Blob+anchor download on web, FilePicker unchanged on every other
  // platform.
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
    if (bytes == null) { _showSnack('Could not read the selected file.', color: AppColors.negative); return; }

    setState(() => _uploadingExcel = true);
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) { _showSnack('The file has no sheets.', color: AppColors.negative); return; }
      final sheet = workbook.tables[workbook.tables.keys.first]!;
      if (sheet.maxRows < 2) { _showSnack('No data rows found below the header.', color: AppColors.negative); return; }

      final session = ref.read(sessionProvider)!;
      final byCode = {
        for (final p in _allProducts.isNotEmpty ? _allProducts : await _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId))
          (p['product_code'] as String).toUpperCase(): p,
      };

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxCode     = col('product code');
      final idxBatch    = col('batch no');
      final idxExpiry   = col('expiry date');
      final idxMfgDate  = col('manufacturing date');
      final idxSerial   = col('serial no');
      final idxPack     = col('qty pack') != -1 ? col('qty pack') : col('quantity');
      final idxLoose    = col('qty loose');
      final idxCost     = col('unit cost');
      final idxCostSpec = col('unit cost (product currency)');
      final idxRemarks  = col('remarks');

      if (idxCode == -1 || idxPack == -1 || idxCost == -1) {
        _showSnack('Missing required column(s): Product Code, Qty Pack/Quantity, Unit Cost.', color: AppColors.negative);
        return;
      }

      String cellStr(List<xls.Data?> row, int idx) =>
          (idx == -1 || idx >= row.length) ? '' : (row[idx]?.value?.toString().trim() ?? '');

      var added = 0;
      final errors = <String>[];
      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        final code = cellStr(row, idxCode);
        if (code.isEmpty) continue;
        final product = byCode[code.toUpperCase()];
        if (product == null) { errors.add('Row ${r + 1}: product code "$code" not found.'); continue; }
        final packQty  = double.tryParse(cellStr(row, idxPack)) ?? 0;
        final looseQty = idxLoose == -1 ? 0.0 : (double.tryParse(cellStr(row, idxLoose)) ?? 0);
        final cost     = double.tryParse(cellStr(row, idxCost)) ?? 0;
        if (packQty <= 0 && looseQty <= 0) { errors.add('Row ${r + 1}: "$code" has no quantity.'); continue; }
        if (cost <= 0) { errors.add('Row ${r + 1}: "$code" is missing a unit cost.'); continue; }
        final costSpecStr = idxCostSpec == -1 ? '' : cellStr(row, idxCostSpec);
        _addLineFromProduct(
          product,
          batchNo: idxBatch == -1 ? null : cellStr(row, idxBatch),
          expiryDateStr: idxExpiry == -1 ? null : cellStr(row, idxExpiry),
          manufacturingDateStr: idxMfgDate == -1 ? null : cellStr(row, idxMfgDate),
          serialNo: idxSerial == -1 ? null : cellStr(row, idxSerial),
          packQty: packQty, looseQty: looseQty, unitCost: cost,
          unitCostSpecific: costSpecStr.isEmpty ? null : double.tryParse(costSpecStr),
          remarks: idxRemarks == -1 ? null : cellStr(row, idxRemarks),
        );
        added++;
      }

      if (!mounted) return;
      unawaited(_refreshAllAlreadyEstablished());
      if (errors.isNotEmpty) {
        _showSnack('$added row(s) added, ${errors.length} row(s) skipped.', color: Colors.orange);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Rows skipped'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(child: Text(errors.join('\n'))),
            ),
            actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('OK'))],
          ),
        );
      } else {
        _showSnack('$added row(s) added from Excel.', color: AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('OpeningStockExcelUpload', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'upload this Excel file'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _uploadingExcel = false);
    }
  }

  // ── GL posting toggle ────────────────────────────────────────────────────

  void _onPostGlChanged(bool? v) {
    if (v == true && _fyStartDate == null) {
      _showSnack('No Financial Year is configured for this company — set one up first.', color: AppColors.negative);
      return;
    }
    setState(() {
      _postGl = v ?? false;
      if (_postGl) _openingDate = _fyStartDate!;
    });
  }

  // ── Save / Approve ───────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_locationId == null) { _showSnack('Select a Store/Location.', color: AppColors.negative); return false; }
    final validLines = _lines.where((l) => l.productId != null && l.baseQty > 0).toList();
    if (validLines.isEmpty) { _showSnack('Add at least one line with a product and quantity.', color: AppColors.negative); return false; }
    for (final l in validLines) {
      if (l.unitCost <= 0) { _showSnack('Enter a unit cost for "${l.productDisplay}".', color: AppColors.negative); return false; }
      if (l.isBatchTracked && l.batchNoCtrl.text.trim().isEmpty) { _showSnack('Enter a batch number for "${l.productDisplay}".', color: AppColors.negative); return false; }
      if (l.isSerialTracked && l.serialNoCtrl.text.trim().isEmpty) { _showSnack('Enter a serial number for "${l.productDisplay}".', color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':     session.clientId,
        'company_id':    session.companyId,
        'location_id':   _locationId,
        'opening_no':    _openingNo,
        'opening_date':  _fmtDate(_openingDate),
        'remarks':       _remarksCtrl.text.trim(),
        'post_gl':       _postGl,
      };
      final lines = validLines.asMap().entries.map((e) => {
        'line_no':               e.key + 1,
        'product_id':            e.value.productId,
        'uom_id':                e.value.uomId,
        'uom_conversion_factor': e.value.uomConversionFactor,
        'pack_qty':              e.value.qtyPack,
        'loose_qty':             e.value.qtyLoose,
        'base_qty':              e.value.baseQty,
        'batch_no':              e.value.isBatchTracked ? e.value.batchNoCtrl.text.trim() : null,
        'expiry_date':           e.value.isBatchTracked && e.value.expiryDate != null ? _fmtDate(e.value.expiryDate!) : null,
        'manufacturing_date':    e.value.isBatchTracked && e.value.manufacturingDate != null ? _fmtDate(e.value.manufacturingDate!) : null,
        'serial_no':             e.value.isSerialTracked ? e.value.serialNoCtrl.text.trim() : null,
        'unit_cost':             e.value.unitCost,
        'unit_cost_specific':    e.value.unitCostSpecific,
        'barcode':                e.value.matchedBarcode ?? '',
        'remarks':                e.value.remarksCtrl.text.trim(),
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'OPENING_STOCK',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_opening_stock',
          payload:      {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
        );
        await _ds.cacheOpeningStockLocally(effectiveOpeningNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() { _openingNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final openingNo = await _ds.save(header: header, lines: lines, userId: session.userId);
        unawaited(_ds.cacheOpeningStockLocally(effectiveOpeningNo: openingNo, header: header, lines: lines));
        if (mounted) {
          setState(() { _openingNo = openingNo; _saving = false; });
          _showSnack('Opening Stock $openingNo saved.', color: AppColors.positive);
        }
      }
      return true;
    } on DioException catch (e) {
      setState(() { _saving = false; _actionError = e.response?.data?['message'] ?? _serverError(e); });
      return false;
    } catch (e) {
      setState(() { _saving = false; _actionError = 'Unexpected error: $e'; });
      return false;
    }
  }

  Future<void> _approveOpeningStock() async {
    if (_openingNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;
    if (_openingDate.isAfter(DateTime.now())) {
      _showSnack('Opening date cannot be in the future.', color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Opening Stock'),
        content: Text(_postGl
            ? 'Once approved, stock and cost will be established for every line, and a journal entry will be '
                'posted debiting each product\'s Stock Account (Cr Opening Stock Equity Account). This entry can '
                'no longer be edited. This cannot be undone. Continue?'
            : 'Once approved, stock and cost will be established for every line and this entry can no longer be edited. '
                'This does not post any accounting entry. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final session = ref.read(sessionProvider)!;
    setState(() { _approving = true; _actionError = null; });
    try {
      await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        openingNo: _openingNo!, openingDate: _fmtDate(_openingDate), approvedBy: session.userId,
      );
      if (mounted) {
        setState(() => _status = 'APPROVED');
        _showSnack('Opening Stock $_openingNo approved.', color: AppColors.positive);
        await _init();
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    return e.message ?? e.toString();
  }

  String _locationLabel(String? id) {
    if (id == null) return '';
    final match = _locations.where((l) => l['id'] == id).toList();
    return match.isNotEmpty ? match.first['location_name'] as String? ?? '' : '';
  }

  // _users is loaded once in _init() (getUsers, id+full_name) — reused here
  // rather than a fresh query, same as every other UUID->name resolution
  // already done on this screen.
  String? _resolveUserName(String? userId) {
    if (userId == null) return null;
    final match = _users.firstWhere((u) => u['id'] == userId, orElse: () => const {});
    return match['full_name'] as String?;
  }

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) => {
    'company': company,
    'header': {
      'opening_no':    _openingNo ?? '',
      'opening_date':  _displayDate(_openingDate),
      'status':        _status,
      'location_name': _locationLabel(_locationId),
      'remarks':       _remarksCtrl.text,
    },
    'lines': _lines.map((l) => {
      'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
      'batch_no':     l.batchNoCtrl.text,
      'serial_no':    l.serialNoCtrl.text,
      'base_qty':     l.baseQty,
      'unit_cost':    l.unitCost,
      'amount':       l.baseQty * l.unitCost,
    }).toList(),
    'signatures': {
      'prepared_by':   _preparedByName,
      'authorised_by': _authorisedByName,
    },
  };

  Future<void> _printOpeningStock() async {
    if (_openingNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('OPENING_STOCK').future);
      final document = _buildPrintDocument(company);
      final session = ref.read(sessionProvider);
      await PrintEngine.printDocument(
        template: template,
        document: document,
        filename: '$_openingNo.pdf',
        printedByName: session?.fullName,
        printedOn: DateTime.now(),
      );
    } catch (e, st) {
      AppLogger.error('OpeningStockPrint', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'print this opening stock'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Widget _buildPrintButton() => Tooltip(
    message: _printing ? 'Preparing PDF…' : 'Print / Save as PDF',
    child: IconButton(
      icon: _printing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.print_outlined),
      color: AppColors.primary,
      onPressed: _printing ? null : _printOpeningStock,
    ),
  );

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime? d) {
    if (d == null) return 'Select date';
    const m = ['', 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> onPicked) async {
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d != null) onPicked(d);
  }

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final showLooseQty = (session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
    final showBarcode  = session?.enableBarcode ?? false;
    final showPartNo   = session?.enablePartNumber ?? false;
    final showScan     = showBarcode || showPartNo;

    final canSave     = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final showApprove = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;
    final locked      = _status != 'DRAFT';

    // Title/subtitle/status-badge/Print now live in the shared TopBar via
    // ScreenHeaderMixin — see CLAUDE.md's "Screen header" pattern. Save/
    // Approve stay here as a slim body row.
    refreshScreenHeader();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isOffline) const OfflineBanner(),
        if (isMobile && (canSave || showApprove))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: _buildActionButtons(canSave: canSave, canApprove: showApprove),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_error != null) ...[_errorBanner(_error!, onRetry: _init), const SizedBox(height: 16)],
                    if (_actionError != null) ...[_errorBanner(_actionError!), const SizedBox(height: 16)],
                    _buildHeaderCard(locked, isMobile, showScan),
                    const SizedBox(height: 12),
                    if (_lines.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${_lines.length} line(s)${_checkingExisting ? ' — checking existing stock…' : ''}',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                        ),
                      ),
                    Expanded(child: _buildLinesArea(locked, showLooseQty, isMobile)),
                    const SizedBox(height: 12),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool canApprove}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : _saveDraft,
      child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save Draft'),
    ),
    if (canSave && canApprove) const SizedBox(width: 12),
    if (canApprove) FilledButton(
      onPressed: _approving ? null : _approveOpeningStock,
      style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
      child: _approving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Approve'),
    ),
  ]);

  Widget _errorBanner(String msg, {VoidCallback? onRetry}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(color: AppColors.negative.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.negative.withValues(alpha: 0.3))),
    child: Row(children: [
      const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(msg, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
      if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
    ]),
  );

  Widget _buildHeaderCard(bool locked, bool isMobile, bool showScan) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final openingNoField = SakalFieldCard.readOnly(label: 'Opening No', value: _openingNo ?? '(auto on save)');
    final locationField = SakalFieldCard(
      label: 'Store / Location', required: true, editable: !locked,
      child: DropdownButtonFormField<String>(
        key: ValueKey(_locationId),
        decoration: bare, isExpanded: true, isDense: true, itemHeight: null, style: style,
        initialValue: _locationId,
        items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
            child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: style))).toList(),
        onChanged: locked ? null : (v) { setState(() => _locationId = v); unawaited(_refreshAllAlreadyEstablished()); },
      ),
    );
    final dateField = SakalFieldCard(
      label: 'Opening Date', required: true, editable: !locked && !_postGl,
      child: InkWell(
        onTap: (locked || _postGl) ? null : () => _pickDate(_openingDate, (d) => setState(() => _openingDate = d)),
        child: Row(children: [
          Expanded(child: Text(_displayDate(_openingDate), style: style)),
          Icon(_postGl ? Icons.lock_outline : Icons.calendar_today_outlined, size: 15, color: (locked || _postGl) ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final remarksField = SakalFieldCard(
      label: 'Remarks', editable: !locked,
      child: TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final scanField = SakalFieldCard(
      label: 'Scan Barcode/Part Number', editable: !locked,
      child: TextFormField(
        controller: _scanCtrl, enabled: !locked,
        decoration: bare.copyWith(prefixIcon: const Icon(Icons.qr_code_scanner, size: 18)),
        style: style,
        onFieldSubmitted: (v) => _onScanSubmitted(v),
      ),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SakalFieldRow(isMobile: isMobile, spans: const [2, 2, 2], children: [openingNoField, locationField, dateField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, spans: const [3, 2], children: [
            remarksField,
            if (showScan) scanField,
          ]),
          const SizedBox(height: 12),
          _buildPostGlToggle(locked),
          if (!locked) ...[const SizedBox(height: 12), _buildExcelButtons()],
        ]),
      ),
    );
  }

  Widget _buildPostGlToggle(bool locked) {
    return Row(children: [
      Checkbox(value: _postGl, onChanged: locked ? null : _onPostGlChanged),
      Expanded(
        child: GestureDetector(
          onTap: locked ? null : () => _onPostGlChanged(!_postGl),
          child: Text(
            'Post to Ledger (GL) — debits each product\'s Stock Account and credits the '
            'Opening Stock Equity Account. Locks the date to the financial year start.',
            style: TextStyle(fontSize: 12, color: _postGl ? AppColors.primary : AppColors.textSecondary, fontWeight: _postGl ? FontWeight.w600 : FontWeight.w400),
          ),
        ),
      ),
    ]);
  }

  Widget _buildExcelButtons() {
    if (!canExcelUpload) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      OutlinedButton.icon(
        onPressed: _uploadingExcel ? null : _uploadExcel,
        icon: _uploadingExcel
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.upload_file, size: 16),
        label: const Text('Upload Excel'),
      ),
      const SizedBox(width: 8),
      TextButton.icon(
        onPressed: _downloadTemplate,
        icon: const Icon(Icons.download, size: 16),
        label: const Text('Template'),
      ),
    ]);
  }

  // ── Lines area ───────────────────────────────────────────────────────────

  Widget _buildLinesArea(bool locked, bool showLooseQty, bool isMobile) {
    final showBatchColumns = _lines.any((l) => l.isBatchTracked);
    final showSerialColumn = _lines.any((l) => l.isSerialTracked);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Expanded(child: Text('Opening Stock Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (!locked) TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: _lines.isEmpty
                ? const Center(
                    child: Text('No lines yet — add a product, scan a barcode, or upload an Excel file.',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  )
                : isMobile
                    ? ListView.separated(
                        itemCount: _lines.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _buildMobileCard(_lines[i], i, locked, showLooseQty),
                      )
                    : _buildDesktopGrid(locked, showLooseQty, showBatchColumns, showSerialColumn),
          ),
        ]),
      ),
    );
  }

  // Sticky header + ListView.builder + synced horizontal scroll — the
  // proven fix from Bulk Upload Products / the (now-retired) Opening Stock
  // Value Upload screen this session (row-height gaps, missing horizontal
  // scrollbar, header-scrolls-away, and hang-at-~400-rows were all found
  // and fixed on that pattern). The old SakalScrollableTable-based grid
  // here was never exercised past a handful of manually-added lines — this
  // screen now also handles a full bulk import, so it needed the same fix.
  final _vController = ScrollController();
  final _hHeaderController = ScrollController();
  final _hBodyController = ScrollController();
  bool _syncingHScroll = false;

  void _syncHScroll(ScrollController source, ScrollController target) {
    if (_syncingHScroll || !target.hasClients) return;
    _syncingHScroll = true;
    target.jumpTo(source.offset);
    _syncingHScroll = false;
  }

  // Column widths depend on which optional columns are showing screen-
  // wide (showBatchColumns/showSerialColumn/showLooseQty) — computed
  // identically for the header and every row so they always line up. A
  // row that doesn't personally need a shown column still gets a blank
  // placeholder cell of the same width (CLAUDE.md's line-items grid
  // pattern), never a shifted layout.
  List<double> _colWidths(bool showLoose, bool showBatch, bool showSerial) => [
        36, 230,
        if (showBatch) ...[120, 110, 130],
        if (showSerial) 120,
        70, 100,
        if (showLoose) 90,
        100, 120, 150,
        70, 36,
      ];

  Widget _buildDesktopGrid(bool locked, bool showLoose, bool showBatch, bool showSerial) {
    final widths = _colWidths(showLoose, showBatch, showSerial);
    final totalWidth = widths.fold<double>(0, (a, b) => a + b);
    return Column(children: [
      SingleChildScrollView(
        controller: _hHeaderController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(width: totalWidth, child: _buildHeaderCells(widths, showLoose, showBatch, showSerial)),
      ),
      Expanded(
        child: Scrollbar(
          controller: _hBodyController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _hBodyController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth,
              child: Scrollbar(
                controller: _vController,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _vController,
                  itemCount: _lines.length,
                  itemExtent: 38,
                  itemBuilder: (_, i) => _buildDesktopRow(_lines[i], i, widths, locked, showLoose, showBatch, showSerial),
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

  Widget _buildHeaderCells(List<double> w, bool showLoose, bool showBatch, bool showSerial) {
    var i = 0;
    final cells = <Widget>[
      _headerCell('#', w[i++]),
      _headerCell('Product', w[i++]),
      if (showBatch) ...[_headerCell('Batch No', w[i++]), _headerCell('Expiry Date', w[i++]), _headerCell('Mfg Date', w[i++])],
      if (showSerial) _headerCell('Serial No', w[i++]),
      _headerCell('Unit', w[i++]),
      _headerCell(showLoose ? 'Qty Pack' : 'Quantity', w[i++]),
      if (showLoose) _headerCell('Qty Loose', w[i++]),
      _headerCell('Unit Cost', w[i++]),
      _headerCell('Cost (Product Ccy)', w[i++]),
      _headerCell('Remarks', w[i++]),
      _headerCell('Status', w[i++]),
      _headerCell('', w[i++]),
    ];
    return Row(children: cells);
  }

  InputDecoration get _cellInputDecoration => const InputDecoration(
        isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6), border: InputBorder.none,
      );

  Widget _cell(Widget child, double width) => Container(width: width, decoration: _gridCellDecoration, child: child);

  bool get _isLocked => _status != 'DRAFT';

  Widget _textField(TextEditingController ctrl, {TextInputType? keyboardType, TextAlign align = TextAlign.left, bool enabled = true}) => TextFormField(
        controller: ctrl, enabled: enabled && !_isLocked,
        keyboardType: keyboardType, textAlign: align,
        style: const TextStyle(fontSize: _gridFontSize), decoration: _cellInputDecoration,
        onChanged: (_) => setState(() {}),
      );

  Widget _statusCell(_OpeningLineRow row, double width) => Container(
        width: width, alignment: Alignment.center, decoration: _gridCellDecoration,
        child: row.alreadyEstablished
            ? Tooltip(
                message: 'Already has qty ${row.currentStock} / cost ${row.currentCost} at this location — Approve will be blocked.',
                child: const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.negative),
              )
            : const Icon(Icons.check_circle_outline, size: 14, color: AppColors.positive),
      );

  Widget _productCell(_OpeningLineRow row, double width, bool locked) => Container(
        width: width, decoration: _gridCellDecoration, padding: const EdgeInsets.symmetric(horizontal: 2),
        child: SakalAutocomplete<Map<String, dynamic>>(
          key: ValueKey('${row.hashCode}-${row.productDisplay}'),
          initialValue: TextEditingValue(text: row.productDisplay),
          displayStringForOption: (p) => '[${p['product_code']}] ${p['product_name']}',
          optionsBuilder: (v) async {
            if (locked) return const [];
            final session = ref.read(sessionProvider)!;
            return _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: v.text);
          },
          onSelected: (p) => _onProductSelected(row, p),
          enabled: !locked,
          decoration: _cellInputDecoration,
          style: const TextStyle(fontSize: _gridFontSize),
        ),
      );

  Widget _expiryCell(_OpeningLineRow row, bool locked) => InkWell(
        onTap: (!row.isBatchTracked || locked) ? null : () async {
          final d = await showDatePicker(context: context, initialDate: row.expiryDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (d != null) setState(() => row.expiryDate = d);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(row.isBatchTracked ? _displayDate(row.expiryDate) : '', style: const TextStyle(fontSize: _gridFontSize)),
        ),
      );

  Widget _mfgCell(_OpeningLineRow row, bool locked) => InkWell(
        onTap: (!row.isBatchTracked || locked) ? null : () async {
          final d = await showDatePicker(context: context, initialDate: row.manufacturingDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (d != null) setState(() => row.manufacturingDate = d);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(row.isBatchTracked ? _displayDate(row.manufacturingDate) : '', style: const TextStyle(fontSize: _gridFontSize)),
        ),
      );

  Widget _buildDesktopRow(_OpeningLineRow row, int index, List<double> w, bool locked, bool showLoose, bool showBatch, bool showSerial) {
    var i = 0;
    final cells = <Widget>[
      Container(
        width: w[i++], alignment: Alignment.center, decoration: _gridCellDecoration,
        child: Text('${index + 1}', style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textSecondary)),
      ),
      _productCell(row, w[i++], locked),
      if (showBatch) ...[
        _cell(_textField(row.batchNoCtrl, enabled: row.isBatchTracked), w[i++]),
        _cell(_expiryCell(row, locked), w[i++]),
        _cell(_mfgCell(row, locked), w[i++]),
      ],
      if (showSerial) _cell(_textField(row.serialNoCtrl, enabled: row.isSerialTracked), w[i++]),
      Container(
        width: w[i++], alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 4), decoration: _gridCellDecoration,
        child: Text(row.uomLabel ?? '—', style: const TextStyle(fontSize: _gridFontSize), overflow: TextOverflow.ellipsis),
      ),
      _cell(_textField(row.qtyPackCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), w[i++]),
      if (showLoose) _cell(_textField(row.qtyLooseCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), w[i++]),
      _cell(_textField(row.unitCostCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), w[i++]),
      _cell(_textField(row.unitCostSpecificCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), w[i++]),
      _cell(_textField(row.remarksCtrl), w[i++]),
      _statusCell(row, w[i++]),
      Container(
        width: w[i++], decoration: _gridCellDecoration,
        child: locked ? null : IconButton(
          padding: EdgeInsets.zero, iconSize: 14, icon: const Icon(Icons.close),
          onPressed: () => _removeLine(row),
          tooltip: 'Remove line',
        ),
      ),
    ];
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells);
  }

  Widget _buildMobileCard(_OpeningLineRow row, int idx, bool locked, bool showLooseQty) {
    final fields = <Widget>[
      SizedBox(
        width: double.infinity,
        child: SakalAutocomplete<Map<String, dynamic>>(
          key: ValueKey('${row.hashCode}-${row.productDisplay}'),
          initialValue: TextEditingValue(text: row.productDisplay),
          displayStringForOption: (p) => '[${p['product_code']}] ${p['product_name']}',
          optionsBuilder: (v) async {
            if (locked) return const [];
            final session = ref.read(sessionProvider)!;
            return _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: v.text);
          },
          onSelected: (p) => _onProductSelected(row, p),
          enabled: !locked,
          decoration: const InputDecoration(labelText: 'Product'),
        ),
      ),
      if (row.isBatchTracked) TextFormField(controller: row.batchNoCtrl, enabled: !locked, decoration: const InputDecoration(labelText: 'Batch No')),
      if (row.isBatchTracked) InkWell(
        onTap: locked ? null : () async {
          final d = await showDatePicker(context: context, initialDate: row.expiryDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (d != null) setState(() => row.expiryDate = d);
        },
        child: InputDecorator(decoration: const InputDecoration(labelText: 'Expiry Date'), child: Text(row.expiryDate != null ? _displayDate(row.expiryDate) : '—')),
      ),
      if (row.isSerialTracked) TextFormField(controller: row.serialNoCtrl, enabled: !locked, decoration: const InputDecoration(labelText: 'Serial No')),
      TextFormField(controller: row.qtyPackCtrl, enabled: !locked, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: showLooseQty ? 'Qty Pack' : 'Quantity')),
      if (showLooseQty) TextFormField(controller: row.qtyLooseCtrl, enabled: !locked, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Qty Loose')),
      TextFormField(controller: row.unitCostCtrl, enabled: !locked, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Unit Cost')),
      TextFormField(controller: row.unitCostSpecificCtrl, enabled: !locked, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Cost (Product Currency)')),
      TextFormField(controller: row.remarksCtrl, enabled: !locked, decoration: const InputDecoration(labelText: 'Remarks')),
    ];
    return SakalLineItemCard(
      title: '${idx + 1}. ${row.productDisplay.isEmpty ? 'New Line' : row.productDisplay}',
      onDelete: locked ? null : () => _removeLine(row),
      fields: const [],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (row.alreadyEstablished)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('Already has stock/cost at this location — Approve will be blocked.', style: TextStyle(fontSize: 11, color: AppColors.negative, fontWeight: FontWeight.w600)),
            ),
          for (final f in fields) ...[f, const SizedBox(height: 8)],
        ],
      ),
    );
  }
}

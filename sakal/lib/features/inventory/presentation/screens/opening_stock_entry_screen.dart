import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../domain/repositories/opening_stock_repository.dart';
import '../providers/opening_stock_providers.dart';

/// One physical lot/unit — the module's own deliberate divergence from
/// every other module's "line + child batch/serial table" shape. Batch,
/// expiry and serial live flat on the row; there is no direction flag
/// (Opening Stock only ever establishes NEW lots, GRN-style).
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
  final TextEditingController remarksCtrl   = TextEditingController();
  String? matchedBarcode;
  num? currentStock;
  num? currentCost;

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get baseQty  => qtyPack * uomConversionFactor + qtyLoose;
  double get unitCost => double.tryParse(unitCostCtrl.text) ?? 0;

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  /// Advisory only — the real OPENING_STOCK_ALREADY_ESTABLISHED guard is
  /// server-side, at Approve.
  bool get alreadyEstablished => (currentStock ?? 0) != 0 || (currentCost ?? 0) != 0;

  void dispose() {
    qtyPackCtrl.dispose(); qtyLooseCtrl.dispose(); batchNoCtrl.dispose();
    serialNoCtrl.dispose(); unitCostCtrl.dispose(); remarksCtrl.dispose();
  }
}

class OpeningStockEntryScreen extends ConsumerStatefulWidget {
  final String? editOpeningNo;
  final String? editOpeningDate;
  const OpeningStockEntryScreen({super.key, this.editOpeningNo, this.editOpeningDate});

  @override
  ConsumerState<OpeningStockEntryScreen> createState() => _OpeningStockEntryScreenState();
}

class _OpeningStockEntryScreenState extends ConsumerState<OpeningStockEntryScreen>
    with ScreenPermissionMixin<OpeningStockEntryScreen> {
  @override String get screenName => RouteNames.openingStock;

  OpeningStockRepository get _ds => ref.read(openingStockRepositoryProvider);

  String?  _openingNo;
  DateTime _openingDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  final _remarksCtrl = TextEditingController();
  final _scanCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  final List<_OpeningLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _printing = false;
  bool    _uploadingExcel = false;

  bool get _isNew => _openingNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    _scanCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _locations = await _ds.getLocations(clientId: session.clientId, companyId: session.companyId);

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
          _remarksCtrl.text = header['remarks'] as String? ?? '';

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
            row.remarksCtrl.text = sl['remarks'] as String? ?? '';
            _lines.add(row);
          }
        }
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  void _addLine() => setState(() => _lines.add(_OpeningLineRow()));
  void _removeLine(_OpeningLineRow row) => setState(() { _lines.remove(row); row.dispose(); });

  Future<void> _refreshCurrentStock(_OpeningLineRow row) async {
    if (row.productId == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    try {
      final r = await _ds.getCurrentStockAndCost(
        clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
      );
      if (mounted) setState(() { row.currentStock = r?['current_stock'] as num? ?? 0; row.currentCost = r?['cost_price'] as num? ?? 0; });
    } catch (_) { /* advisory only */ }
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
    unawaited(_refreshCurrentStock(row));
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
    if (remarks != null && remarks.isNotEmpty) row.remarksCtrl.text = remarks;
    setState(() => _lines.add(row));
    unawaited(_refreshCurrentStock(row));
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
    } catch (e) {
      if (mounted) _showSnack('Lookup failed: $e', color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    if (match == null) { _showSnack('No product found for "$code".', color: AppColors.negative); _scanCtrl.clear(); return; }
    final matchedProduct = match;

    final existing = _lines.where((l) => l.productId == matchedProduct['id']).toList();
    if (existing.isEmpty) {
      _addLineFromProduct(matchedProduct, matchedCode: code);
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
    }
    _scanCtrl.clear();
  }

  // ── Excel upload ─────────────────────────────────────────────────────────

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
      final products = await _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId);
      final byCode = {for (final p in products) (p['product_code'] as String).toUpperCase(): p};

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxCode    = col('product_code');
      final idxBatch   = col('batch_no');
      final idxExpiry  = col('expiry_date');
      final idxMfgDate = col('manufacturing_date');
      final idxSerial  = col('serial_no');
      final idxPack    = col('pack_qty');
      final idxLoose   = col('loose_qty');
      final idxCost    = col('unit_cost');
      final idxRemarks = col('remarks');

      if (idxCode == -1 || idxPack == -1 || idxCost == -1) {
        _showSnack('Missing required column(s): product_code, pack_qty, unit_cost.', color: AppColors.negative);
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
        _addLineFromProduct(
          product,
          batchNo: idxBatch == -1 ? null : cellStr(row, idxBatch),
          expiryDateStr: idxExpiry == -1 ? null : cellStr(row, idxExpiry),
          manufacturingDateStr: idxMfgDate == -1 ? null : cellStr(row, idxMfgDate),
          serialNo: idxSerial == -1 ? null : cellStr(row, idxSerial),
          packQty: packQty, looseQty: looseQty, unitCost: cost,
          remarks: idxRemarks == -1 ? null : cellStr(row, idxRemarks),
        );
        added++;
      }

      if (!mounted) return;
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
    } catch (e) {
      if (mounted) _showSnack('Excel upload failed: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _uploadingExcel = false);
    }
  }

  Future<void> _downloadTemplate() async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    const headers = ['product_code', 'batch_no', 'expiry_date', 'manufacturing_date', 'serial_no', 'pack_qty', 'loose_qty', 'unit_cost', 'remarks'];
    sheet.appendRow(headers.map((h) => xls.TextCellValue(h)).toList());
    final bytes = workbook.encode();
    if (bytes == null) return;
    await FilePicker.platform.saveFile(
      dialogTitle: 'Save Opening Stock template',
      fileName: 'opening_stock_template.xlsx',
      bytes: Uint8List.fromList(bytes),
      type: FileType.custom, allowedExtensions: ['xlsx'],
    );
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
        content: const Text('Once approved, stock and cost will be established for every line and this entry can no longer be edited. '
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
  };

  Future<void> _printOpeningStock() async {
    if (_openingNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('OPENING_STOCK').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_openingNo.pdf');
    } catch (e) {
      if (mounted) _showSnack('Print failed: $e', color: AppColors.negative);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildTitleBlock(),
                  if (_openingNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_openingNo != null) _buildPrintButton(),
                      if (canSave || showApprove) Expanded(child: _buildActionButtons(canSave: canSave, canApprove: showApprove)),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_openingNo != null) _buildPrintButton(),
                  if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                ]),
        ),
        const Divider(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_error != null) ...[_errorBanner(_error!, onRetry: _init), const SizedBox(height: 16)],
                    if (_actionError != null) ...[_errorBanner(_actionError!), const SizedBox(height: 16)],
                    _buildHeaderCard(locked, isMobile, showScan),
                    const SizedBox(height: 16),
                    _buildLinesCard(locked, showLooseQty, isMobile),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (context.canPop())
        IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back', onPressed: () => context.pop()),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_openingNo != null ? 'Opening Stock · $_openingNo' : 'New Opening Stock',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        Row(children: [
          _status == 'APPROVED' ? _statusChip(_status) : Text(_openingNo != null ? 'Draft' : 'Unsaved draft',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (_openingNo != null) ...[
            const SizedBox(width: 8),
            PendingSyncBadge(documentType: 'OPENING_STOCK', documentId: _openingNo!),
          ],
        ]),
      ]),
    ],
  );

  Widget _statusChip(String status) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
    child: const Text('APPROVED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
  );

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
        decoration: bare, isExpanded: true, isDense: true, itemHeight: null, style: style,
        initialValue: _locationId,
        items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
            child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: style))).toList(),
        onChanged: locked ? null : (v) => setState(() => _locationId = v),
      ),
    );
    final dateField = SakalFieldCard(
      label: 'Opening Date', required: true, editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(_openingDate, (d) => setState(() => _openingDate = d)),
        child: Row(children: [
          Expanded(child: Text(_displayDate(_openingDate), style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SakalFieldRow(isMobile: isMobile, spans: const [2, 2, 2], children: [openingNoField, locationField, dateField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, spans: const [3, 2], children: [
            remarksField,
            if (showScan) scanField,
          ]),
          if (!locked) ...[const SizedBox(height: 12), _buildExcelButtons()],
        ]),
      ),
    );
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

  Widget _buildLinesCard(bool locked, bool showLooseQty, bool isMobile) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Opening Stock Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (!locked) TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
          ]),
          const SizedBox(height: 8),
          if (_lines.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet — add a product, scan a barcode, or upload an Excel file.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._lines.asMap().entries.map((e) => _buildLineCard(e.value, e.key, locked, showLooseQty, isMobile)),
        ]),
      ),
    );
  }

  Widget _buildLineCard(_OpeningLineRow row, int idx, bool locked, bool showLooseQty, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final productField = SakalFieldCard(
      label: 'Product', required: true, editable: !locked,
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
        decoration: bare,
        style: style,
      ),
    );
    final batchNoField = SakalFieldCard(
      label: 'Batch No', editable: !locked,
      child: TextFormField(controller: row.batchNoCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final expiryField = SakalFieldCard(
      label: 'Expiry Date', editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(row.expiryDate, (d) => setState(() => row.expiryDate = d)),
        child: Row(children: [
          Expanded(child: Text(row.expiryDate != null ? _displayDate(row.expiryDate) : '—', style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final mfgField = SakalFieldCard(
      label: 'Manufacturing Date', editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(row.manufacturingDate, (d) => setState(() => row.manufacturingDate = d)),
        child: Row(children: [
          Expanded(child: Text(row.manufacturingDate != null ? _displayDate(row.manufacturingDate) : '—', style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final serialNoField = SakalFieldCard(
      label: 'Serial No', editable: !locked,
      child: TextFormField(controller: row.serialNoCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final unitField = SakalFieldCard.readOnly(label: 'Unit', value: row.uomLabel ?? '—');
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Qty Pack' : 'Quantity', editable: !locked, numeric: true,
      child: TextFormField(
        controller: row.qtyPackCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Qty Loose', editable: !locked, numeric: true,
      child: TextFormField(
        controller: row.qtyLooseCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );
    final unitCostField = SakalFieldCard(
      label: 'Unit Cost', required: true, editable: !locked, numeric: true,
      child: TextFormField(
        controller: row.unitCostCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );
    final remarksField = SakalFieldCard(
      label: 'Remarks', editable: !locked,
      child: TextFormField(controller: row.remarksCtrl, enabled: !locked, decoration: bare, style: style),
    );

    return SakalLineItemCard(
      title: '${idx + 1}. ${row.productDisplay.isEmpty ? 'New Line' : row.productDisplay}',
      onDelete: locked ? null : () => _removeLine(row),
      fields: [
        SizedBox(width: isMobile ? double.infinity : 240, child: productField),
        if (row.isBatchTracked) SizedBox(width: 150, child: batchNoField),
        if (row.isBatchTracked) SizedBox(width: 150, child: expiryField),
        if (row.isBatchTracked) SizedBox(width: 160, child: mfgField),
        if (row.isSerialTracked) SizedBox(width: 150, child: serialNoField),
        SizedBox(width: 80, child: unitField),
        SizedBox(width: 110, child: qtyPackField),
        if (showLooseQty) SizedBox(width: 110, child: qtyLooseField),
        SizedBox(width: 110, child: unitCostField),
        SizedBox(width: 170, child: remarksField),
      ],
      body: row.alreadyEstablished
          ? Text(
              'This product already has stock (${row.currentStock}) / cost (${row.currentCost}) at this location — Approve will be blocked.',
              style: const TextStyle(fontSize: 11, color: AppColors.negative, fontWeight: FontWeight.w600),
            )
          : null,
    );
  }
}

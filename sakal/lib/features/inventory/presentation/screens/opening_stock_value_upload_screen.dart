import 'dart:async';
import 'dart:typed_data';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/reporting/web_download.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/deferred_row_disposal.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_header_action_button.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../providers/opening_stock_providers.dart';

/// Opening Stock — Value Upload (feature IN-OSV, route
/// /inventory/opening-stock-value-upload). A dedicated, bulk-upload-first
/// sibling of the existing Opening Stock screen (IN-OPN) — same underlying
/// engine (rih_opening_stock_headers/rid_opening_stock_lines,
/// fn_save_opening_stock/fn_approve_opening_stock, migration 193's own
/// extension), so the existing OPENING_STOCK_ALREADY_ESTABLISHED guard keeps
/// protecting BOTH screens from ever double-establishing the same
/// product/location, regardless of which one created the document.
///
/// Unlike the existing screen, this one ALSO posts GL (Dr each line's own
/// Stock Account, Cr a company-configured Opening Stock Equity Account),
/// dated at the company's financial year start (locked, not editable), and
/// Save is a single click that chains Save+Approve immediately (online-only
/// — no offline queue, since Approve always stays online-only in this app
/// and this screen always chains it).
///
/// Deliberately ONE flat "Qty" column, not a Pack/Loose split — unlike every
/// live line-entry screen in this app, this is a one-shot bulk value import
/// from a spreadsheet the user already has in base units; the company's
/// qty_entry_mode setting governs interactive entry screens, not this kind
/// of bulk import.
class OpeningStockValueUploadScreen extends ConsumerStatefulWidget {
  const OpeningStockValueUploadScreen({super.key});

  @override
  ConsumerState<OpeningStockValueUploadScreen> createState() => _OpeningStockValueUploadScreenState();
}

const _gridFontSize = 11.0;
const _gridRowVPad = 5.0;
final _gridCellDecoration = BoxDecoration(border: Border.all(color: AppColors.border, width: 0.6));

class _StockValueRow implements DisposableRow {
  String? productId;
  String  productCode = '';
  String  productName = '';
  String  trackingType = 'NONE';
  String? uomId;
  String  uomLabel = '';
  final TextEditingController qtyCtrl = TextEditingController();
  final TextEditingController batchNoCtrl = TextEditingController();
  DateTime? expiryDate;
  DateTime? manufacturingDate;
  final TextEditingController serialNoCtrl = TextEditingController();
  final TextEditingController priceBaseCtrl = TextEditingController();
  final TextEditingController priceProductCtrl = TextEditingController();
  num? currentStock;
  num? currentCost;

  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  double get priceBase => double.tryParse(priceBaseCtrl.text) ?? 0;
  double? get priceProduct => double.tryParse(priceProductCtrl.text);

  bool get isBatchTracked => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  /// Advisory only — the real OPENING_STOCK_ALREADY_ESTABLISHED guard is
  /// server-side, at Approve.
  bool get alreadyEstablished => (currentStock ?? 0) != 0 || (currentCost ?? 0) != 0;

  @override
  void dispose() {
    for (final c in [qtyCtrl, batchNoCtrl, serialNoCtrl, priceBaseCtrl, priceProductCtrl]) {
      c.dispose();
    }
  }
}

class _OpeningStockValueUploadScreenState extends ConsumerState<OpeningStockValueUploadScreen>
    with
        ScreenPermissionMixin<OpeningStockValueUploadScreen>,
        ScreenHeaderMixin<OpeningStockValueUploadScreen>,
        DeferredRowDisposal<OpeningStockValueUploadScreen> {
  @override
  String get screenName => RouteNames.openingStockValueUpload;

  List<_StockValueRow> _lines = [];
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _allProducts = [];
  String? _locationId;
  DateTime? _fyStartDate;

  bool _loading = true;
  String? _loadError;
  bool _uploadingExcel = false;
  bool _checkingExisting = false;
  bool _saving = false;
  String? _progressText;

  static const _uploadHeaders = [
    'Product Code', 'Product Name', 'Unit', 'Qty',
    'Batch No', 'Expiry Date', 'Manufacturing Date', 'Serial No',
    'Price (Base Currency)', 'Price (Product Currency)',
  ];

  String _norm(String s) => s.trim().toUpperCase();

  @override
  void initState() {
    super.initState();
    _hHeaderController.addListener(() => _syncHScroll(_hHeaderController, _hBodyController));
    _hBodyController.addListener(() => _syncHScroll(_hBodyController, _hHeaderController));
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

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

  Future<void> _init() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      final session = ref.read(sessionProvider)!;
      final ds = ref.read(openingStockRepositoryProvider);

      _locations = await ds.getLocations(clientId: session.clientId, companyId: session.companyId);
      _locationId = session.locationId;

      final fys = await ref.read(financialYearsProvider.future);
      if (fys.isEmpty) {
        setState(() { _loading = false; _loadError = 'No Financial Year is configured for this company. Set one up first (Finance → Financial Years) before uploading opening stock value.'; });
        return;
      }
      final active = fys.where((f) => f['is_active'] == true).toList();
      final chosen = active.isNotEmpty ? active.first : fys.last; // fys is fy_start_date DESC, so .last is the earliest
      _fyStartDate = DateTime.tryParse(chosen['fy_start_date'] as String);

      final productsRes = await DioClient.instance.get('/rim_products', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false', 'is_active': 'eq.true',
        'select': 'id,product_code,product_name,base_uom_id,tracking_type,'
            'uom:rim_common_masters!base_uom_id(description)',
        'order': 'product_code.asc', 'limit': '20000',
      });
      _allProducts = List<Map<String, dynamic>>.from(productsRes.data as List);

      if (mounted) setState(() => _loading = false);
    } catch (e, st) {
      AppLogger.error('OpeningStockValueUploadInit', e, st);
      if (mounted) setState(() { _loading = false; _loadError = ErrorPresenter.format(e, action: 'load this screen'); });
    }
  }

  // ── Template / Upload ──────────────────────────────────────────────────

  Future<void> _downloadTemplate() async {
    final workbook = xls.Excel.createExcel();
    final sheetName = workbook.getDefaultSheet()!;
    final sheet = workbook[sheetName];
    sheet.appendRow(_uploadHeaders.map((h) => xls.TextCellValue(h)).toList());
    for (final p in _allProducts) {
      final uom = p['uom'] as Map<String, dynamic>?;
      sheet.appendRow([
        xls.TextCellValue(p['product_code'] as String? ?? ''),
        xls.TextCellValue(p['product_name'] as String? ?? ''),
        xls.TextCellValue(uom?['description'] as String? ?? ''),
        xls.TextCellValue(''), xls.TextCellValue(''), xls.TextCellValue(''),
        xls.TextCellValue(''), xls.TextCellValue(''), xls.TextCellValue(''), xls.TextCellValue(''),
      ]);
    }
    final bytes = workbook.encode();
    if (bytes == null) return;
    await _saveWorkbookBytes(bytes, 'opening_stock_value_upload_template.xlsx', 'Save Opening Stock Value Upload template');
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
    if (bytes == null) { _showSnack('Could not read the selected file.', AppColors.negative); return; }

    setState(() => _uploadingExcel = true);
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) { _showSnack('The file has no sheets.', AppColors.negative); return; }
      final sheet = workbook.tables[workbook.tables.keys.first]!;
      if (sheet.maxRows < 2) { _showSnack('No data rows found below the header.', AppColors.negative); return; }

      final byCode = { for (final p in _allProducts) _norm(p['product_code'] as String): p };

      final headerCells = sheet.row(0);
      final headerNames = headerCells.map((c) => c?.value?.toString().trim().toLowerCase() ?? '').toList();
      int col(String name) => headerNames.indexOf(name);
      final idxCode     = col('product code');
      final idxQty      = col('qty');
      final idxBatch    = col('batch no');
      final idxExpiry   = col('expiry date');
      final idxMfgDate  = col('manufacturing date');
      final idxSerial   = col('serial no');
      final idxPriceBase    = col('price (base currency)');
      final idxPriceProduct = col('price (product currency)');

      if (idxCode == -1 || idxQty == -1 || idxPriceBase == -1) {
        _showSnack('Missing required column(s): Product Code, Qty, Price (Base Currency).', AppColors.negative);
        return;
      }

      String cellStr(List<xls.Data?> row, int idx) =>
          (idx == -1 || idx >= row.length) ? '' : (row[idx]?.value?.toString().trim() ?? '');

      final parsed = <_StockValueRow>[];
      final errors = <String>[];
      for (var r = 1; r < sheet.maxRows; r++) {
        final row = sheet.row(r);
        final code = cellStr(row, idxCode);
        if (code.isEmpty) continue;
        final product = byCode[_norm(code)];
        if (product == null) { errors.add('Row ${r + 1}: product code "$code" not found.'); continue; }
        final qtyStr = cellStr(row, idxQty);
        final priceStr = cellStr(row, idxPriceBase);
        if ((double.tryParse(qtyStr) ?? 0) <= 0) { errors.add('Row ${r + 1}: "$code" has no quantity.'); continue; }
        if ((double.tryParse(priceStr) ?? 0) <= 0) { errors.add('Row ${r + 1}: "$code" is missing Price (Base Currency).'); continue; }

        final line = _StockValueRow()
          ..productId = product['id'] as String
          ..productCode = product['product_code'] as String
          ..productName = product['product_name'] as String
          ..trackingType = product['tracking_type'] as String? ?? 'NONE'
          ..uomId = product['base_uom_id'] as String?
          ..uomLabel = (product['uom'] as Map<String, dynamic>?)?['description'] as String? ?? '';
        line.qtyCtrl.text = qtyStr;
        line.priceBaseCtrl.text = priceStr;
        line.priceProductCtrl.text = idxPriceProduct == -1 ? '' : cellStr(row, idxPriceProduct);
        line.batchNoCtrl.text = idxBatch == -1 ? '' : cellStr(row, idxBatch);
        line.serialNoCtrl.text = idxSerial == -1 ? '' : cellStr(row, idxSerial);
        final expiryStr = idxExpiry == -1 ? '' : cellStr(row, idxExpiry);
        if (expiryStr.isNotEmpty) line.expiryDate = DateTime.tryParse(expiryStr);
        final mfgStr = idxMfgDate == -1 ? '' : cellStr(row, idxMfgDate);
        if (mfgStr.isNotEmpty) line.manufacturingDate = DateTime.tryParse(mfgStr);
        parsed.add(line);
      }

      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() => _lines = parsed);
      unawaited(_refreshAlreadyEstablished());

      if (errors.isNotEmpty) {
        _showSnack('${parsed.length} row(s) loaded, ${errors.length} row(s) skipped.', Colors.orange);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Rows skipped'),
            content: SizedBox(width: 440, height: 320, child: SingleChildScrollView(child: Text(errors.join('\n')))),
            actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('OK'))],
          ),
        );
      } else {
        _showSnack('${parsed.length} row(s) loaded from Excel. Review below, then Save.', AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('OpeningStockValueUploadExcel', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'upload this Excel file'), AppColors.negative);
    } finally {
      if (mounted) setState(() => _uploadingExcel = false);
    }
  }

  // ── Advisory already-established check (UX only — real guard is server-side) ──

  Future<void> _refreshAlreadyEstablished() async {
    if (_locationId == null || _lines.isEmpty) return;
    setState(() => _checkingExisting = true);
    try {
      final session = ref.read(sessionProvider)!;
      final ids = _lines.map((l) => l.productId).whereType<String>().toSet().join(',');
      final res = await DioClient.instance.get('/rim_product_location', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'location_id': 'eq.$_locationId', 'product_id': 'in.($ids)',
        'select': 'product_id,current_stock,cost_price',
      });
      final byProduct = {
        for (final r in (res.data as List)) (r as Map<String, dynamic>)['product_id'] as String: r,
      };
      if (!mounted) return;
      setState(() {
        for (final l in _lines) {
          final m = byProduct[l.productId];
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

  // ── Save (chains Save + Approve in one click) ───────────────────────────

  Future<void> _save() async {
    if (_locationId == null) { _showSnack('Select a Store/Location.', AppColors.negative); return; }
    if (_lines.isEmpty) { _showSnack('Upload a file first.', AppColors.negative); return; }
    if (_fyStartDate == null) { _showSnack('No Financial Year start date resolved.', AppColors.negative); return; }
    for (final l in _lines) {
      if (l.qty <= 0) { _showSnack('"${l.productCode}" has no quantity.', AppColors.negative); return; }
      if (l.priceBase <= 0) { _showSnack('"${l.productCode}" is missing Price (Base Currency).', AppColors.negative); return; }
      if (l.isBatchTracked && l.batchNoCtrl.text.trim().isEmpty) { _showSnack('Enter a Batch No for "${l.productCode}".', AppColors.negative); return; }
      if (l.isSerialTracked && l.serialNoCtrl.text.trim().isEmpty) { _showSnack('Enter a Serial No for "${l.productCode}".', AppColors.negative); return; }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Post Opening Stock Value?'),
        content: Text(
          'This will establish opening quantity + cost for ${_lines.length} product(s) at the selected '
          'location, dated ${_fmtDate(_fyStartDate!)} (start of financial year), and post a journal entry '
          'debiting each product\'s Stock Account. This cannot be undone. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _saving = true; _progressText = 'Saving…'; });
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(openingStockRepositoryProvider);
    try {
      final header = {
        'client_id': session.clientId, 'company_id': session.companyId,
        'location_id': _locationId, 'opening_date': _fmtDate(_fyStartDate!),
        'post_gl': true,
      };
      final lines = _lines.asMap().entries.map((e) => {
        'line_no': e.key + 1,
        'product_id': e.value.productId,
        'uom_id': e.value.uomId,
        'uom_conversion_factor': 1,
        'pack_qty': e.value.qty, 'loose_qty': 0, 'base_qty': e.value.qty,
        'batch_no': e.value.isBatchTracked ? e.value.batchNoCtrl.text.trim() : null,
        'expiry_date': e.value.isBatchTracked && e.value.expiryDate != null ? _fmtDate(e.value.expiryDate!) : null,
        'manufacturing_date': e.value.isBatchTracked && e.value.manufacturingDate != null ? _fmtDate(e.value.manufacturingDate!) : null,
        'serial_no': e.value.isSerialTracked ? e.value.serialNoCtrl.text.trim() : null,
        'unit_cost': e.value.priceBase,
        'unit_cost_specific': e.value.priceProduct,
      }).toList();

      final openingNo = await ds.save(header: header, lines: lines, userId: session.userId);
      if (mounted) setState(() => _progressText = 'Posting $openingNo…');
      await ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        openingNo: openingNo, openingDate: _fmtDate(_fyStartDate!), approvedBy: session.userId,
      );

      if (!mounted) return;
      for (final l in _lines) {
        deferRowDisposal(l);
      }
      setState(() { _lines = []; _saving = false; _progressText = null; });
      _showSnack('Opening Stock $openingNo posted.', AppColors.positive);
    } catch (e, st) {
      AppLogger.error('OpeningStockValueUploadSave', e, st);
      if (mounted) _showSnack(ErrorPresenter.format(e, action: 'post this opening stock value'), AppColors.negative);
    } finally {
      if (mounted) setState(() { _saving = false; _progressText = null; });
    }
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime? d) {
    if (d == null) return '—';
    const m = ['', 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
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
      title: 'Opening Stock Value Upload',
      helpText: 'Upload opening quantity + cost from Excel — this also posts a journal entry '
          '(Dr Stock Account, Cr Opening Stock Equity Account) dated at the start of the financial year.',
      actions: showDesktopActions
          ? [
              if (canExcelUpload)
                SakalHeaderActionButton(label: 'Template', icon: Icons.download_outlined, kind: SakalActionKind.neutral, onPressed: busy ? null : _downloadTemplate),
              if (canExcelUpload)
                SakalHeaderActionButton(label: 'Upload Excel', icon: Icons.upload_file_outlined, kind: SakalActionKind.neutral, loading: _uploadingExcel, onPressed: busy ? null : _uploadExcel),
              SakalHeaderActionButton(label: 'Save', icon: Icons.save_outlined, kind: SakalActionKind.save, loading: _saving, onPressed: (busy || _lines.isEmpty) ? null : _save),
            ]
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    final session = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    final busy = _saving || _uploadingExcel;

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_loadError!, style: const TextStyle(color: AppColors.negative), textAlign: TextAlign.center),
        ),
      );
    }

    return PopScope(
      canPop: !busy,
      child: Stack(children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isOffline) const OfflineBanner(),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _buildHeaderRow(isMobile, busy),
            ),
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
            if (_lines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(
                  '${_lines.length} product(s) loaded${_checkingExisting ? ' — checking existing stock…' : ''}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
            Expanded(
              child: _lines.isEmpty
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.upload_file_outlined, size: 48, color: AppColors.textSecondary),
                        SizedBox(height: 12),
                        Text('Download the template, fill in Qty + Price, then upload it here.', style: TextStyle(color: AppColors.textSecondary)),
                      ]),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: isMobile
                          ? ListView.separated(
                              itemCount: _lines.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (_, i) => _buildMobileCard(_lines[i], i),
                            )
                          : _buildDesktopGrid(),
                    ),
            ),
          ],
        ),
        if (busy) _buildBusyOverlay(),
      ]),
    );
  }

  Widget _buildHeaderRow(bool isMobile, bool busy) {
    final locationField = DropdownButtonFormField<String>(
      decoration: const InputDecoration(labelText: 'Store / Location', isDense: true, border: OutlineInputBorder()),
      isExpanded: true, itemHeight: null,
      initialValue: _locationId,
      items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: busy ? null : (v) { setState(() => _locationId = v); unawaited(_refreshAlreadyEstablished()); },
    );
    final dateField = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(4)),
      child: Row(children: [
        const Icon(Icons.lock_outline, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Text('Posting Date: ${_displayDate(_fyStartDate)} (start of financial year)', style: const TextStyle(fontSize: 13)),
      ]),
    );
    if (isMobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        locationField, const SizedBox(height: 8), dateField,
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(flex: 2, child: locationField),
      const SizedBox(width: 12),
      Expanded(flex: 3, child: dateField),
    ]);
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
                Text(_progressText ?? (_uploadingExcel ? 'Reading Excel file…' : 'Saving…'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text('Please don\'t close or navigate away from this screen.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ]),
            ),
          ),
        ),
      );

  // Sticky header + ListView.builder + synced horizontal scroll — same
  // proven fix as bulk_upload_products_screen.dart this session (row-height
  // gaps / missing horizontal scrollbar / header scrolling away / hang on
  // large files were all found live on that screen; reused here from the
  // start rather than re-discovering the same bugs on a second screen).
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

  static const _colWidths = <double>[44, 130, 220, 80, 90, 120, 120, 130, 110, 110, 130, 36];
  static final _gridTotalWidth = _colWidths.fold<double>(0, (a, b) => a + b);

  Widget _buildDesktopGrid() {
    final showBatchColumns = _lines.any((l) => l.isBatchTracked);
    final showSerialColumn = _lines.any((l) => l.isSerialTracked);
    return Column(children: [
      SingleChildScrollView(
        controller: _hHeaderController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(width: _gridTotalWidth, child: _buildHeaderCells()),
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
                  itemBuilder: (_, i) => _buildDesktopRow(_lines[i], i, showBatchColumns, showSerialColumn),
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

  Widget _buildHeaderCells() => Row(children: [
        _headerCell('#', _colWidths[0]),
        _headerCell('Product Code', _colWidths[1]),
        _headerCell('Product Name', _colWidths[2]),
        _headerCell('Unit', _colWidths[3]),
        _headerCell('Qty', _colWidths[4]),
        _headerCell('Batch No', _colWidths[5]),
        _headerCell('Expiry Date', _colWidths[6]),
        _headerCell('Serial No', _colWidths[7]),
        _headerCell('Price (Base)', _colWidths[8]),
        _headerCell('Price (Product Ccy)', _colWidths[9]),
        _headerCell('Status', _colWidths[10]),
        _headerCell('', _colWidths[11]),
      ]);

  InputDecoration get _cellInputDecoration => const InputDecoration(
        isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6), border: InputBorder.none,
      );

  Widget _cell(Widget child, double width) => Container(width: width, decoration: _gridCellDecoration, child: child);

  Widget _textField(TextEditingController ctrl, {TextInputType? keyboardType, TextAlign align = TextAlign.left, bool enabled = true}) => TextFormField(
        controller: ctrl, enabled: enabled && !_saving && !_uploadingExcel, keyboardType: keyboardType,
        textAlign: align, style: const TextStyle(fontSize: _gridFontSize), decoration: _cellInputDecoration,
      );

  Widget _statusCell(_StockValueRow row, double width) => Container(
        width: width, alignment: Alignment.center, decoration: _gridCellDecoration,
        child: row.alreadyEstablished
            ? Tooltip(
                message: 'Already has qty ${row.currentStock} / cost ${row.currentCost} at this location — Save will be blocked.',
                child: const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.negative),
              )
            : const Icon(Icons.check_circle_outline, size: 14, color: AppColors.positive),
      );

  Widget _buildDesktopRow(_StockValueRow row, int index, bool showBatchColumns, bool showSerialColumn) {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        width: _colWidths[0], alignment: Alignment.center, decoration: _gridCellDecoration,
        child: Text('${index + 1}', style: const TextStyle(fontSize: _gridFontSize, color: AppColors.textSecondary)),
      ),
      Container(
        width: _colWidths[1], alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 4), decoration: _gridCellDecoration,
        child: Text(row.productCode, style: const TextStyle(fontSize: _gridFontSize), overflow: TextOverflow.ellipsis),
      ),
      Container(
        width: _colWidths[2], alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 4), decoration: _gridCellDecoration,
        child: Text(row.productName, style: const TextStyle(fontSize: _gridFontSize), overflow: TextOverflow.ellipsis),
      ),
      Container(
        width: _colWidths[3], alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 4), decoration: _gridCellDecoration,
        child: Text(row.uomLabel, style: const TextStyle(fontSize: _gridFontSize), overflow: TextOverflow.ellipsis),
      ),
      _cell(_textField(row.qtyCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), _colWidths[4]),
      _cell(_textField(row.batchNoCtrl, enabled: row.isBatchTracked), _colWidths[5]),
      _cell(_expiryCell(row), _colWidths[6]),
      _cell(_textField(row.serialNoCtrl, enabled: row.isSerialTracked), _colWidths[7]),
      _cell(_textField(row.priceBaseCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), _colWidths[8]),
      _cell(_textField(row.priceProductCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right), _colWidths[9]),
      _statusCell(row, _colWidths[10]),
      Container(
        width: _colWidths[11], decoration: _gridCellDecoration,
        child: (_saving || _uploadingExcel) ? null : IconButton(
          padding: EdgeInsets.zero, iconSize: 14, icon: const Icon(Icons.close),
          onPressed: () => setState(() { _lines.remove(row); deferRowDisposal(row); }),
          tooltip: 'Remove row',
        ),
      ),
    ]);
  }

  Widget _expiryCell(_StockValueRow row) => InkWell(
        onTap: (!row.isBatchTracked || _saving || _uploadingExcel) ? null : () async {
          final d = await showDatePicker(context: context, initialDate: row.expiryDate ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (d != null) setState(() => row.expiryDate = d);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(row.isBatchTracked ? _displayDate(row.expiryDate) : '', style: const TextStyle(fontSize: _gridFontSize)),
        ),
      );

  Widget _buildMobileCard(_StockValueRow row, int index) {
    final fields = <Widget>[
      _textField(row.qtyCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right),
      if (row.isBatchTracked) _textField(row.batchNoCtrl),
      if (row.isBatchTracked) _expiryCell(row),
      if (row.isSerialTracked) _textField(row.serialNoCtrl),
      _textField(row.priceBaseCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right),
      _textField(row.priceProductCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), align: TextAlign.right),
    ];
    return SakalLineItemCard(
      title: '${index + 1}. [${row.productCode}] ${row.productName}',
      onDelete: (_saving || _uploadingExcel) ? null : () => setState(() { _lines.remove(row); deferRowDisposal(row); }),
      fields: const [],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (row.alreadyEstablished)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('Already has stock/cost at this location — Save will be blocked.', style: TextStyle(fontSize: 11, color: AppColors.negative, fontWeight: FontWeight.w600)),
            ),
          for (final f in fields) ...[f, const SizedBox(height: 8)],
        ],
      ),
    );
  }
}

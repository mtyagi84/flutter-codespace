import 'dart:async';

import 'package:dio/dio.dart';
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
import '../../../master/data/models/item_category_model.dart';
import '../../../master/data/models/product_model.dart';
import '../../../master/presentation/providers/item_categories_providers.dart';
import '../../domain/repositories/stock_count_repository.dart';
import '../providers/stock_count_providers.dart';

/// A NEW batch being physically found — pure free-text new-lot entry
/// (GRN-style), same shape regardless of whether the system already knows
/// this lot. Deliberately NO existing-lot candidate picker anywhere in
/// this screen — Stock Count is a blind count, so nothing here may show
/// what the system currently expects.
class _NewBatchEntry {
  final TextEditingController batchNoCtrl = TextEditingController();
  DateTime? expiryDate;
  DateTime? manufacturingDate;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;

  void dispose() { batchNoCtrl.dispose(); qtyPackCtrl.dispose(); qtyLooseCtrl.dispose(); }
}

class _NewSerialEntry {
  final TextEditingController serialCtrl = TextEditingController();
  void dispose() => serialCtrl.dispose();
}

/// One row per product in the worksheet's fixed scope. is_counted is the
/// authoritative "row touched" flag — untouched rows stay is_counted=false
/// forever, never silently treated as a confirmed-zero count.
class _WorksheetRow {
  final String productId;
  final String productCode;
  final String productName;
  final String trackingType;
  final String? uomId;
  final String? uomLabel;
  final double  uomConversionFactor;
  final String? catalogBarcode;    // product master's own barcode — scan-MATCH key only, never saved as-is
  final String? catalogPartNumber; // product master's own part number — scan-MATCH key only, never saved as-is

  bool isCounted = false;
  String? scannedCode; // the code the counter actually scanned to reach this row, if any — this is what gets saved for traceability
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  final List<_NewBatchEntry>  batches = [];
  final List<_NewSerialEntry> serials = [];
  final GlobalKey rowKey = GlobalKey();
  bool highlighted = false;

  _WorksheetRow({
    required this.productId,
    required this.productCode,
    required this.productName,
    required this.trackingType,
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    this.catalogBarcode,
    this.catalogPartNumber,
    this.scannedCode,
  });

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;

  double get baseQty {
    if (isBatchTracked) return batches.fold(0.0, (s, b) => s + b.qtyPack * uomConversionFactor + b.qtyLoose);
    if (isSerialTracked) return serials.length.toDouble();
    return qtyPack * uomConversionFactor + qtyLoose;
  }

  void dispose() {
    qtyPackCtrl.dispose(); qtyLooseCtrl.dispose();
    for (final b in batches) { b.dispose(); }
    for (final s in serials) { s.dispose(); }
  }
}

class StockCountEntryScreen extends ConsumerStatefulWidget {
  final String? editCountNo;
  final String? editCountDate;
  const StockCountEntryScreen({super.key, this.editCountNo, this.editCountDate});

  @override
  ConsumerState<StockCountEntryScreen> createState() => _StockCountEntryScreenState();
}

class _StockCountEntryScreenState extends ConsumerState<StockCountEntryScreen>
    with ScreenPermissionMixin<StockCountEntryScreen> {
  @override String get screenName => RouteNames.stockCount;

  StockCountRepository get _ds => ref.read(stockCountRepositoryProvider);

  String?  _countNo;
  DateTime _countDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  String?  _categoryId;
  String   _categoryDisplay = '';
  String?  _natureFilter;
  final _remarksCtrl = TextEditingController();
  final _scanCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _scrollController = ScrollController();

  List<Map<String, dynamic>> _locations = [];
  List<ItemCategoryModel> _categories = [];
  Map<String, String> _categoryPaths = {};
  final List<_WorksheetRow> _lines = [];

  bool    _loading = true;
  bool    _starting = false;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _submitting = false;
  bool    _printing = false;
  String  _search = '';

  bool get _isNew => _countNo == null;
  bool get _hasStarted => _lines.isNotEmpty;

  static const double _kEstimatedRowHeight = 64;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _search = _searchCtrl.text.trim().toLowerCase()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    _scanCtrl.dispose();
    _searchCtrl.dispose();
    _scrollController.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _locations  = await _ds.getLocations(clientId: session.clientId, companyId: session.companyId);
      _categories = await ref.read(itemCategoriesRepositoryProvider).getCategories(clientId: session.clientId, companyId: session.companyId);
      _categoryPaths = _buildCategoryPaths(_categories);

      if (widget.editCountNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          countNo: widget.editCountNo!, countDate: widget.editCountDate,
        );
        if (header != null) {
          _countNo      = header['count_no'] as String;
          _countDate    = DateTime.parse(header['count_date'] as String);
          _status       = header['status'] as String;
          _locationId   = header['location_id'] as String?;
          _categoryId   = header['category_filter_id'] as String?;
          _natureFilter = header['nature_filter'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';
          if (_categoryId != null) _categoryDisplay = _categoryPaths[_categoryId] ?? '';

          final savedLines = await _ds.getLines(
            clientId: session.clientId, companyId: session.companyId,
            countNo: _countNo!, countDate: _fmtDate(_countDate),
          );
          for (final l in _lines) { l.dispose(); }
          _lines.clear();
          for (final sl in savedLines) {
            final product = sl['product'] as Map<String, dynamic>?;
            final uom     = sl['uom'] as Map<String, dynamic>?;
            final row = _WorksheetRow(
              productId: sl['product_id'] as String,
              productCode: product?['product_code'] as String? ?? '',
              productName: product?['product_name'] as String? ?? '',
              trackingType: product?['tracking_type'] as String? ?? 'NONE',
              uomId: sl['uom_id'] as String?,
              uomLabel: uom?['description'] as String?,
              uomConversionFactor: (sl['uom_conversion_factor'] as num? ?? 1).toDouble(),
              catalogBarcode: product?['barcode'] as String?,
              catalogPartNumber: product?['part_number'] as String?,
              scannedCode: sl['barcode'] as String?,
            )..isCounted = sl['is_counted'] as bool? ?? false;
            row.qtyPackCtrl.text  = ((sl['counted_qty_pack'] as num?) ?? 0).toString();
            row.qtyLooseCtrl.text = ((sl['counted_qty_loose'] as num?) ?? 0).toString();
            _lines.add(row);

            if (row.isCounted && (row.isBatchTracked || row.isSerialTracked)) {
              unawaited(_loadSavedBatchSerial(row, (sl['serial_no'] as num).toInt()));
            }
          }
        }
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadSavedBatchSerial(_WorksheetRow row, int lineSerial) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final saved = await _ds.getLineBatches(
          clientId: session.clientId, companyId: session.companyId,
          countNo: _countNo!, countDate: _fmtDate(_countDate), lineSerial: lineSerial,
        );
        final rows = saved.map((b) {
          final r = _NewBatchEntry()
            ..batchNoCtrl.text = b['batch_no'] as String? ?? ''
            ..expiryDate = b['expiry_date'] != null ? DateTime.tryParse(b['expiry_date'] as String) : null
            ..manufacturingDate = b['manufacturing_date'] != null ? DateTime.tryParse(b['manufacturing_date'] as String) : null;
          r.qtyPackCtrl.text = ((b['qty_pack'] as num?) ?? 0).toString();
          r.qtyLooseCtrl.text = ((b['qty_loose'] as num?) ?? 0).toString();
          return r;
        }).toList();
        if (mounted) setState(() => row.batches.addAll(rows));
      } else if (row.isSerialTracked) {
        final saved = await _ds.getLineSerials(
          clientId: session.clientId, companyId: session.companyId,
          countNo: _countNo!, countDate: _fmtDate(_countDate), lineSerial: lineSerial,
        );
        final rows = saved.map((s) => _NewSerialEntry()..serialCtrl.text = s['serial_no'] as String? ?? '').toList();
        if (mounted) setState(() => row.serials.addAll(rows));
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productName}": $e', color: AppColors.negative);
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

  Future<void> _startCount() async {
    if (_locationId == null) { _showSnack('Select a Store/Location.', color: AppColors.negative); return; }
    final session = ref.read(sessionProvider)!;
    setState(() => _starting = true);
    try {
      final products = await _ds.getEligibleProducts(
        clientId: session.clientId, companyId: session.companyId,
        categoryId: _categoryId, nature: _natureFilter,
      );
      if (products.isEmpty) {
        if (mounted) { _showSnack('No products match this filter.', color: AppColors.negative); setState(() => _starting = false); }
        return;
      }
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
      for (final p in products) {
        final uom = p['uom'] as Map<String, dynamic>?;
        _lines.add(_WorksheetRow(
          productId: p['product_id'] as String,
          productCode: p['product_code'] as String? ?? '',
          productName: p['product_name'] as String? ?? '',
          trackingType: p['tracking_type'] as String? ?? 'NONE',
          uomId: p['base_uom_id'] as String?,
          uomLabel: uom?['description'] as String?,
          catalogBarcode: p['barcode'] as String?,
          catalogPartNumber: p['part_number'] as String?,
        ));
      }
      final saved = await _saveDraft(showSnack: false);
      if (mounted) {
        setState(() => _starting = false);
        if (saved) _showSnack('Count started with ${_lines.length} product(s) in scope.', color: AppColors.positive);
      }
    } on DioException catch (e) {
      if (mounted) { setState(() => _starting = false); _showSnack(e.response?.data?['message'] ?? _serverError(e), color: AppColors.negative); }
    } catch (e) {
      if (mounted) { setState(() => _starting = false); _showSnack('Could not start count: $e', color: AppColors.negative); }
    }
  }

  void _addNewBatch(_WorksheetRow row) => setState(() { row.batches.add(_NewBatchEntry()); row.isCounted = true; });
  void _removeNewBatch(_WorksheetRow row, _NewBatchEntry b) => setState(() { row.batches.remove(b); b.dispose(); });
  void _addNewSerial(_WorksheetRow row) => setState(() { row.serials.add(_NewSerialEntry()); row.isCounted = true; });
  void _removeNewSerial(_WorksheetRow row, _NewSerialEntry s) => setState(() { row.serials.remove(s); s.dispose(); });

  void _markCountedNoneFound(_WorksheetRow row) => setState(() {
    row.isCounted = true;
    for (final b in row.batches) { b.dispose(); }
    for (final s in row.serials) { s.dispose(); }
    row.batches.clear();
    row.serials.clear();
  });

  // ── Scan-to-jump — local lookup only, never a remote call. The worksheet
  //    is a closed universe once started (blind count). ────────────────────
  Future<void> _onScanSubmitted(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    final matches = _lines.where((l) => l.catalogBarcode == code || l.catalogPartNumber == code).toList();
    if (matches.isEmpty) {
      _showSnack('Product not in this count\'s scope: "$code".', color: AppColors.negative);
      _scanCtrl.clear();
      return;
    }
    final row = matches.first;
    final index = _lines.indexOf(row);
    setState(() { row.highlighted = true; row.scannedCode = code; });
    if (_scrollController.hasClients) {
      unawaited(_scrollController.animateTo(
        (index * _kEstimatedRowHeight).clamp(0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut,
      ));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = row.rowKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200));
    });
    Timer(const Duration(seconds: 2), () { if (mounted) setState(() => row.highlighted = false); });
    _scanCtrl.clear();
  }

  List<_WorksheetRow> get _filteredLines {
    if (_search.isEmpty) return _lines;
    return _lines.where((l) => l.productCode.toLowerCase().contains(_search) || l.productName.toLowerCase().contains(_search)).toList();
  }

  Future<bool> _saveDraft({bool showSnack = true}) async {
    if (_locationId == null) { _showSnack('Select a Store/Location.', color: AppColors.negative); return false; }
    if (_lines.isEmpty) { _showSnack('Start a count first.', color: AppColors.negative); return false; }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (var i = 0; i < _lines.length; i++) {
        final l = _lines[i];
        final lineSerial = i + 1;
        if (!l.isCounted) continue;
        if (l.isBatchTracked) {
          for (final b in l.batches.where((b) => (b.qtyPack * l.uomConversionFactor + b.qtyLoose) > 0)) {
            batches.add({
              'line_serial': lineSerial, 'batch_no': b.batchNoCtrl.text.trim(),
              'expiry_date': b.expiryDate != null ? _fmtDate(b.expiryDate!) : null,
              'manufacturing_date': b.manufacturingDate != null ? _fmtDate(b.manufacturingDate!) : null,
              'qty_pack': b.qtyPack, 'qty_loose': b.qtyLoose, 'base_qty': b.qtyPack * l.uomConversionFactor + b.qtyLoose,
            });
          }
        } else if (l.isSerialTracked) {
          for (final s in l.serials.where((s) => s.serialCtrl.text.trim().isNotEmpty)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialCtrl.text.trim()});
          }
        }
      }

      final header = {
        'client_id':          session.clientId,
        'company_id':         session.companyId,
        'location_id':        _locationId,
        'count_no':           _countNo,
        'count_date':         _fmtDate(_countDate),
        'category_filter_id': _categoryId,
        'nature_filter':      _natureFilter,
        'remarks':            _remarksCtrl.text.trim(),
      };
      final lines = _lines.asMap().entries.map((e) => {
        'serial_no':              e.key + 1,
        'product_id':             e.value.productId,
        'uom_id':                 e.value.uomId,
        'uom_conversion_factor':  e.value.uomConversionFactor,
        'is_counted':             e.value.isCounted,
        'counted_qty_pack':       e.value.isCounted ? e.value.qtyPack : null,
        'counted_qty_loose':      e.value.isCounted ? e.value.qtyLoose : null,
        'counted_base_qty':       e.value.isCounted ? e.value.baseQty : null,
        'barcode':                e.value.scannedCode ?? '',
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'STOCK_COUNT',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_stock_count',
          payload:      {'p_header': header, 'p_lines': lines, 'p_batches': batches, 'p_serials': serials, 'p_user_id': session.userId},
        );
        await _ds.cacheStockCountLocally(effectiveCountNo: localId, header: header, lines: lines, batches: batches, serials: serials);
        if (mounted) {
          setState(() { _countNo = localId; _saving = false; });
          if (showSnack) _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final countNo = await _ds.save(header: header, lines: lines, batches: batches, serials: serials, userId: session.userId);
        unawaited(_ds.cacheStockCountLocally(effectiveCountNo: countNo, header: header, lines: lines, batches: batches, serials: serials));
        if (mounted) {
          setState(() { _countNo = countNo; _saving = false; });
          if (showSnack) _showSnack('Stock Count $countNo saved.', color: AppColors.positive);
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

  Future<void> _submitCount() async {
    final saved = await _saveDraft(showSnack: false);
    if (!saved || _countNo == null) return;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit Stock Count'),
        content: const Text('Once submitted, this count can no longer be edited. A manager will review it together with any other counts of this location. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final session = ref.read(sessionProvider)!;
    setState(() { _submitting = true; _actionError = null; });
    try {
      await _ds.submit(clientId: session.clientId, companyId: session.companyId, countNo: _countNo!, countDate: _fmtDate(_countDate), userId: session.userId);
      if (mounted) {
        _showSnack('Stock Count $_countNo submitted.', color: AppColors.positive);
        await _init();
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      if (mounted) setState(() => _submitting = false);
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
      'count_no':   _countNo ?? '',
      'count_date': _displayDate(_countDate),
      'status':     _status,
      'location_name': _locationLabel(_locationId),
      'category':   _categoryDisplay,
      'remarks':    _remarksCtrl.text,
    },
    'lines': _lines.where((l) => l.isCounted).map((l) => {
      'product_name': '[${l.productCode}] ${l.productName}',
      'counted_qty':  l.baseQty,
    }).toList(),
  };

  Future<void> _printCount() async {
    if (_countNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('STOCK_COUNT').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_countNo.pdf');
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
      onPressed: _printing ? null : _printCount,
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
    final showSubmit  = _status == 'DRAFT' && canApprove && _hasStarted;
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
                  if (_countNo != null || (canSave && _hasStarted) || showSubmit) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_countNo != null) _buildPrintButton(),
                      if ((canSave && _hasStarted) || showSubmit) Expanded(child: _buildActionButtons(canSave: canSave && _hasStarted, canSubmit: showSubmit)),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_countNo != null) _buildPrintButton(),
                  if ((canSave && _hasStarted) || showSubmit) _buildActionButtons(canSave: canSave && _hasStarted, canSubmit: showSubmit),
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
                    _buildHeaderCard(locked, isMobile),
                    const SizedBox(height: 16),
                    if (!_hasStarted && !locked)
                      Center(child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: FilledButton.icon(
                          onPressed: _starting ? null : _startCount,
                          icon: _starting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.play_arrow),
                          label: const Text('Start Count'),
                        ),
                      ))
                    else
                      _buildLinesCard(locked, showLooseQty, showScan),
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
        Text(_countNo != null ? 'Stock Count · $_countNo' : 'New Stock Count',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        Row(children: [
          _status != 'DRAFT' ? _statusChip(_status) : Text(_countNo != null ? 'Draft' : 'Unsaved draft',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (_countNo != null) ...[
            const SizedBox(width: 8),
            PendingSyncBadge(documentType: 'STOCK_COUNT', documentId: _countNo!),
          ],
        ]),
      ]),
    ],
  );

  Widget _statusChip(String status) {
    final color = status == 'SUBMITTED' ? AppColors.secondary : AppColors.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool canSubmit}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : () => _saveDraft(),
      child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save Draft'),
    ),
    if (canSave && canSubmit) const SizedBox(width: 12),
    if (canSubmit) FilledButton(
      onPressed: _submitting ? null : _submitCount,
      style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
      child: _submitting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Submit'),
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

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final filtersLocked = locked || _hasStarted; // scope is fixed once the worksheet is built

    final countNoField = SakalFieldCard.readOnly(label: 'Count No', value: _countNo ?? '(auto on save)');
    final locationField = SakalFieldCard(
      label: 'Store / Location', required: true, editable: !filtersLocked,
      child: DropdownButtonFormField<String>(
        decoration: bare, isExpanded: true, isDense: true, itemHeight: null, style: style,
        initialValue: _locationId,
        items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
            child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: style))).toList(),
        onChanged: filtersLocked ? null : (v) => setState(() => _locationId = v),
      ),
    );
    final dateField = SakalFieldCard(
      label: 'Count Date', required: true, editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(_countDate, (d) => setState(() => _countDate = d)),
        child: Row(children: [
          Expanded(child: Text(_displayDate(_countDate), style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final categoryField = SakalFieldCard(
      label: 'Category (All if blank)', editable: !filtersLocked,
      child: SakalAutocomplete<ItemCategoryModel>(
        key: ValueKey('$_categoryId-$_categoryDisplay'),
        initialValue: TextEditingValue(text: _categoryDisplay),
        displayStringForOption: (c) => _categoryPaths[c.id] ?? c.categoryName,
        optionsBuilder: (v) {
          if (filtersLocked) return const [];
          if (v.text.isEmpty) return _categories;
          final s = v.text.toLowerCase();
          return _categories.where((c) => (_categoryPaths[c.id] ?? c.categoryName).toLowerCase().contains(s));
        },
        onSelected: (c) => setState(() { _categoryId = c.id; _categoryDisplay = _categoryPaths[c.id] ?? c.categoryName; }),
        enabled: !filtersLocked,
        decoration: bare.copyWith(
          suffixIcon: (_categoryId != null && !filtersLocked)
              ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _categoryId = null; _categoryDisplay = ''; }))
              : null,
        ),
        style: style,
      ),
    );
    final natureField = SakalFieldCard(
      label: 'Item Type (All if blank)', editable: !filtersLocked,
      child: DropdownButtonFormField<String?>(
        decoration: bare, isExpanded: true, isDense: true, itemHeight: null, style: style,
        initialValue: _natureFilter,
        items: [
          DropdownMenuItem(value: null, child: Text('All Types', style: style)),
          ...ProductModel.natureLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: style))),
        ],
        onChanged: filtersLocked ? null : (v) => setState(() => _natureFilter = v),
      ),
    );
    final remarksField = SakalFieldCard(
      label: 'Remarks', editable: !locked,
      child: TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: bare, style: style),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SakalFieldRow(isMobile: isMobile, spans: const [2, 2, 2], children: [countNoField, locationField, dateField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, spans: const [3, 2, 3], children: [categoryField, natureField, remarksField]),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked, bool showLooseQty, bool showScan) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final rows = _filteredLines;
    final countedN = _lines.where((l) => l.isCounted).length;

    final scanField = SakalFieldCard(
      label: 'Scan Barcode/Part Number', editable: !locked,
      child: TextFormField(
        controller: _scanCtrl, enabled: !locked,
        decoration: bare.copyWith(prefixIcon: const Icon(Icons.qr_code_scanner, size: 16)),
        style: style,
        onFieldSubmitted: _onScanSubmitted,
      ),
    );
    final searchField = SakalFieldCard(
      label: 'Search Product', editable: true,
      child: TextField(
        controller: _searchCtrl,
        decoration: bare.copyWith(
          prefixIcon: const Icon(Icons.search, size: 16),
          suffixIcon: _search.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear) : null,
        ),
        style: style,
      ),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Worksheet — $countedN of ${_lines.length} counted',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 8, children: [
            if (showScan) SizedBox(width: 240, child: scanField),
            SizedBox(width: 240, child: searchField),
          ]),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 600),
            child: ListView.builder(
              controller: _scrollController,
              itemCount: rows.length,
              itemBuilder: (context, i) => _buildWorksheetRow(rows[i], locked, showLooseQty),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildWorksheetRow(_WorksheetRow row, bool locked, bool showLooseQty) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final isTracked = row.isBatchTracked || row.isSerialTracked;

    final unitField = SakalFieldCard.readOnly(label: 'Unit', value: row.uomLabel ?? '—');
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Qty Pack' : 'Quantity', editable: !locked, numeric: true,
      child: TextFormField(
        controller: row.qtyPackCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (v) => setState(() => row.isCounted = true),
      ),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Qty Loose', editable: !locked, numeric: true,
      child: TextFormField(
        controller: row.qtyLooseCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (v) => setState(() => row.isCounted = true),
      ),
    );

    final card = SakalLineItemCard(
      title: '[${row.productCode}] ${row.productName}',
      subtitle: isTracked
          ? (row.isBatchTracked
              ? '${row.batches.length} batch(es) — total ${row.baseQty.toStringAsFixed(2)}'
              : '${row.serials.length} serial(s)')
          : null,
      trailingHeaderAction: Icon(
        row.isCounted ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: row.isCounted ? Colors.white : Colors.white54,
      ),
      fields: isTracked
          ? const []
          : [
              SizedBox(width: 90, child: unitField),
              SizedBox(width: 120, child: qtyPackField),
              if (showLooseQty) SizedBox(width: 120, child: qtyLooseField),
            ],
      body: isTracked ? _buildBatchSerialEditor(row, locked, showLooseQty) : null,
    );

    return Container(
      key: row.rowKey,
      margin: const EdgeInsets.only(bottom: 4),
      padding: row.highlighted ? const EdgeInsets.all(2) : EdgeInsets.zero,
      decoration: row.highlighted
          ? BoxDecoration(border: Border.all(color: AppColors.secondary, width: 2), borderRadius: BorderRadius.circular(12))
          : null,
      child: card,
    );
  }

  Widget _buildBatchSerialEditor(_WorksheetRow row, bool locked, bool showLooseQty) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(row.isBatchTracked ? 'Batches' : 'Serial Numbers',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const Spacer(),
          if (!locked)
            TextButton.icon(
              onPressed: () => row.isBatchTracked ? _addNewBatch(row) : _addNewSerial(row),
              icon: const Icon(Icons.add, size: 14),
              label: Text(row.isBatchTracked ? 'Add Batch' : 'Add Serial', style: const TextStyle(fontSize: 12)),
            ),
          if (!locked && !row.isCounted)
            TextButton.icon(
              onPressed: () => _markCountedNoneFound(row),
              icon: const Icon(Icons.block, size: 14, color: AppColors.negative),
              label: const Text('None Found', style: TextStyle(fontSize: 12, color: AppColors.negative)),
            ),
        ]),
        if (row.isBatchTracked)
          ...row.batches.map((b) => _buildNewBatchRow(row, b, showLooseQty, locked))
        else
          ...row.serials.map((s) => _buildNewSerialRow(row, s, locked)),
      ]),
    );
  }

  Widget _buildNewBatchRow(_WorksheetRow row, _NewBatchEntry b, bool showLooseQty, bool locked) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final batchNoField = SakalFieldCard(
      label: 'Batch No', editable: !locked,
      child: TextFormField(controller: b.batchNoCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final expiryField = SakalFieldCard(
      label: 'Expiry Date', editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(b.expiryDate, (d) => setState(() => b.expiryDate = d)),
        child: Row(children: [
          Expanded(child: Text(b.expiryDate != null ? _displayDate(b.expiryDate) : '—', style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final mfgField = SakalFieldCard(
      label: 'Manufacturing Date', editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(b.manufacturingDate, (d) => setState(() => b.manufacturingDate = d)),
        child: Row(children: [
          Expanded(child: Text(b.manufacturingDate != null ? _displayDate(b.manufacturingDate) : '—', style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final unitField = SakalFieldCard.readOnly(label: 'Unit', value: row.uomLabel ?? '—');
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Qty Pack' : 'Qty', editable: !locked, numeric: true,
      child: TextFormField(
        controller: b.qtyPackCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Qty Loose', editable: !locked, numeric: true,
      child: TextFormField(
        controller: b.qtyLooseCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 140, child: batchNoField),
            SizedBox(width: 150, child: expiryField),
            SizedBox(width: 160, child: mfgField),
            SizedBox(width: 80, child: unitField),
            SizedBox(width: 100, child: qtyPackField),
            if (showLooseQty) SizedBox(width: 100, child: qtyLooseField),
          ]),
        ),
        if (!locked)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: IconButton(
              icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative),
              onPressed: () => _removeNewBatch(row, b),
            ),
          ),
      ]),
    );
  }

  Widget _buildNewSerialRow(_WorksheetRow row, _NewSerialEntry s, bool locked) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final serialField = SakalFieldCard(
      label: 'Serial No', editable: !locked,
      child: TextFormField(controller: s.serialCtrl, enabled: !locked, decoration: bare, style: style, onChanged: (_) => setState(() {})),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        SizedBox(width: 200, child: serialField),
        if (!locked) IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative), onPressed: () => _removeNewSerial(row, s)),
      ]),
    );
  }
}

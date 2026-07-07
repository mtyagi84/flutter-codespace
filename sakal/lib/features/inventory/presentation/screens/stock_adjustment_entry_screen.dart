import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../domain/repositories/stock_adjustment_repository.dart';
import '../providers/stock_adjustment_providers.dart';

/// A NEW batch/serial being created on a '+' (increase) line — same shape
/// as GRN's own new-lot entry, since increasing stock for a batch/serial-
/// tracked product is exactly like receiving it: the user types the lot
/// identity fresh.
class _AdjNewBatchRow {
  final TextEditingController batchNoCtrl = TextEditingController();
  DateTime? expiryDate;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;

  void dispose() { batchNoCtrl.dispose(); qtyPackCtrl.dispose(); qtyLooseCtrl.dispose(); }
}

class _AdjNewSerialRow {
  final TextEditingController serialCtrl = TextEditingController();
  void dispose() => serialCtrl.dispose();
}

/// An EXISTING batch/serial on hand — the candidate list for a '-'
/// (decrease) line, same shape as Material Issue's own picker (based on
/// live on-hand balance, not any originating document).
class _AdjBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  num availableBalance;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');

  _AdjBatchCandidate({required this.batchNo, this.expiryDate, required this.availableBalance});

  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

class _AdjSerialCandidate {
  final String serialNo;
  bool selected = false;
  _AdjSerialCandidate({required this.serialNo});
}

class _AdjLineRow {
  String? productId;
  String  productDisplay = '';
  final TextEditingController barcodeCtrl = TextEditingController();
  String? matchedBarcode;
  String  trackingType = 'NONE';
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  String  adjustFlag = '+';
  double? systemQty;
  String? reasonId; // optional per-line override of the header reason
  final TextEditingController remarksCtrl = TextEditingController();

  // '+' direction: new lots being created.
  final List<_AdjNewBatchRow>  newBatchRows  = [];
  final List<_AdjNewSerialRow> newSerialRows = [];

  // '-' direction: existing lots on hand.
  List<_AdjBatchCandidate>  batchCandidates  = [];
  List<_AdjSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  double get qtyPack     => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose    => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get baseQty     => qtyPack * uomConversionFactor + qtyLoose;

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';
  bool get isIncrease      => adjustFlag == '+';

  double get newBatchQtySum      => newBatchRows.fold(0.0, (s, b) => s + b.qtyPack * uomConversionFactor + b.qtyLoose);
  double get existingBatchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedExistingSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    barcodeCtrl.dispose(); qtyPackCtrl.dispose(); qtyLooseCtrl.dispose(); remarksCtrl.dispose();
    for (final b in newBatchRows) { b.dispose(); }
    for (final s in newSerialRows) { s.dispose(); }
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class StockAdjustmentEntryScreen extends ConsumerStatefulWidget {
  final String? editAdjustmentNo;
  final String? editAdjustmentDate;
  const StockAdjustmentEntryScreen({super.key, this.editAdjustmentNo, this.editAdjustmentDate});

  @override
  ConsumerState<StockAdjustmentEntryScreen> createState() => _StockAdjustmentEntryScreenState();
}

class _StockAdjustmentEntryScreenState extends ConsumerState<StockAdjustmentEntryScreen>
    with ScreenPermissionMixin<StockAdjustmentEntryScreen> {
  @override String get screenName => RouteNames.stockAdjustments;

  StockAdjustmentRepository get _ds => ref.read(stockAdjustmentRepositoryProvider);

  String?  _adjustmentNo;
  DateTime _adjustmentDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  String?  _reasonId;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _reasons   = [];
  final List<_AdjLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _printing = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  bool _loadingVoucherLines = false;

  bool get _isNew => _adjustmentNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;

      _locations = await _ds.getLocations(clientId: session.clientId, companyId: session.companyId);
      _reasons   = await _ds.getReasons(clientId: session.clientId, companyId: session.companyId);

      if (widget.editAdjustmentNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          adjustmentNo: widget.editAdjustmentNo!, adjustmentDate: widget.editAdjustmentDate,
        );
        if (header != null) {
          _adjustmentNo   = header['adjustment_no'] as String;
          _adjustmentDate = DateTime.parse(header['adjustment_date'] as String);
          _status         = header['status'] as String;
          _locationId     = header['location_id'] as String?;
          _reasonId       = header['reason_id'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';

          final savedLines = await _ds.getLines(
            clientId: session.clientId, companyId: session.companyId,
            adjustmentNo: _adjustmentNo!, adjustmentDate: _fmtDate(_adjustmentDate),
          );
          for (final l in _lines) { l.dispose(); }
          _lines.clear();
          for (final sl in savedLines) {
            final product = sl['product'] as Map<String, dynamic>?;
            final uom     = sl['uom'] as Map<String, dynamic>?;
            final row = _AdjLineRow()
              ..productId = sl['product_id'] as String?
              ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
              ..trackingType = product?['tracking_type'] as String? ?? 'NONE'
              ..uomId = sl['uom_id'] as String?
              ..uomLabel = uom?['description'] as String?
              ..uomConversionFactor = (sl['uom_conversion_factor'] as num? ?? 1).toDouble()
              ..adjustFlag = sl['adjust_flag'] as String? ?? '+'
              ..systemQty = (sl['system_qty'] as num?)?.toDouble()
              ..matchedBarcode = sl['barcode'] as String?
              ..reasonId = sl['reason_id'] as String?;
            row.qtyPackCtrl.text = ((sl['qty_pack'] as num?) ?? 0).toString();
            row.qtyLooseCtrl.text = ((sl['qty_loose'] as num?) ?? 0).toString();
            row.remarksCtrl.text = sl['remarks'] as String? ?? '';
            _lines.add(row);

            if (row.isBatchTracked || row.isSerialTracked) {
              unawaited(_loadSavedBatchSerial(row, (sl['serial_no'] as num).toInt()));
            }
          }
        }
      }

      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadSavedBatchSerial(_AdjLineRow row, int lineSerial) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final saved = await _ds.getLineBatches(
          clientId: session.clientId, companyId: session.companyId,
          adjustmentNo: _adjustmentNo!, adjustmentDate: _fmtDate(_adjustmentDate), lineSerial: lineSerial,
        );
        if (row.isIncrease) {
          final rows = saved.map((b) {
            final r = _AdjNewBatchRow()
              ..batchNoCtrl.text = b['batch_no'] as String? ?? ''
              ..expiryDate = b['expiry_date'] != null ? DateTime.tryParse(b['expiry_date'] as String) : null;
            r.qtyPackCtrl.text = ((b['qty_pack'] as num?) ?? 0).toString();
            r.qtyLooseCtrl.text = ((b['qty_loose'] as num?) ?? 0).toString();
            return r;
          }).toList();
          if (mounted) setState(() => row.newBatchRows.addAll(rows));
        } else {
          final available = await _ds.getAvailableBatches(
            clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
          );
          final candidates = available.map((b) => _AdjBatchCandidate(
            batchNo: b['batch_no'] as String, expiryDate: b['expiry_date'] as String?, availableBalance: b['balance'] as num? ?? 0,
          )).toList();
          for (final saved1 in saved) {
            final match = candidates.where((c) => c.batchNo == saved1['batch_no']).toList();
            final qty = ((saved1['qty_pack'] as num?) ?? 0) + ((saved1['qty_loose'] as num?) ?? 0);
            if (match.isNotEmpty) {
              match.first.qtyCtrl.text = qty.toString();
            } else {
              candidates.add(_AdjBatchCandidate(batchNo: saved1['batch_no'] as String, expiryDate: saved1['expiry_date'] as String?, availableBalance: qty)
                ..qtyCtrl.text = qty.toString());
            }
          }
          if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
        }
      } else if (row.isSerialTracked) {
        final saved = await _ds.getLineSerials(
          clientId: session.clientId, companyId: session.companyId,
          adjustmentNo: _adjustmentNo!, adjustmentDate: _fmtDate(_adjustmentDate), lineSerial: lineSerial,
        );
        if (row.isIncrease) {
          final rows = saved.map((s) => _AdjNewSerialRow()..serialCtrl.text = s['serial_no'] as String? ?? '').toList();
          if (mounted) setState(() => row.newSerialRows.addAll(rows));
        } else {
          final available = await _ds.getAvailableSerials(
            clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
          );
          final savedSerials = saved.map((s) => s['serial_no'] as String).toSet();
          final candidates = available.map((s) => _AdjSerialCandidate(serialNo: s['serial_no'] as String)
            ..selected = savedSerials.contains(s['serial_no'])).toList();
          for (final sv in savedSerials) {
            if (!candidates.any((c) => c.serialNo == sv)) {
              candidates.add(_AdjSerialCandidate(serialNo: sv)..selected = true);
            }
          }
          if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
        }
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingVoucherLines = true);
    try {
      final vouchers = await _ds.getPostedVouchers(clientId: session.clientId, companyId: session.companyId, adjustmentNo: _adjustmentNo!);
      final lines = <String, List<Map<String, dynamic>>>{};
      for (final v in vouchers) {
        lines[v['trans_no'] as String] = await _ds.getPostedVoucherLines(
          clientId: session.clientId, companyId: session.companyId,
          voucherNo: v['trans_no'] as String, voucherDate: v['trans_date'] as String,
        );
      }
      if (mounted) setState(() { _postedVouchers = vouchers; _voucherLines..clear()..addAll(lines); _loadingVoucherLines = false; });
    } catch (e) {
      if (mounted) setState(() => _loadingVoucherLines = false);
    }
  }

  void _addLine() => setState(() => _lines.add(_AdjLineRow()));
  void _removeLine(_AdjLineRow row) => setState(() { _lines.remove(row); row.dispose(); });

  bool _isDuplicateProduct(String productId, {_AdjLineRow? excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  Future<void> _onProductSelected(_AdjLineRow row, Map<String, dynamic> product) async {
    final productId = product['id'] as String;
    if (_isDuplicateProduct(productId, excluding: row)) {
      _showSnack('This product is already on another line — edit that line instead.', color: AppColors.negative);
      return;
    }
    setState(() {
      row.productId = productId;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.uomId = product['base_uom_id'] as String?;
      final uom = product['uom'] as Map<String, dynamic>?;
      row.uomLabel = uom?['description'] as String?;
      row.trackingType = product['tracking_type'] as String? ?? 'NONE';
    });
    unawaited(_refreshSystemQty(row));
    if (row.isBatchTracked || row.isSerialTracked) unawaited(_onDirectionChanged(row));
  }

  Future<void> _onBarcodeSubmitted(_AdjLineRow row, String rawBarcode) async {
    final barcode = rawBarcode.trim();
    if (barcode.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    Map<String, dynamic>? match;
    try {
      match = await _ds.getProductByBarcode(clientId: session.clientId, companyId: session.companyId, barcode: barcode);
    } catch (e) {
      if (mounted) _showSnack('Barcode lookup failed: $e', color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    if (match == null) { _showSnack('No product found for barcode "$barcode".', color: AppColors.negative); return; }
    final matchedProduct = match;
    await _onProductSelected(row, matchedProduct);
    if (mounted && row.productId == matchedProduct['id']) {
      setState(() {
        row.uomId = matchedProduct['matched_uom_id'] as String? ?? row.uomId;
        row.uomConversionFactor = (matchedProduct['matched_uom_conversion_factor'] as num? ?? 1).toDouble();
        row.matchedBarcode = barcode;
        row.barcodeCtrl.clear();
      });
    }
  }

  Future<void> _refreshSystemQty(_AdjLineRow row) async {
    if (row.productId == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    try {
      final qty = await _ds.getCurrentStock(
        clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
      );
      if (mounted) setState(() => row.systemQty = qty.toDouble());
    } catch (_) { /* advisory only */ }
  }

  /// Re-derives the batch/serial editor when direction flips: '+' starts
  /// with one empty new-lot row; '-' loads current on-hand candidates.
  Future<void> _onDirectionChanged(_AdjLineRow row) async {
    for (final b in row.newBatchRows) { b.dispose(); }
    for (final b in row.batchCandidates) { b.dispose(); }
    row.newBatchRows.clear();
    row.newSerialRows.clear();
    row.batchCandidates = [];
    row.serialCandidates = [];
    row.candidatesLoaded = false;

    if (row.isIncrease) {
      if (row.isBatchTracked) row.newBatchRows.add(_AdjNewBatchRow());
      if (row.isSerialTracked) row.newSerialRows.add(_AdjNewSerialRow());
      if (mounted) setState(() {});
      return;
    }

    if (!row.isBatchTracked && !row.isSerialTracked) return;
    if (row.productId == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final rows = await _ds.getAvailableBatches(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
        );
        final candidates = rows.map((b) => _AdjBatchCandidate(
          batchNo: b['batch_no'] as String, expiryDate: b['expiry_date'] as String?, availableBalance: b['balance'] as num? ?? 0,
        )).toList();
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else {
        final rows = await _ds.getAvailableSerials(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
        );
        final candidates = rows.map((s) => _AdjSerialCandidate(serialNo: s['serial_no'] as String)).toList();
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  void _addNewBatchRow(_AdjLineRow row) => setState(() => row.newBatchRows.add(_AdjNewBatchRow()));
  void _removeNewBatchRow(_AdjLineRow row, _AdjNewBatchRow b) => setState(() { row.newBatchRows.remove(b); b.dispose(); });
  void _addNewSerialRow(_AdjLineRow row) => setState(() => row.newSerialRows.add(_AdjNewSerialRow()));
  void _removeNewSerialRow(_AdjLineRow row, _AdjNewSerialRow s) => setState(() { row.newSerialRows.remove(s); s.dispose(); });

  /// Mandatory allocation whenever baseQty > 0 — same reasoning as every
  /// other batch/serial-tracked module in this schema: leaving it
  /// unallocated would silently fall through fn_approve_stock_adjustment's
  /// v_has_batches/v_has_serials check into the plain aggregate movement.
  String? _batchSerialError(_AdjLineRow row) {
    if (row.baseQty <= 0) return null;
    if (row.isBatchTracked) {
      final sum = row.isIncrease ? row.newBatchQtySum : row.existingBatchQtySum;
      if (row.isIncrease && row.newBatchRows.isEmpty) return 'Enter at least one batch for "${row.productDisplay}".';
      if (!row.isIncrease && row.batchCandidates.isEmpty) return 'No batches currently in stock for "${row.productDisplay}".';
      if ((sum - row.baseQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${sum.toStringAsFixed(2)} but the adjustment quantity is ${row.baseQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      final count = row.isIncrease ? row.newSerialRows.where((s) => s.serialCtrl.text.trim().isNotEmpty).length : row.selectedExistingSerialCount;
      if (row.isIncrease && row.newSerialRows.isEmpty) return 'Enter at least one serial number for "${row.productDisplay}".';
      if (!row.isIncrease && row.serialCandidates.isEmpty) return 'No serial numbers currently in stock for "${row.productDisplay}".';
      if (count != row.baseQty.round() || (row.baseQty - row.baseQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers for "${row.productDisplay}" ($count) must match the adjustment quantity (${row.baseQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  Future<bool> _saveDraft() async {
    if (_locationId == null) { _showSnack('Select a Store/Location.', color: AppColors.negative); return false; }
    if (_reasonId == null) { _showSnack('Select a Reason.', color: AppColors.negative); return false; }
    final adjustableLines = _lines.where((l) => l.productId != null && l.baseQty > 0).toList();
    if (adjustableLines.isEmpty) { _showSnack('Add at least one line with a product and quantity.', color: AppColors.negative); return false; }
    for (final l in adjustableLines) {
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (var i = 0; i < adjustableLines.length; i++) {
        final l = adjustableLines[i];
        final lineSerial = i + 1;
        if (l.isBatchTracked) {
          if (l.isIncrease) {
            for (final b in l.newBatchRows.where((b) => (b.qtyPack * l.uomConversionFactor + b.qtyLoose) > 0)) {
              batches.add({
                'line_serial': lineSerial, 'batch_no': b.batchNoCtrl.text.trim(),
                'expiry_date': b.expiryDate != null ? _fmtDate(b.expiryDate!) : null,
                'qty_pack': b.qtyPack, 'qty_loose': b.qtyLoose, 'base_qty': b.qtyPack * l.uomConversionFactor + b.qtyLoose,
              });
            }
          } else {
            for (final b in l.batchCandidates.where((b) => b.allocatedQty > 0)) {
              batches.add({'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate, 'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty});
            }
          }
        } else if (l.isSerialTracked) {
          if (l.isIncrease) {
            for (final s in l.newSerialRows.where((s) => s.serialCtrl.text.trim().isNotEmpty)) {
              serials.add({'line_serial': lineSerial, 'serial_no': s.serialCtrl.text.trim()});
            }
          } else {
            for (final s in l.serialCandidates.where((s) => s.selected)) {
              serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
            }
          }
        }
      }

      final header = {
        'client_id':       session.clientId,
        'company_id':      session.companyId,
        'location_id':     _locationId,
        'adjustment_no':   _adjustmentNo,
        'adjustment_date': _fmtDate(_adjustmentDate),
        'reason_id':       _reasonId,
        'remarks':         _remarksCtrl.text.trim(),
      };
      final lines = adjustableLines.asMap().entries.map((e) => {
        'serial_no':              e.key + 1,
        'product_id':             e.value.productId,
        'uom_id':                 e.value.uomId,
        'uom_conversion_factor':  e.value.uomConversionFactor,
        'qty_pack':               e.value.qtyPack,
        'qty_loose':              e.value.qtyLoose,
        'base_qty':               e.value.baseQty,
        'adjust_flag':            e.value.adjustFlag,
        'system_qty':             e.value.systemQty,
        'barcode':                e.value.matchedBarcode ?? '',
        'reason_id':              e.value.reasonId ?? '',
        'remarks':                e.value.remarksCtrl.text.trim(),
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'STOCK_ADJUSTMENT',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_stock_adjustment',
          payload:      {'p_header': header, 'p_lines': lines, 'p_batches': batches, 'p_serials': serials, 'p_user_id': session.userId},
        );
        await _ds.cacheAdjustmentLocally(effectiveAdjustmentNo: localId, header: header, lines: lines, batches: batches, serials: serials);
        if (mounted) {
          setState(() { _adjustmentNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final adjustmentNo = await _ds.save(header: header, lines: lines, batches: batches, serials: serials, userId: session.userId);
        unawaited(_ds.cacheAdjustmentLocally(effectiveAdjustmentNo: adjustmentNo, header: header, lines: lines, batches: batches, serials: serials));
        if (mounted) {
          setState(() { _adjustmentNo = adjustmentNo; _saving = false; });
          _showSnack('Stock Adjustment $adjustmentNo saved.', color: AppColors.positive);
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

  Future<void> _approveAdjustment() async {
    if (_adjustmentNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (_adjustmentDate.isAfter(DateTime.now())) {
      _showSnack('Adjustment date cannot be in the future.', color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Stock Adjustment'),
        content: const Text('Once approved, stock will be updated and the Stock/Stock Adjustment entry will be posted to Finance. This adjustment can no longer be edited. Continue?'),
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
        adjustmentNo: _adjustmentNo!, adjustmentDate: _fmtDate(_adjustmentDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Stock Adjustment $_adjustmentNo approved.', color: AppColors.positive);
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

  String _reasonLabel(String? id) {
    if (id == null) return '';
    final match = _reasons.where((r) => r['id'] == id).toList();
    return match.isNotEmpty ? match.first['description'] as String? ?? '' : '';
  }

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) => {
    'company': company,
    'header': {
      'adjustment_no':   _adjustmentNo ?? '',
      'adjustment_date': _displayDate(_adjustmentDate),
      'status':          _status,
      'location_name':   _locationLabel(_locationId),
      'reason':          _reasonLabel(_reasonId),
      'remarks':         _remarksCtrl.text,
    },
    'lines': _lines.map((l) => {
      'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
      'direction':    l.isIncrease ? 'Increase' : 'Decrease',
      'base_qty':     l.baseQty,
      'system_qty':   l.systemQty ?? 0,
    }).toList(),
  };

  Future<void> _printAdjustment() async {
    if (_adjustmentNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('STOCK_ADJUSTMENT').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_adjustmentNo.pdf');
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
      onPressed: _printing ? null : _printAdjustment,
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
                  if (_adjustmentNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_adjustmentNo != null) _buildPrintButton(),
                      if (canSave || showApprove) Expanded(child: _buildActionButtons(canSave: canSave, canApprove: showApprove)),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_adjustmentNo != null) _buildPrintButton(),
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
                    _buildHeaderCard(locked, isMobile),
                    const SizedBox(height: 16),
                    _buildLinesCard(locked, showLooseQty, showBarcode),
                    if (_status == 'APPROVED' && _postedVouchers.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildPostedVouchersSection(),
                    ],
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_adjustmentNo != null ? 'Stock Adjustment · $_adjustmentNo' : 'New Stock Adjustment',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    Row(children: [
      _status == 'APPROVED' ? _statusChip(_status) : Text(_adjustmentNo != null ? 'Draft' : 'Unsaved draft',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      if (_adjustmentNo != null) ...[
        const SizedBox(width: 8),
        PendingSyncBadge(documentType: 'STOCK_ADJUSTMENT', documentId: _adjustmentNo!),
      ],
    ]),
  ]);

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
      onPressed: _approving ? null : _approveAdjustment,
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

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);

    final locationField = field(DropdownButtonFormField<String>(
      decoration: dec.copyWith(labelText: 'Store / Location *'),
      isExpanded: true, isDense: true, itemHeight: null,
      initialValue: _locationId,
      items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
          child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
      onChanged: locked ? null : (v) => setState(() => _locationId = v),
    ));
    final dateField = field(InkWell(
      onTap: locked ? null : () => _pickDate(_adjustmentDate, (d) => setState(() => _adjustmentDate = d)),
      child: InputDecorator(
        decoration: dec.copyWith(labelText: 'Adjustment Date *',
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
        child: Text(_displayDate(_adjustmentDate), style: const TextStyle(fontSize: 13)),
      ),
    ));
    final reasonField = field(DropdownButtonFormField<String>(
      decoration: dec.copyWith(labelText: 'Reason *'),
      isExpanded: true, isDense: true, itemHeight: null,
      initialValue: _reasonId,
      items: _reasons.map((r) => DropdownMenuItem(value: r['id'] as String,
          child: Text(r['description'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
      onChanged: locked ? null : (v) => setState(() => _reasonId = v),
    ));
    final remarksField = field(TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Remarks')));

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: isMobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                field(InputDecorator(decoration: dec.copyWith(labelText: 'Adjustment No'),
                    child: Text(_adjustmentNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _adjustmentNo != null ? AppColors.textPrimary : AppColors.textDisabled)))),
                const SizedBox(height: 8),
                locationField, const SizedBox(height: 8),
                dateField, const SizedBox(height: 8),
                reasonField, const SizedBox(height: 8),
                remarksField,
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(flex: 2, child: field(InputDecorator(decoration: dec.copyWith(labelText: 'Adjustment No'),
                      child: Text(_adjustmentNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _adjustmentNo != null ? AppColors.textPrimary : AppColors.textDisabled))))),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: locationField),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: dateField),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(flex: 2, child: reasonField),
                  const SizedBox(width: 12),
                  Expanded(flex: 3, child: remarksField),
                ]),
              ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked, bool showLooseQty, bool showBarcode) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Adjustment Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (!locked) TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
          ]),
          const SizedBox(height: 8),
          if (_lines.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet — add a product.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._lines.map((row) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 0,
              color: AppColors.background,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    SizedBox(
                      width: 240,
                      child: Autocomplete<Map<String, dynamic>>(
                        key: ValueKey('${row.hashCode}-${row.productDisplay}'),
                        initialValue: TextEditingValue(text: row.productDisplay),
                        displayStringForOption: (p) => '[${p['product_code']}] ${p['product_name']}',
                        optionsBuilder: (v) async {
                          if (locked) return const [];
                          final session = ref.read(sessionProvider)!;
                          return _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: v.text);
                        },
                        onSelected: (p) => _onProductSelected(row, p),
                        fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                          controller: textCtrl, focusNode: focusNode, enabled: !locked,
                          decoration: dec.copyWith(labelText: 'Product'), style: const TextStyle(fontSize: 13),
                        ),
                        optionsViewBuilder: (context, onSel, opts) => Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4, borderRadius: BorderRadius.circular(4),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 260, minWidth: 240),
                              child: ListView.builder(
                                padding: EdgeInsets.zero, shrinkWrap: true, itemCount: opts.length,
                                itemBuilder: (context, idx) {
                                  final p = opts.elementAt(idx);
                                  return InkWell(
                                    onTap: () => onSel(p),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Text('[${p['product_code']}] ${p['product_name']}', style: const TextStyle(fontSize: 13)),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (showBarcode) SizedBox(width: 140, height: 48, child: TextFormField(
                      controller: row.barcodeCtrl, enabled: !locked,
                      decoration: dec.copyWith(labelText: 'Scan/Enter Barcode'),
                      style: const TextStyle(fontSize: 12),
                      onFieldSubmitted: (v) => _onBarcodeSubmitted(row, v),
                    )),
                    SizedBox(width: 130, height: 48, child: DropdownButtonFormField<String>(
                      decoration: dec.copyWith(labelText: 'Direction'),
                      isExpanded: true, isDense: true, itemHeight: null,
                      initialValue: row.adjustFlag,
                      items: const [
                        DropdownMenuItem(value: '+', child: Text('+ Increase', style: TextStyle(fontSize: 12))),
                        DropdownMenuItem(value: '-', child: Text('- Decrease', style: TextStyle(fontSize: 12))),
                      ],
                      onChanged: locked ? null : (v) {
                        setState(() => row.adjustFlag = v ?? '+');
                        unawaited(_onDirectionChanged(row));
                      },
                    )),
                    SizedBox(width: 90, child: TextFormField(
                      controller: row.qtyPackCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: showLooseQty ? 'Qty Pack' : 'Quantity'),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(() {}),
                    )),
                    if (showLooseQty) SizedBox(width: 90, child: TextFormField(
                      controller: row.qtyLooseCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: 'Qty Loose'),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(() {}),
                    )),
                    if (row.systemQty != null)
                      SizedBox(width: 110, child: Text('System: ${row.systemQty!.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                    SizedBox(width: 180, height: 48, child: DropdownButtonFormField<String>(
                      decoration: dec.copyWith(labelText: 'Reason (override)'),
                      isExpanded: true, isDense: true, itemHeight: null,
                      initialValue: row.reasonId,
                      items: _reasons.map((r) => DropdownMenuItem(value: r['id'] as String,
                          child: Text(r['description'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))).toList(),
                      onChanged: locked ? null : (v) => setState(() => row.reasonId = v),
                    )),
                    if (!locked) IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative), onPressed: () => _removeLine(row)),
                  ]),
                  if (row.isBatchTracked || row.isSerialTracked) _buildBatchSerialEditor(row, locked, showLooseQty),
                ]),
              ),
            )),
        ]),
      ),
    );
  }

  Widget _buildBatchSerialEditor(_AdjLineRow row, bool locked, bool showLooseQty) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    final isBatch = row.isBatchTracked;

    if (row.isIncrease) {
      // '+' : new lot entry, GRN-style.
      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(isBatch ? 'New Batches' : 'New Serial Numbers',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
            const SizedBox(width: 10),
            Text(isBatch
                ? '${row.newBatchQtySum.toStringAsFixed(2)} / ${row.baseQty.toStringAsFixed(2)}'
                : '${row.newSerialRows.length} / ${row.baseQty.toStringAsFixed(0)}',
                style: TextStyle(fontSize: 11,
                    color: (isBatch ? (row.newBatchQtySum - row.baseQty).abs() < 0.0001 : row.newSerialRows.length == row.baseQty.round())
                        ? AppColors.positive : AppColors.negative)),
            const Spacer(),
            if (!locked) TextButton.icon(
              onPressed: () => isBatch ? _addNewBatchRow(row) : _addNewSerialRow(row),
              icon: const Icon(Icons.add, size: 14),
              label: Text(isBatch ? 'Add Batch' : 'Add Serial', style: const TextStyle(fontSize: 12)),
            ),
          ]),
          if (isBatch)
            ...row.newBatchRows.map((b) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(width: 140, child: TextFormField(controller: b.batchNoCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'Batch No'), style: const TextStyle(fontSize: 12))),
                SizedBox(width: 150, child: InkWell(
                  onTap: locked ? null : () => _pickDate(b.expiryDate, (d) => setState(() => b.expiryDate = d)),
                  child: InputDecorator(decoration: dec.copyWith(labelText: 'Expiry Date'),
                      child: Text(_displayDate(b.expiryDate), style: const TextStyle(fontSize: 12))),
                )),
                SizedBox(width: 90, child: TextFormField(controller: b.qtyPackCtrl, enabled: !locked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: showLooseQty ? 'Qty Pack' : 'Qty'), style: const TextStyle(fontSize: 12),
                    onChanged: (_) => setState(() {}))),
                if (showLooseQty) SizedBox(width: 90, child: TextFormField(controller: b.qtyLooseCtrl, enabled: !locked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Qty Loose'), style: const TextStyle(fontSize: 12),
                    onChanged: (_) => setState(() {}))),
                if (!locked) IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative), onPressed: () => _removeNewBatchRow(row, b)),
              ]),
            ))
          else
            ...row.newSerialRows.map((s) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                SizedBox(width: 200, child: TextFormField(controller: s.serialCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'Serial No'), style: const TextStyle(fontSize: 12),
                    onChanged: (_) => setState(() {}))),
                if (!locked) IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative), onPressed: () => _removeNewSerialRow(row, s)),
              ]),
            )),
        ]),
      );
    }

    // '-' : existing on-hand candidates, Material-Issue-style.
    if (!row.candidatesLoaded) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(isBatch ? 'Select Batches to Reduce' : 'Select Serial Numbers to Reduce',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch ? '${row.existingBatchQtySum.toStringAsFixed(2)} / ${row.baseQty.toStringAsFixed(2)}' : '${row.selectedExistingSerialCount} / ${row.baseQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: (isBatch ? (row.existingBatchQtySum - row.baseQty).abs() < 0.0001 : row.selectedExistingSerialCount == row.baseQty.round()) ? AppColors.positive : AppColors.negative)),
        ]),
        const SizedBox(height: 8),
        if (isBatch && row.batchCandidates.isEmpty)
          const Text('No batches currently in stock.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (!isBatch && row.serialCandidates.isEmpty)
          const Text('No serial numbers currently in stock.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (isBatch)
          ...row.batchCandidates.map((b) => Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 130, child: Text(b.batchNo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
              SizedBox(width: 150, child: Text('Available: ${b.availableBalance.toStringAsFixed(2)}${b.expiryDate != null ? ' · Exp ${b.expiryDate}' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
              SizedBox(width: 90, child: TextFormField(
                controller: b.qtyCtrl, enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Reduce Qty'),
                style: const TextStyle(fontSize: 12),
                onChanged: (_) => setState(() {}),
              )),
            ]),
          ))
        else
          ...row.serialCandidates.map((s) => Padding(
            padding: const EdgeInsets.only(top: 2),
            child: CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
              value: s.selected,
              onChanged: locked ? null : (v) => setState(() => s.selected = v ?? false),
              title: Text(s.serialNo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            ),
          )),
      ]),
    );
  }

  Widget _buildPostedVouchersSection() {
    Widget colHeader(String label, {TextAlign align = TextAlign.left}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(label, textAlign: align, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
    );
    Widget cell(String text, {TextAlign align = TextAlign.left, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(text, textAlign: align, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Posted Journal Entries', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        if (_loadingVoucherLines)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else
          ..._postedVouchers.map((v) {
            final transNo = v['trans_no'] as String;
            final lines = _voucherLines[transNo] ?? [];
            double totalDebit = 0, totalCredit = 0;
            for (final l in lines) {
              final amount = (l['trans_amount'] as num? ?? 0).toDouble();
              if (l['trans_nature'] == 'DR') { totalDebit += amount; } else { totalCredit += amount; }
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                    child: const Text('Stock Adjustment Voucher', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary)),
                  ),
                  const SizedBox(width: 10),
                  Text(transNo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.positive)),
                ]),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    Container(
                      color: AppColors.primary,
                      child: Row(children: [
                        Expanded(flex: 2, child: colHeader('Serial No')),
                        Expanded(flex: 4, child: colHeader('Ledger Name')),
                        Expanded(flex: 2, child: colHeader('Debit', align: TextAlign.right)),
                        Expanded(flex: 2, child: colHeader('Credit', align: TextAlign.right)),
                      ]),
                    ),
                    for (var i = 0; i < lines.length; i++) Builder(builder: (_) {
                      final l = lines[i];
                      final account = l['account'] as Map<String, dynamic>?;
                      final ledgerName = account != null ? '[${account['account_code']}] ${account['account_name']}' : '—';
                      final amount = (l['trans_amount'] as num? ?? 0).toDouble();
                      final isDr = l['trans_nature'] == 'DR';
                      return Container(
                        color: i.isEven ? Colors.white : AppColors.background,
                        child: Row(children: [
                          Expanded(flex: 2, child: cell('${l['serial_no']}')),
                          Expanded(flex: 4, child: cell(ledgerName)),
                          Expanded(flex: 2, child: cell(isDr ? amount.toStringAsFixed(2) : '—', align: TextAlign.right)),
                          Expanded(flex: 2, child: cell(!isDr ? amount.toStringAsFixed(2) : '—', align: TextAlign.right)),
                        ]),
                      );
                    }),
                    Container(
                      decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.06), border: const Border(top: BorderSide(color: AppColors.border))),
                      child: Row(children: [
                        const Expanded(flex: 6, child: Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))),
                        Expanded(flex: 2, child: cell(totalDebit.toStringAsFixed(2), align: TextAlign.right, bold: true)),
                        Expanded(flex: 2, child: cell(totalCredit.toStringAsFixed(2), align: TextAlign.right, bold: true)),
                      ]),
                    ),
                  ]),
                ),
              ]),
            );
          }),
      ],
    );
  }
}

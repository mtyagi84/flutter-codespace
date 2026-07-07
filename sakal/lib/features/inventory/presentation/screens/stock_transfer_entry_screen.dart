import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../domain/repositories/stock_transfer_repository.dart';
import '../providers/stock_transfer_providers.dart';

class _TransferBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  num availableBalance;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');
  _TransferBatchCandidate({required this.batchNo, this.expiryDate, required this.availableBalance});
  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

class _TransferSerialCandidate {
  final String serialNo;
  bool selected = false;
  _TransferSerialCandidate({required this.serialNo});
}

class _TransferLineRow {
  String? sourceRequestLineSerial; // stringified int, matches the request line's own serial_no
  String? productId;
  String  productDisplay;
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor;
  final double requestRemainingQty; // 0 for DIRECT lines — no ceiling
  final String trackingType;
  final TextEditingController qtyPackCtrl;
  final TextEditingController qtyLooseCtrl;
  final TextEditingController salesPriceCtrl = TextEditingController();
  final TextEditingController remarksCtrl = TextEditingController();
  num costPriceHint = 0;
  double chargeAmount = 0; // computed by apportionment, not user-editable
  List<_TransferBatchCandidate>  batchCandidates  = [];
  List<_TransferSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  _TransferLineRow({
    this.sourceRequestLineSerial,
    this.productId,
    this.productDisplay = '',
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    this.requestRemainingQty = 0,
    this.trackingType = 'NONE',
    double initialQtyPack = 0,
  }) : qtyPackCtrl = TextEditingController(text: initialQtyPack.toStringAsFixed(2)),
       qtyLooseCtrl = TextEditingController(text: '0');

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get baseQty  => qtyPack * uomConversionFactor + qtyLoose;
  double get salesPrice => double.tryParse(salesPriceCtrl.text) ?? 0;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    salesPriceCtrl.dispose();
    remarksCtrl.dispose();
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class _TransferChargeRow {
  String chargeId;
  String chargeName;
  String nature;
  String? glAccountId;
  final TextEditingController amountCtrl;
  _TransferChargeRow({required this.chargeId, required this.chargeName, required this.nature, this.glAccountId, double amount = 0})
      : amountCtrl = TextEditingController(text: amount.toStringAsFixed(2));
  double get amount => double.tryParse(amountCtrl.text) ?? 0;
  void dispose() => amountCtrl.dispose();
}

class StockTransferEntryScreen extends ConsumerStatefulWidget {
  final String? editTransferNo;
  final String? editTransferDate;
  const StockTransferEntryScreen({super.key, this.editTransferNo, this.editTransferDate});

  @override
  ConsumerState<StockTransferEntryScreen> createState() => _StockTransferEntryScreenState();
}

class _StockTransferEntryScreenState extends ConsumerState<StockTransferEntryScreen>
    with ScreenPermissionMixin<StockTransferEntryScreen> {
  @override String get screenName => RouteNames.stockTransfers;

  StockTransferRepository get _ds => ref.read(stockTransferRepositoryProvider);

  String?  _transferNo;
  DateTime _transferDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _fromLocationId;
  String?  _toLocationId;
  String   _mode = 'DIRECT'; // DIRECT / AGAINST_REQUEST
  String?  _sourceRequestNo;
  String?  _sourceRequestDate;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  String _interLocationModel = 'SIMPLE';
  List<Map<String, dynamic>> _fulfillableRequests = [];
  bool _loadingRequests = false;

  final List<_TransferLineRow>   _lines   = [];
  final List<_TransferChargeRow> _charges = [];
  List<Map<String, dynamic>> _additionalCharges = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  bool _loadingVoucherLines = false;

  bool get _isNew => _transferNo == null;
  bool get _requestLocked => _mode == 'AGAINST_REQUEST' && _sourceRequestNo != null;

  bool get _isLikelyInterEntity {
    if (_interLocationModel != 'INTER_ENTITY') return false;
    final from = _locations.where((l) => l['id'] == _fromLocationId).firstOrNull;
    final to   = _locations.where((l) => l['id'] == _toLocationId).firstOrNull;
    final fromGroup = from?['group_id'] as String?;
    final toGroup   = to?['group_id'] as String?;
    return fromGroup != null && toGroup != null && fromGroup != toGroup;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    for (final c in _charges) { c.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _fromLocationId = session.locationId;
      final results = await Future.wait([
        _ds.getLocations(clientId: session.clientId, companyId: session.companyId),
        _ds.getInterLocationModel(clientId: session.clientId, companyId: session.companyId),
        _ds.getAdditionalCharges(clientId: session.clientId, companyId: session.companyId),
      ]);
      _locations           = results[0] as List<Map<String, dynamic>>;
      _interLocationModel  = results[1] as String;
      _additionalCharges   = results[2] as List<Map<String, dynamic>>;

      if (widget.editTransferNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: widget.editTransferNo!, transferDate: widget.editTransferDate,
        );
        if (header != null) {
          _transferNo        = header['transfer_no'] as String;
          _transferDate       = DateTime.parse(header['transfer_date'] as String);
          _status              = header['status'] as String;
          _fromLocationId       = header['from_location_id'] as String?;
          _toLocationId          = header['to_location_id'] as String?;
          _mode                   = (header['against_request'] as bool? ?? false) ? 'AGAINST_REQUEST' : 'DIRECT';
          _sourceRequestNo          = header['source_request_no'] as String?;
          _sourceRequestDate         = header['source_request_date'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';

          final savedLines = await _ds.getLines(
            clientId: session.clientId, companyId: session.companyId,
            transferNo: _transferNo!, transferDate: _fmtDate(_transferDate),
          );
          final newRows = <_TransferLineRow>[];
          for (final sl in savedLines) {
            final product = sl['product'] as Map<String, dynamic>?;
            final uom     = sl['uom'] as Map<String, dynamic>?;
            final row = _TransferLineRow(
              sourceRequestLineSerial: sl['source_request_line_serial']?.toString(),
              productId: sl['product_id'] as String?,
              productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
              uomId: sl['uom_id'] as String?,
              uomLabel: uom?['description'] as String?,
              uomConversionFactor: (sl['uom_conversion_factor'] as num? ?? 1).toDouble(),
              trackingType: product?['tracking_type'] as String? ?? 'NONE',
              initialQtyPack: (sl['qty_pack'] as num? ?? 0).toDouble(),
            );
            row.qtyLooseCtrl.text = (sl['qty_loose'] as num? ?? 0).toString();
            row.remarksCtrl.text = sl['remarks'] as String? ?? '';
            if (sl['sales_price'] != null) row.salesPriceCtrl.text = (sl['sales_price'] as num).toString();
            row.chargeAmount = (sl['charge_amount'] as num? ?? 0).toDouble();
            _lines.add(row);
            newRows.add(row);
          }

          final savedCharges = await _ds.getCharges(
            clientId: session.clientId, companyId: session.companyId,
            transferNo: _transferNo!, transferDate: _fmtDate(_transferDate),
          );
          for (final sc in savedCharges) {
            _charges.add(_TransferChargeRow(
              chargeId: sc['charge_id'] as String, chargeName: sc['charge_name'] as String,
              nature: sc['nature'] as String? ?? 'ADD', glAccountId: sc['gl_account_id'] as String?,
              amount: (sc['amount'] as num? ?? 0).toDouble(),
            ));
          }

          for (final row in newRows) {
            if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadExistingCandidates(row, newRows.indexOf(row) + 1));
          }
          unawaited(_refreshCostPrices());
        }
      }

      if (_mode == 'AGAINST_REQUEST' && !_requestLocked && _fromLocationId != null) {
        unawaited(_loadFulfillableRequests());
      }

      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadExistingCandidates(_TransferLineRow row, int lineSerial) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final saved = await _ds.getTransferLineBatches(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: _transferNo!, transferDate: _fmtDate(_transferDate), lineSerial: lineSerial,
        );
        final available = await _ds.getAvailableBatches(
          clientId: session.clientId, companyId: session.companyId, locationId: _fromLocationId!, productId: row.productId!,
        );
        final candidates = <String, _TransferBatchCandidate>{};
        for (final b in available) {
          candidates[b['batch_no'] as String] = _TransferBatchCandidate(
            batchNo: b['batch_no'] as String, expiryDate: b['expiry_date'] as String?, availableBalance: b['balance'] as num? ?? 0,
          );
        }
        for (final s in saved) {
          final key = s['batch_no'] as String;
          candidates.putIfAbsent(key, () => _TransferBatchCandidate(batchNo: key, expiryDate: s['expiry_date'] as String?, availableBalance: 0));
          candidates[key]!.qtyCtrl.text = (s['base_qty'] as num? ?? 0).toString();
        }
        if (mounted) setState(() { row.batchCandidates = candidates.values.toList(); row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final saved = await _ds.getTransferLineSerials(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: _transferNo!, transferDate: _fmtDate(_transferDate), lineSerial: lineSerial,
        );
        final savedSet = saved.map((s) => s['serial_no'] as String).toSet();
        final available = await _ds.getAvailableSerials(
          clientId: session.clientId, companyId: session.companyId, locationId: _fromLocationId!, productId: row.productId!,
        );
        final candidates = <String, _TransferSerialCandidate>{};
        for (final s in available) {
          candidates[s['serial_no'] as String] = _TransferSerialCandidate(serialNo: s['serial_no'] as String);
        }
        for (final s in savedSet) {
          candidates.putIfAbsent(s, () => _TransferSerialCandidate(serialNo: s));
          candidates[s]!.selected = true;
        }
        if (mounted) setState(() { row.serialCandidates = candidates.values.toList(); row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingVoucherLines = true);
    try {
      final vouchers = await _ds.getPostedVouchers(clientId: session.clientId, companyId: session.companyId, transferNo: _transferNo!);
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

  Future<void> _loadFulfillableRequests() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingRequests = true);
    try {
      final rows = await _ds.getFulfillableRequests(clientId: session.clientId, companyId: session.companyId, fromLocationId: _fromLocationId!);
      if (mounted) setState(() { _fulfillableRequests = rows; _loadingRequests = false; });
    } catch (e) {
      if (mounted) { setState(() => _loadingRequests = false); _showSnack('Could not load fulfillable requests: $e', color: AppColors.negative); }
    }
  }

  Future<void> _onModeChanged(String mode) async {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _sourceRequestNo = null; _sourceRequestDate = null;
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
    });
    if (mode == 'AGAINST_REQUEST' && _fromLocationId != null) unawaited(_loadFulfillableRequests());
  }

  Future<void> _onFromLocationChanged(String? locId) async {
    setState(() {
      _fromLocationId = locId;
      _sourceRequestNo = null; _sourceRequestDate = null;
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
      _fulfillableRequests = [];
    });
    if (_mode == 'AGAINST_REQUEST' && locId != null) unawaited(_loadFulfillableRequests());
  }

  Future<void> _selectRequest(Map<String, dynamic> req) async {
    final session = ref.read(sessionProvider)!;
    final reqNo   = req['request_no'] as String;
    final reqDate = req['request_date'] as String;
    try {
      final reqLines = await _ds.getRequestLines(clientId: session.clientId, companyId: session.companyId, requestNo: reqNo, requestDate: reqDate);
      if (!mounted) return;
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
      final newRows = <_TransferLineRow>[];
      setState(() {
        _sourceRequestNo = reqNo;
        _sourceRequestDate = reqDate;
        _toLocationId = req['to_location_id'] as String?;
        for (final rl in reqLines) {
          final remaining = (rl['base_qty'] as num? ?? 0).toDouble() - (rl['transferred_qty'] as num? ?? 0).toDouble();
          if (remaining <= 0) continue;
          final product = rl['product'] as Map<String, dynamic>?;
          final uom     = rl['uom'] as Map<String, dynamic>?;
          final row = _TransferLineRow(
            sourceRequestLineSerial: (rl['serial_no'] as int).toString(),
            productId: rl['product_id'] as String?,
            productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
            uomId: rl['uom_id'] as String?,
            uomLabel: uom?['description'] as String?,
            uomConversionFactor: (rl['uom_conversion_factor'] as num? ?? 1).toDouble(),
            requestRemainingQty: remaining,
            trackingType: product?['tracking_type'] as String? ?? 'NONE',
            initialQtyPack: remaining,
          );
          _lines.add(row);
          newRows.add(row);
        }
      });
      for (final row in newRows) {
        if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidatesForNewLine(row));
      }
      unawaited(_refreshCostPrices());
    } catch (e) {
      if (mounted) _showSnack('Could not load request lines: $e', color: AppColors.negative);
    }
  }

  void _addDirectLine() => setState(() => _lines.add(_TransferLineRow()));

  void _removeLine(_TransferLineRow row) {
    setState(() { _lines.remove(row); row.dispose(); });
    unawaited(_refreshCostPrices());
  }

  bool _isDuplicateProduct(String productId, {_TransferLineRow? excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  Future<void> _onProductSelected(_TransferLineRow row, Map<String, dynamic> product) async {
    final productId = product['id'] as String;
    if (_isDuplicateProduct(productId, excluding: row)) {
      _showSnack('This product is already on another line — edit that line\'s quantity instead.', color: AppColors.negative);
      return;
    }
    setState(() {
      row.productId = productId;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.uomId = product['base_uom_id'] as String?;
      final uom = product['uom'] as Map<String, dynamic>?;
      row.uomLabel = uom?['description'] as String?;
    });
    if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidatesForNewLine(row));
    unawaited(_refreshCostPrices());
  }

  Future<void> _loadCandidatesForNewLine(_TransferLineRow row) async {
    final session = ref.read(sessionProvider)!;
    if (_fromLocationId == null || row.productId == null) return;
    try {
      if (row.isBatchTracked) {
        final rows = await _ds.getAvailableBatches(clientId: session.clientId, companyId: session.companyId, locationId: _fromLocationId!, productId: row.productId!);
        final candidates = rows.map((b) => _TransferBatchCandidate(batchNo: b['batch_no'] as String, expiryDate: b['expiry_date'] as String?, availableBalance: b['balance'] as num? ?? 0)).toList();
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final rows = await _ds.getAvailableSerials(clientId: session.clientId, companyId: session.companyId, locationId: _fromLocationId!, productId: row.productId!);
        final candidates = rows.map((s) => _TransferSerialCandidate(serialNo: s['serial_no'] as String)).toList();
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  Future<void> _refreshCostPrices() async {
    final session = ref.read(sessionProvider)!;
    final ids = _lines.map((l) => l.productId).whereType<String>().toSet().toList();
    if (ids.isEmpty || _fromLocationId == null) return;
    try {
      final prices = await _ds.getCostPrices(clientId: session.clientId, companyId: session.companyId, locationId: _fromLocationId!, productIds: ids);
      if (!mounted) return;
      setState(() {
        for (final l in _lines) { if (l.productId != null) l.costPriceHint = prices[l.productId] ?? 0; }
        _recalculateChargeApportionment();
      });
    } catch (_) {
      // Display-only hint — save/approve still works without it.
    }
  }

  void _addCharge() {
    if (_additionalCharges.isEmpty) return;
    final first = _additionalCharges.first;
    setState(() {
      _charges.add(_TransferChargeRow(
        chargeId: first['id'] as String, chargeName: first['charge_name'] as String,
        nature: first['nature'] as String? ?? 'ADD', glAccountId: first['default_gl_account_id'] as String?,
      ));
      _recalculateChargeApportionment();
    });
  }

  void _removeCharge(_TransferChargeRow row) {
    setState(() { row.dispose(); _charges.remove(row); _recalculateChargeApportionment(); });
  }

  double _lineValueForApportion(_TransferLineRow l) => (_isLikelyInterEntity ? l.salesPrice : l.costPriceHint.toDouble()) * l.baseQty;

  double get _linesValueTotal => _lines.fold(0.0, (s, l) => s + _lineValueForApportion(l));
  double get _chargesTotal => _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));

  void _recalculateChargeApportionment() {
    if (_lines.isEmpty) return;
    final total = _linesValueTotal;
    final chargesTotal = _charges.fold(0.0, (s, c) => s + c.amount);
    for (final l in _lines) {
      final share = total > 0 ? _lineValueForApportion(l) / total : (1 / _lines.length);
      l.chargeAmount = chargesTotal * share;
    }
  }

  /// Mandatory allocation whenever baseQty > 0 — same reasoning as Material
  /// Issue/Purchase Return: leaving it unallocated would silently fall
  /// through into the plain aggregate movement, bypassing the strict check.
  String? _batchSerialError(_TransferLineRow row) {
    if (row.baseQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No batches currently in stock for "${row.productDisplay}".';
      if ((row.batchQtySum - row.baseQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} but the transfer quantity is ${row.baseQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialCandidates.isEmpty) return 'No serial numbers currently in stock for "${row.productDisplay}".';
      if (row.selectedSerialCount != row.baseQty.round() || (row.baseQty - row.baseQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the transfer quantity (${row.baseQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  String? _qtyError(_TransferLineRow row) {
    if (row.baseQty < 0) return 'Transfer qty for "${row.productDisplay}" cannot be negative.';
    if (_mode == 'AGAINST_REQUEST' && row.baseQty > row.requestRemainingQty + 0.0001) {
      return 'Transfer qty for "${row.productDisplay}" (${row.baseQty.toStringAsFixed(2)}) cannot exceed the request\'s remaining qty (${row.requestRemainingQty.toStringAsFixed(2)}).';
    }
    return null;
  }

  Future<bool> _saveDraft() async {
    if (_fromLocationId == null || _toLocationId == null) { _showSnack('Select both From Location and To Location.', color: AppColors.negative); return false; }
    if (_fromLocationId == _toLocationId) { _showSnack('From Location and To Location cannot be the same.', color: AppColors.negative); return false; }
    final transferLines = _lines.where((l) => l.baseQty > 0).toList();
    if (transferLines.isEmpty) { _showSnack('Add at least one line with a transfer quantity.', color: AppColors.negative); return false; }
    for (final l in _lines) {
      final qtyErr = _qtyError(l);
      if (qtyErr != null) { _showSnack(qtyErr, color: AppColors.negative); return false; }
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }
    for (final c in _charges) {
      if (c.glAccountId == null) { _showSnack('Charge "${c.chargeName}" has no GL account configured.', color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (var i = 0; i < transferLines.length; i++) {
        final l = transferLines[i];
        final lineSerial = i + 1;
        if (l.isBatchTracked) {
          for (final b in l.batchCandidates.where((b) => b.allocatedQty > 0)) {
            batches.add({'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate, 'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty});
          }
        } else if (l.isSerialTracked) {
          for (final s in l.serialCandidates.where((s) => s.selected)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
          }
        }
      }

      var chargeSerial = 1;
      final charges = _charges.map((c) => {
        'serial_no': chargeSerial++,
        'charge_id': c.chargeId, 'charge_name': c.chargeName, 'nature': c.nature, 'gl_account_id': c.glAccountId,
        'amount_or_percent': 'AMOUNT', 'percent': null, 'amount': c.amount,
      }).toList();

      final transferNo = await _ds.save(
        header: {
          'client_id':          session.clientId,
          'company_id':         session.companyId,
          'from_location_id':   _fromLocationId,
          'to_location_id':     _toLocationId,
          'transfer_no':        _transferNo,
          'transfer_date':      _fmtDate(_transferDate),
          'against_request':    _mode == 'AGAINST_REQUEST',
          'source_request_no':  _sourceRequestNo,
          'source_request_date': _sourceRequestDate,
          'remarks':            _remarksCtrl.text.trim(),
        },
        lines: transferLines.asMap().entries.map((e) => {
          'serial_no':                      e.key + 1,
          'source_request_no':               _mode == 'AGAINST_REQUEST' ? _sourceRequestNo : null,
          'source_request_date':              _mode == 'AGAINST_REQUEST' ? _sourceRequestDate : null,
          'source_request_line_serial':        _mode == 'AGAINST_REQUEST' ? int.tryParse(e.value.sourceRequestLineSerial ?? '') : null,
          'product_id':                          e.value.productId,
          'uom_id':                                e.value.uomId,
          'uom_conversion_factor':                  e.value.uomConversionFactor,
          'qty_pack':                                 e.value.qtyPack,
          'qty_loose':                                 e.value.qtyLoose,
          'base_qty':                                   e.value.baseQty,
          'sales_price':                                 _isLikelyInterEntity ? e.value.salesPrice : null,
          'charge_amount':                                e.value.chargeAmount,
          'remarks':                                       e.value.remarksCtrl.text.trim(),
        }).toList(),
        batches: batches,
        serials: serials,
        charges: charges,
        userId: session.userId,
      );
      if (mounted) {
        setState(() { _transferNo = transferNo; _saving = false; });
        _showSnack('Stock Transfer $transferNo saved.', color: AppColors.positive);
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

  Future<void> _approveTransfer() async {
    if (_transferNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (_transferDate.isAfter(DateTime.now())) {
      _showSnack('Transfer date cannot be in the future.', color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Stock Transfer'),
        content: const Text('Once approved, stock will leave the From Location immediately and the appropriate journal entries will be posted to Finance. This transfer can no longer be edited. Continue?'),
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
        transferNo: _transferNo!, transferDate: _fmtDate(_transferDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Stock Transfer $_transferNo approved.', color: AppColors.positive);
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

    final canSave     = !isOffline && _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
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
                  if (canSave || showApprove) ...[const SizedBox(height: 10), _buildActionButtons(canSave: canSave, canApprove: showApprove)],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
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
                    if (_mode == 'AGAINST_REQUEST' && !_requestLocked) ...[
                      _buildRequestPickerCard(locked),
                      const SizedBox(height: 16),
                    ],
                    _buildLinesCard(locked, showLooseQty),
                    const SizedBox(height: 16),
                    _buildChargesCard(locked, isMobile),
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
    Text(_transferNo != null ? 'Stock Transfer · $_transferNo' : 'New Stock Transfer',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    _status != 'DRAFT' ? _statusChip(_status) : Text(_transferNo != null ? 'Draft' : 'Unsaved draft',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
  ]);

  Widget _statusChip(String status) {
    final color = status == 'APPROVED' ? AppColors.positive : status == 'CLOSED' ? AppColors.textSecondary : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool canApprove}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : _saveDraft,
      child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save Draft'),
    ),
    if (canSave && canApprove) const SizedBox(width: 12),
    if (canApprove) FilledButton(
      onPressed: _approving ? null : _approveTransfer,
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
    final modeLocked = locked || _lines.isNotEmpty;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Builder(builder: (_) {
            final modeField = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Mode'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _mode,
              items: const [
                DropdownMenuItem(value: 'DIRECT', child: Text('Direct', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'AGAINST_REQUEST', child: Text('Against Request', style: TextStyle(fontSize: 13))),
              ],
              onChanged: modeLocked ? null : (v) => _onModeChanged(v!),
            ));
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'From Location *'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _fromLocationId,
              items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: modeLocked ? null : (v) => _onFromLocationChanged(v),
            ));
            final f2 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'To Location *'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _toLocationId,
              items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (locked || _requestLocked) ? null : (v) => setState(() => _toLocationId = v),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: modeField), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2),
                  ])
                : Row(children: [Expanded(child: modeField), const SizedBox(width: 12), Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]);
          }),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Transfer No'),
              child: Text(_transferNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _transferNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f2 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_transferDate, (d) => setState(() => _transferDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'Transfer Date *', suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_transferDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            final f3 = field(TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Remarks'), style: const TextStyle(fontSize: 13)));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f3),
                  ])
                : Row(children: [Expanded(flex: 2, child: f1), const SizedBox(width: 12), Expanded(flex: 2, child: f2), const SizedBox(width: 12), Expanded(flex: 3, child: f3)]);
          }),
        ]),
      ),
    );
  }

  Widget _buildRequestPickerCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Fulfillable Stock Transfer Requests', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Approved or partially-transferred requests at this From Location.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_fromLocationId == null)
            const Text('Select a From Location first.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else if (_loadingRequests)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_fulfillableRequests.isEmpty)
            const Text('No fulfillable requests at this location.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else
            RadioGroup<String>(
              groupValue: _sourceRequestNo,
              onChanged: (v) {
                if (locked) return;
                final r = _fulfillableRequests.where((x) => x['request_no'] == v).firstOrNull;
                if (r != null) _selectRequest(r);
              },
              child: Column(children: _fulfillableRequests.map((r) {
                final to = r['to_location'] as Map<String, dynamic>?;
                return RadioListTile<String>(
                  dense: true, contentPadding: EdgeInsets.zero,
                  value: r['request_no'] as String,
                  title: Text(r['request_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  subtitle: Text('${r['request_date']} · To ${to?['location_name'] ?? '—'} · ${r['status']}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                );
              }).toList()),
            ),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked, bool showLooseQty) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Transfer Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (_mode == 'DIRECT' && !locked) TextButton.icon(onPressed: _addDirectLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
          ]),
          const SizedBox(height: 8),
          if (_lines.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
                _mode == 'AGAINST_REQUEST' ? 'No lines yet — pick a request above.' : 'No lines yet — add a product.',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)))
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
                    if (_mode == 'DIRECT')
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
                                      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          child: Text('[${p['product_code']}] ${p['product_name']}', style: const TextStyle(fontSize: 13))),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      SizedBox(width: 240, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(row.productDisplay, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('Remaining ${row.requestRemainingQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}',
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ])),
                    SizedBox(width: 90, child: TextFormField(
                      controller: row.qtyPackCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: showLooseQty ? 'Qty Pack' : 'Quantity'),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) { setState(() {}); unawaited(_refreshCostPrices()); },
                    )),
                    if (showLooseQty) SizedBox(width: 90, child: TextFormField(
                      controller: row.qtyLooseCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: 'Qty Loose'),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) { setState(() {}); unawaited(_refreshCostPrices()); },
                    )),
                    if (_isLikelyInterEntity) SizedBox(width: 100, child: TextFormField(
                      controller: row.salesPriceCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: 'Sales Price'),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(_recalculateChargeApportionment),
                    )),
                    if (row.costPriceHint > 0) SizedBox(width: 100, child: Text('Cost: ${row.costPriceHint.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                    if (row.chargeAmount > 0) SizedBox(width: 110, child: Text('+ Charges: ${row.chargeAmount.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                    if (_mode == 'DIRECT' && !locked) IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative), onPressed: () => _removeLine(row)),
                  ]),
                  if (row.isBatchTracked || row.isSerialTracked) _buildBatchSerialEditor(row, locked),
                ]),
              ),
            )),
        ]),
      ),
    );
  }

  Widget _buildBatchSerialEditor(_TransferLineRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    final isBatch = row.isBatchTracked;

    if (!row.candidatesLoaded) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(isBatch ? 'Select Batches to Transfer' : 'Select Serial Numbers to Transfer',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch ? '${row.batchQtySum.toStringAsFixed(2)} / ${row.baseQty.toStringAsFixed(2)}' : '${row.selectedSerialCount} / ${row.baseQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: (isBatch ? (row.batchQtySum - row.baseQty).abs() < 0.0001 : row.selectedSerialCount == row.baseQty.round()) ? AppColors.positive : AppColors.negative)),
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
                decoration: dec.copyWith(labelText: 'Qty'),
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

  Widget _buildChargesCard(bool locked, bool isMobile) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Additional Charges', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (!locked && _additionalCharges.isNotEmpty) TextButton.icon(onPressed: _addCharge, icon: const Icon(Icons.add, size: 16), label: const Text('Add Charge')),
          ]),
          const SizedBox(height: 4),
          Text(_isLikelyInterEntity ? 'Deferred to Stock Receipt — posted once the receiving group records the purchase.' : 'Posted immediately with this transfer\'s journal entry.',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_charges.isEmpty)
            const Text('No additional charges (freight, loading, handling…).', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else
            ..._charges.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(width: 200, child: DropdownButtonFormField<String>(
                  decoration: dec.copyWith(labelText: 'Charge Type'),
                  isExpanded: true, isDense: true, itemHeight: null,
                  initialValue: row.chargeId,
                  items: _additionalCharges.map((c) => DropdownMenuItem(value: c['id'] as String,
                      child: Text(c['charge_name'] as String, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: locked ? null : (v) {
                    final c = _additionalCharges.where((x) => x['id'] == v).firstOrNull;
                    if (c == null) return;
                    setState(() {
                      row.chargeId = c['id'] as String;
                      row.chargeName = c['charge_name'] as String;
                      row.nature = c['nature'] as String? ?? 'ADD';
                      row.glAccountId = c['default_gl_account_id'] as String?;
                    });
                  },
                )),
                SizedBox(width: 90, child: Text(row.nature, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                SizedBox(width: 110, child: TextFormField(
                  controller: row.amountCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: 'Amount'),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (_) => setState(_recalculateChargeApportionment),
                )),
                if (!locked) IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative), onPressed: () => _removeCharge(row)),
              ]),
            )),
          if (_charges.isNotEmpty) ...[
            const Divider(height: 20),
            Align(alignment: Alignment.centerRight, child: Text('Total Charges: ${_chargesTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
          ],
        ]),
      ),
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
            final voucherType = v['voucher_type_code'] as String? ?? '';
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
                    child: Text(voucherType, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary)),
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

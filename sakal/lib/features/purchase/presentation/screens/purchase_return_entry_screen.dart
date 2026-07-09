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
import '../../domain/repositories/purchase_return_repository.dart';
import '../providers/purchase_return_providers.dart';

/// One batch this GRN line originally received — the user allocates however
/// much of the line's return qty comes from this specific batch. Balance is
/// a UX hint only; the real block is fn_post_stock_movement's strict
/// per-batch check (migration 063) at Approve time.
class _ReturnBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final String? manufacturingDate;
  final double receivedQty;
  num availableBalance = 0;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');

  _ReturnBatchCandidate({required this.batchNo, this.expiryDate, this.manufacturingDate, required this.receivedQty});

  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

/// One serial this GRN line originally received — the user checks which
/// exact units are going back. status is a UX hint only, same caveat as
/// _ReturnBatchCandidate.
class _ReturnSerialCandidate {
  final String serialNo;
  String status;
  bool selected = false;

  _ReturnSerialCandidate({required this.serialNo, this.status = 'IN_STOCK'});
}

class _ReturnLineRow {
  final String sourceGrnNo;
  final String sourceGrnDate;
  final int    sourceGrnLineSerial;
  final String productId;
  final String productDisplay;
  final String? uomId;
  final String? uomLabel;
  final double uomConversionFactor;
  final double grnQty;         // the GRN line's original received qty
  final double rate;
  final String? taxGroupId;
  final double grnTaxAmount;   // the GRN line's own estimated tax (deferred at GRN time)
  final bool   isBilled;       // whether the source GRN has already been billed
  final bool   hasSourcePo;    // whether the source GRN line traces to a PO
  final String? barcode;       // carried forward from the source GRN line, if any
  final String trackingType;   // NONE / BATCH / BATCH_WITH_EXPIRY / SERIAL
  final int?   existingLineSerialNo; // this line's own serial_no if reloaded from a saved return, else null (brand-new line)
  final TextEditingController qtyPackCtrl;
  final TextEditingController qtyLooseCtrl;
  List<_ReturnBatchCandidate>  batchCandidates  = [];
  List<_ReturnSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  _ReturnLineRow({
    required this.sourceGrnNo,
    required this.sourceGrnDate,
    required this.sourceGrnLineSerial,
    required this.productId,
    required this.productDisplay,
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    required this.grnQty,
    required this.rate,
    this.taxGroupId,
    this.grnTaxAmount = 0,
    required this.isBilled,
    required this.hasSourcePo,
    this.barcode,
    this.trackingType = 'NONE',
    this.existingLineSerialNo,
    double? initialQtyPack,
    double initialQtyLoose = 0,
  }) : qtyPackCtrl = TextEditingController(text: (initialQtyPack ?? grnQty).toStringAsFixed(2)),
       qtyLooseCtrl = TextEditingController(text: initialQtyLoose.toStringAsFixed(2));

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get returnQty => qtyPack * uomConversionFactor + qtyLoose;
  double get grossAmount => returnQty * rate;
  double get suggestedTaxAmount => grnQty > 0 ? grnTaxAmount * (returnQty / grnQty) : 0;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class _ReturnChargeRow {
  final String sourceGrnNo;
  final String sourceGrnDate;
  final String chargeId;
  final String chargeName;
  final bool   isTaxable;
  final String? taxId;
  final String nature;
  final String? glAccountId;
  final double taxAmount;
  final TextEditingController amountCtrl;

  _ReturnChargeRow({
    required this.sourceGrnNo,
    required this.sourceGrnDate,
    required this.chargeId,
    required this.chargeName,
    required this.isTaxable,
    this.taxId,
    required this.nature,
    this.glAccountId,
    this.taxAmount = 0,
    required double initialAmount,
  }) : amountCtrl = TextEditingController(text: initialAmount.toStringAsFixed(2));

  double get amount => double.tryParse(amountCtrl.text) ?? 0;

  void dispose() => amountCtrl.dispose();
}

class PurchaseReturnEntryScreen extends ConsumerStatefulWidget {
  final String? editReturnNo;
  final String? editReturnDate;
  const PurchaseReturnEntryScreen({super.key, this.editReturnNo, this.editReturnDate});

  @override
  ConsumerState<PurchaseReturnEntryScreen> createState() => _PurchaseReturnEntryScreenState();
}

class _PurchaseReturnEntryScreenState extends ConsumerState<PurchaseReturnEntryScreen>
    with ScreenPermissionMixin<PurchaseReturnEntryScreen> {
  // Entry screen is not itself a menu item — Menu -> List -> Entry pattern.
  @override String get screenName => RouteNames.purchaseReturns;

  PurchaseReturnRepository get _ds => ref.read(purchaseReturnRepositoryProvider);

  // ── Header state ─────────────────────────────────────────────────────────
  String?  _returnNo;
  DateTime _returnDate = DateTime.now();
  String   _status     = 'DRAFT';
  String?  _locationId;

  String?  _supplierId;
  String?  _supplierDisplay;

  String?  _returnCurrencyId;
  String?  _returnCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  double   get _rateToBase  => double.tryParse(_rateToBaseCtrl.text) ?? 1;
  double   get _rateToLocal => double.tryParse(_rateToLocalCtrl.text) ?? 1;

  final _taxableAmountCtrl = TextEditingController(text: '0');
  final _taxAmountCtrl     = TextEditingController(text: '0');
  double get _taxableAmount => double.tryParse(_taxableAmountCtrl.text) ?? 0;
  double get _taxAmount     => double.tryParse(_taxAmountCtrl.text) ?? 0;
  String? _reason;
  List<String> _reasons = [];
  final _remarksCtrl = TextEditingController();

  // ── GRN picker + lines/charges ────────────────────────────────────────────
  List<Map<String, dynamic>> _suppliers   = [];
  List<Map<String, dynamic>> _pendingGrns = [];
  Set<String> _fullyReturnedGrnKeys = {};
  final Set<String> _selectedGrnKeys = {};
  final List<_ReturnLineRow> _lines = [];
  final List<_ReturnChargeRow> _charges = [];

  String _grnKey(Map<String, dynamic> g) => '${g['grn_no']}|${g['grn_date']}';

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving    = false;
  bool    _approving = false;
  bool    _loadingGrns = false;
  bool    _printing  = false;

  // ── Posted Journal Entries — a return can post BOTH a JV and an SDN ──────
  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  bool _loadingVoucherLines = false;

  bool get _isNew => _returnNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _rateToBaseCtrl.dispose();
    _rateToLocalCtrl.dispose();
    _taxableAmountCtrl.dispose();
    _taxAmountCtrl.dispose();
    _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    for (final c in _charges) { c.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _suppliers = await _ds.getSuppliersWithApprovedGrns(
          clientId: session.clientId, companyId: session.companyId);
      final reasonRows = await _ds.getCommonMastersByType(
          clientId: session.clientId, companyId: session.companyId, typeKey: 'PURCHASE_RETURN_REASON');
      _reasons = reasonRows.map((r) => r['description'] as String).toList();

      if (widget.editReturnNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          returnNo: widget.editReturnNo!, returnDate: widget.editReturnDate,
        );
        if (header != null) {
          _returnNo           = header.returnNo;
          _returnDate         = DateTime.parse(header.returnDate);
          _status             = header.status;
          _locationId         = header.locationId;
          _supplierId         = header.supplierId;
          _supplierDisplay    = header.supplierName != null ? '[${header.supplierCode}] ${header.supplierName}' : '';
          _returnCurrencyId   = header.returnCurrencyId;
          _returnCurrencyCode = header.returnCurrencyCode;
          _rateToBaseCtrl.text  = header.rateToBase.toString();
          _rateToLocalCtrl.text = header.rateToLocal.toString();
          _taxableAmountCtrl.text = header.taxableAmount.toString();
          _taxAmountCtrl.text     = header.taxAmount.toString();
          _reason             = header.reason;
          _remarksCtrl.text   = header.remarks ?? '';

          if (_supplierId != null) {
            _pendingGrns = await _ds.getGrnsForSupplier(
              clientId: session.clientId, companyId: session.companyId, supplierId: _supplierId!,
            );
            _fullyReturnedGrnKeys = await _ds.getFullyReturnedGrnKeys(
              clientId: session.clientId, companyId: session.companyId,
            );
          }

          await _loadExistingLinesAndCharges(session);
        }
      }
      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') {
        unawaited(_loadPostedVouchers());
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  /// Reloads this return's own previously-saved lines/charges — needed both
  /// to re-open a DRAFT for further editing and to display an APPROVED
  /// return (view + print). Each saved line only stores its own qty/product/
  /// source-GRN reference (rid_purchase_return_lines) — the rest of the
  /// display data (product name, UOM, rate, tax group, whether the GRN is
  /// billed/traces to a PO) is looked up fresh from the source GRN's own
  /// lines, same data getGrnLines already returns when a GRN is freshly
  /// picked, so both code paths end up with an identically-shaped row.
  Future<void> _loadExistingLinesAndCharges(UserSession session) async {
    final savedLines = await _ds.getReturnLines(
      clientId: session.clientId, companyId: session.companyId,
      returnNo: _returnNo!, returnDate: _fmtDate(_returnDate),
    );
    if (savedLines.isEmpty) return;

    final grnKeys = <String>{};
    for (final l in savedLines) { grnKeys.add('${l['source_grn_no']}|${l['source_grn_date']}'); }

    final grnLinesByKey = <String, List<Map<String, dynamic>>>{};
    for (final key in grnKeys) {
      final parts = key.split('|');
      grnLinesByKey[key] = await _ds.getGrnLines(
        clientId: session.clientId, companyId: session.companyId, grnNo: parts[0], grnDate: parts[1],
      );
    }

    final newLines = <_ReturnLineRow>[];
    for (final sl in savedLines) {
      final grnNo   = sl['source_grn_no'] as String;
      final grnDate = sl['source_grn_date'] as String;
      final key     = '$grnNo|$grnDate';
      final grn     = _pendingGrns.firstWhere(
        (g) => g['grn_no'] == grnNo && g['grn_date'] == grnDate,
        orElse: () => const {},
      );
      final isBilled = grn['billed_invoice_no'] != null;
      final gl = (grnLinesByKey[key] ?? const []).firstWhere(
        (g) => g['serial_no'] == sl['source_grn_line_serial'],
        orElse: () => const {},
      );
      final product = gl['product'] as Map<String, dynamic>?;
      final uom     = gl['uom'] as Map<String, dynamic>?;
      final row = _ReturnLineRow(
        sourceGrnNo: grnNo, sourceGrnDate: grnDate,
        sourceGrnLineSerial: sl['source_grn_line_serial'] as int,
        productId: sl['product_id'] as String,
        productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
        uomId: gl['uom_id'] as String?,
        uomLabel: uom?['description'] as String?,
        uomConversionFactor: (gl['uom_conversion_factor'] as num? ?? 1).toDouble(),
        grnQty: (gl['base_qty'] as num? ?? 0).toDouble(),
        rate: (gl['rate'] as num? ?? 0).toDouble(),
        taxGroupId: gl['tax_group_id'] as String?,
        grnTaxAmount: (gl['tax_amount'] as num? ?? 0).toDouble(),
        isBilled: isBilled,
        hasSourcePo: gl['source_po_order_no'] != null,
        barcode: gl['barcode'] as String?,
        trackingType: product?['tracking_type'] as String? ?? 'NONE',
        existingLineSerialNo: sl['serial_no'] as int,
        initialQtyPack: (sl['qty_pack'] as num? ?? sl['base_qty'] as num? ?? 0).toDouble(),
        initialQtyLoose: (sl['qty_loose'] as num? ?? 0).toDouble(),
      );
      _lines.add(row);
      newLines.add(row);
      _selectedGrnKeys.add(key);
    }

    final savedCharges = await _ds.getReturnCharges(
      clientId: session.clientId, companyId: session.companyId,
      returnNo: _returnNo!, returnDate: _fmtDate(_returnDate),
    );
    for (final sc in savedCharges) {
      _charges.add(_ReturnChargeRow(
        sourceGrnNo: sc['source_grn_no'] as String? ?? '',
        sourceGrnDate: sc['source_grn_date'] as String? ?? '',
        chargeId: sc['charge_id'] as String,
        chargeName: sc['charge_name'] as String,
        isTaxable: sc['is_taxable'] as bool? ?? false,
        taxId: sc['tax_id'] as String?,
        nature: sc['nature'] as String? ?? 'ADD',
        glAccountId: sc['gl_account_id'] as String?,
        taxAmount: (sc['tax_amount'] as num? ?? 0).toDouble(),
        initialAmount: (sc['amount'] as num? ?? 0).toDouble(),
      ));
    }

    for (final row in newLines) {
      if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row));
    }
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingVoucherLines = true);
    try {
      final vouchers = await _ds.getPostedVouchers(
        clientId: session.clientId, companyId: session.companyId, returnNo: _returnNo!,
      );
      final lines = <String, List<Map<String, dynamic>>>{};
      for (final v in vouchers) {
        lines[v['trans_no'] as String] = await _ds.getPostedVoucherLines(
          clientId: session.clientId, companyId: session.companyId,
          voucherNo: v['trans_no'] as String, voucherDate: v['trans_date'] as String,
        );
      }
      if (mounted) {
        setState(() {
          _postedVouchers = vouchers;
          _voucherLines
            ..clear()
            ..addAll(lines);
          _loadingVoucherLines = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingVoucherLines = false);
    }
  }

  // ── Supplier selection ────────────────────────────────────────────────────

  Future<void> _onSupplierSelected(Map<String, dynamic> supplier) async {
    setState(() {
      _supplierId      = supplier['id'] as String;
      _supplierDisplay = '[${supplier['account_code']}] ${supplier['account_name']}';
      _selectedGrnKeys.clear();
      _returnCurrencyId   = null;
      _returnCurrencyCode = null;
      for (final l in _lines) { l.dispose(); }
      for (final c in _charges) { c.dispose(); }
      _lines.clear();
      _charges.clear();
      _pendingGrns = [];
      _loadingGrns = true;
    });
    final session = ref.read(sessionProvider)!;
    try {
      final rows = await _ds.getGrnsForSupplier(
        clientId: session.clientId, companyId: session.companyId, supplierId: _supplierId!,
      );
      final fullyReturned = await _ds.getFullyReturnedGrnKeys(
        clientId: session.clientId, companyId: session.companyId,
      );
      if (mounted) setState(() { _pendingGrns = rows; _fullyReturnedGrnKeys = fullyReturned; _loadingGrns = false; });
    } catch (e) {
      if (mounted) { setState(() => _loadingGrns = false); _showSnack('Could not load GRNs: $e', color: AppColors.negative); }
    }
  }

  List<Map<String, dynamic>> get _selectableGrns => _returnCurrencyId == null
      ? _pendingGrns
      : _pendingGrns.where((g) => g['grn_currency_id'] == _returnCurrencyId).toList();

  // ── GRN checkbox toggle ───────────────────────────────────────────────────

  Future<void> _toggleGrn(Map<String, dynamic> grn, bool checked) async {
    final session = ref.read(sessionProvider)!;
    final grnNo   = grn['grn_no'] as String;
    final grnDate = grn['grn_date'] as String;
    final isBilled = grn['billed_invoice_no'] != null;

    if (checked) {
      setState(() {
        _selectedGrnKeys.add(_grnKey(grn));
        if (_returnCurrencyId == null) {
          _returnCurrencyId   = grn['grn_currency_id'] as String?;
          final currency = grn['currency'] as Map<String, dynamic>?;
          _returnCurrencyCode = currency?['currency_id'] as String?;
        }
      });
      try {
        final grnLines   = await _ds.getGrnLines(clientId: session.clientId, companyId: session.companyId, grnNo: grnNo, grnDate: grnDate);
        final grnCharges = await _ds.getGrnCharges(clientId: session.clientId, companyId: session.companyId, grnNo: grnNo, grnDate: grnDate);
        if (!mounted) return;
        final newLines = <_ReturnLineRow>[];
        setState(() {
          for (final gl in grnLines) {
            final product = gl['product'] as Map<String, dynamic>?;
            final uom     = gl['uom'] as Map<String, dynamic>?;
            final row = _ReturnLineRow(
              sourceGrnNo: grnNo, sourceGrnDate: grnDate,
              sourceGrnLineSerial: gl['serial_no'] as int,
              productId: gl['product_id'] as String,
              productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
              uomId: gl['uom_id'] as String?,
              uomLabel: uom?['description'] as String?,
              uomConversionFactor: (gl['uom_conversion_factor'] as num? ?? 1).toDouble(),
              grnQty: (gl['base_qty'] as num? ?? 0).toDouble(),
              rate: (gl['rate'] as num? ?? 0).toDouble(),
              taxGroupId: gl['tax_group_id'] as String?,
              grnTaxAmount: (gl['tax_amount'] as num? ?? 0).toDouble(),
              isBilled: isBilled,
              hasSourcePo: gl['source_po_order_no'] != null,
              barcode: gl['barcode'] as String?,
              trackingType: product?['tracking_type'] as String? ?? 'NONE',
            );
            _lines.add(row);
            newLines.add(row);
          }
          for (final gc in grnCharges) {
            _charges.add(_ReturnChargeRow(
              sourceGrnNo: grnNo, sourceGrnDate: grnDate,
              chargeId: gc['charge_id'] as String,
              chargeName: gc['charge_name'] as String,
              isTaxable: gc['is_taxable'] as bool? ?? false,
              taxId: gc['tax_id'] as String?,
              nature: gc['nature'] as String? ?? 'ADD',
              glAccountId: gc['gl_account_id'] as String?,
              taxAmount: (gc['tax_amount'] as num? ?? 0).toDouble(),
              initialAmount: (gc['amount'] as num? ?? 0).toDouble(),
            ));
          }
        });
        _recomputeTotals();
        for (final row in newLines) {
          if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row));
        }
      } catch (e) {
        if (mounted) _showSnack('Could not load GRN lines: $e', color: AppColors.negative);
      }
    } else {
      setState(() {
        _selectedGrnKeys.remove(_grnKey(grn));
        _lines.removeWhere((l) { if (l.sourceGrnNo == grnNo && l.sourceGrnDate == grnDate) { l.dispose(); return true; } return false; });
        _charges.removeWhere((c) { if (c.sourceGrnNo == grnNo && c.sourceGrnDate == grnDate) { c.dispose(); return true; } return false; });
        if (_selectedGrnKeys.isEmpty) { _returnCurrencyId = null; _returnCurrencyCode = null; }
      });
      _recomputeTotals();
    }
  }

  void _removeLine(_ReturnLineRow row) {
    setState(() { _lines.remove(row); row.dispose(); });
    _recomputeTotals();
  }

  /// Fetches this line's batch/serial candidates (what the source GRN line
  /// originally received) plus each one's CURRENT balance/status — a UX
  /// hint only, so the user doesn't attempt an over-return that would just
  /// fail server-side (fn_post_stock_movement's strict check, migration 063).
  /// When row.existingLineSerialNo is set (reloading a saved return), also
  /// pre-fills each candidate with what was actually saved before.
  Future<void> _loadCandidates(_ReturnLineRow row) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final rows = await _ds.getGrnLineBatches(
          clientId: session.clientId, companyId: session.companyId,
          grnNo: row.sourceGrnNo, grnDate: row.sourceGrnDate, lineSerial: row.sourceGrnLineSerial,
        );
        Map<String, num> savedByBatch = const {};
        if (row.existingLineSerialNo != null) {
          final saved = await _ds.getReturnLineBatches(
            clientId: session.clientId, companyId: session.companyId,
            returnNo: _returnNo!, returnDate: _fmtDate(_returnDate), lineSerial: row.existingLineSerialNo!,
          );
          savedByBatch = {for (final s in saved) (s['batch_no'] as String): (s['base_qty'] as num? ?? 0)};
        }
        final candidates = <_ReturnBatchCandidate>[];
        for (final b in rows) {
          final c = _ReturnBatchCandidate(
            batchNo: b['batch_no'] as String,
            expiryDate: b['expiry_date'] as String?,
            manufacturingDate: b['manufacturing_date'] as String?,
            receivedQty: (b['base_qty'] as num? ?? 0).toDouble(),
          );
          c.availableBalance = await _ds.getBatchBalance(
            clientId: session.clientId, companyId: session.companyId,
            locationId: _locationId!, productId: row.productId, batchNo: c.batchNo,
          );
          final saved = savedByBatch[c.batchNo];
          if (saved != null) c.qtyCtrl.text = saved.toDouble().toStringAsFixed(2);
          candidates.add(c);
        }
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final rows = await _ds.getGrnLineSerials(
          clientId: session.clientId, companyId: session.companyId,
          grnNo: row.sourceGrnNo, grnDate: row.sourceGrnDate, lineSerial: row.sourceGrnLineSerial,
        );
        Set<String> savedSerials = const {};
        if (row.existingLineSerialNo != null) {
          final saved = await _ds.getReturnLineSerials(
            clientId: session.clientId, companyId: session.companyId,
            returnNo: _returnNo!, returnDate: _fmtDate(_returnDate), lineSerial: row.existingLineSerialNo!,
          );
          savedSerials = saved.map((s) => s['serial_no'] as String).toSet();
        }
        final candidates = <_ReturnSerialCandidate>[];
        for (final s in rows) {
          final serialNo = s['serial_no'] as String;
          final status = await _ds.getSerialStatus(
            clientId: session.clientId, companyId: session.companyId,
            locationId: _locationId!, productId: row.productId, serialNo: serialNo,
          );
          candidates.add(_ReturnSerialCandidate(serialNo: serialNo, status: status)..selected = savedSerials.contains(serialNo));
        }
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  /// Unlike GRN's own _batchSerialError (which allows leaving a line
  /// un-split at draft stage, since a GRN can still be edited later),
  /// Purchase Return REQUIRES a full batch/serial allocation whenever
  /// returnQty > 0 — a return's whole point is reversing a specific,
  /// identifiable lot/unit, and leaving it unallocated would silently fall
  /// through fn_approve_purchase_return's v_has_batches/v_has_serials check
  /// into the plain aggregate stock movement, which is exactly the weaker,
  /// flag-gated check the strict per-batch/serial rule (migration 063) was
  /// built to bypass.
  String? _batchSerialError(_ReturnLineRow row) {
    if (row.returnQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No batches found for "${row.productDisplay}" on GRN ${row.sourceGrnNo}.';
      if ((row.batchQtySum - row.returnQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} '
            'but the return quantity is ${row.returnQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialCandidates.isEmpty) return 'No serial numbers found for "${row.productDisplay}" on GRN ${row.sourceGrnNo}.';
      if (row.selectedSerialCount != row.returnQty.round() || (row.returnQty - row.returnQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the return quantity '
            '(${row.returnQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  /// A line's return qty can never exceed what that GRN line originally
  /// received — found live: the qty field had no upper bound at all.
  /// This is a basic client-side sanity check only; the authoritative check
  /// (cumulative across every other APPROVED return against the same GRN
  /// line, not just this one document) is fn_approve_purchase_return's own
  /// RETURN_QTY_EXCEEDS_RECEIVED, still enforced server-side at Approve.
  String? _qtyError(_ReturnLineRow row) {
    if (row.returnQty < 0) return 'Return qty for "${row.productDisplay}" cannot be negative.';
    if (row.returnQty > row.grnQty + 0.0001) {
      return 'Return qty for "${row.productDisplay}" (${row.returnQty.toStringAsFixed(2)}) '
          'cannot exceed what GRN ${row.sourceGrnNo} received (${row.grnQty.toStringAsFixed(2)}).';
    }
    return null;
  }

  /// Suggested taxable/tax totals — computed fresh from the GRN lines' own
  /// rate/tax data (never derived from a Bill's posted totals), so this
  /// works identically whether a GRN was billed alone or with others.
  /// Always overwrites the fields (same precedent as Purchase Bill's own
  /// _recomputeDefaults) — the user re-validates against the real debit
  /// note after every GRN/qty change.
  void _recomputeTotals() {
    final taxable = _lines.fold(0.0, (s, l) => s + l.grossAmount);
    final tax     = _lines.fold(0.0, (s, l) => s + l.suggestedTaxAmount);
    setState(() {
      _taxableAmountCtrl.text = taxable.toStringAsFixed(2);
      _taxAmountCtrl.text     = tax.toStringAsFixed(2);
    });
  }

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_supplierId == null) { _showSnack('Select a supplier.', color: AppColors.negative); return false; }
    if (_lines.where((l) => l.returnQty > 0).isEmpty) { _showSnack('Enter a return quantity for at least one line.', color: AppColors.negative); return false; }

    for (final l in _lines) {
      final qtyErr = _qtyError(l);
      if (qtyErr != null) { _showSnack(qtyErr, color: AppColors.negative); return false; }
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final returnableLines = _lines.where((l) => l.returnQty > 0).toList();
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (var i = 0; i < returnableLines.length; i++) {
        final l = returnableLines[i];
        final lineSerial = i + 1;
        if (l.isBatchTracked) {
          for (final b in l.batchCandidates.where((b) => b.allocatedQty > 0)) {
            batches.add({
              'line_serial': lineSerial,
              'batch_no':    b.batchNo,
              'expiry_date': b.expiryDate,
              'manufacturing_date': b.manufacturingDate,
              'qty_pack':    b.allocatedQty,
              'qty_loose':   0,
              'base_qty':    b.allocatedQty,
            });
          }
        } else if (l.isSerialTracked) {
          for (final s in l.serialCandidates.where((s) => s.selected)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
          }
        }
      }

      final header = {
        'client_id':           session.clientId,
        'company_id':          session.companyId,
        'location_id':         _locationId,
        'return_no':           _returnNo,
        'return_date':         _fmtDate(_returnDate),
        'supplier_id':         _supplierId,
        'return_currency_id':  _returnCurrencyId,
        'rate_to_base':        _rateToBase,
        'rate_to_local':       _rateToLocal,
        'taxable_amount':      _taxableAmount,
        'tax_amount':          _taxAmount,
        'return_total':        _taxableAmount + _taxAmount,
        'reason':              _reason ?? '',
        'remarks':             _remarksCtrl.text.trim(),
      };
      final lines = returnableLines.asMap().entries.map((e) => {
        'serial_no':              e.key + 1,
        'source_grn_no':          e.value.sourceGrnNo,
        'source_grn_date':        e.value.sourceGrnDate,
        'source_grn_line_serial': e.value.sourceGrnLineSerial,
        'product_id':             e.value.productId,
        'uom_id':                 e.value.uomId,
        'uom_conversion_factor':  e.value.uomConversionFactor,
        'qty_pack':               e.value.qtyPack,
        'qty_loose':              e.value.qtyLoose,
        'base_qty':               e.value.returnQty,
        'rate':                   e.value.rate,
        'tax_group_id':           e.value.taxGroupId,
        'gross_amount':           e.value.grossAmount,
        'tax_amount':             e.value.suggestedTaxAmount,
        'final_amount':           e.value.grossAmount + e.value.suggestedTaxAmount,
        'barcode':                e.value.barcode ?? '',
      }).toList();
      final charges = _charges.asMap().entries.map((e) => {
        'serial_no':       e.key + 1,
        'charge_id':       e.value.chargeId,
        'charge_name':     e.value.chargeName,
        'is_taxable':      e.value.isTaxable,
        'tax_id':          e.value.taxId,
        'nature':          e.value.nature,
        'gl_account_id':   e.value.glAccountId,
        'amount':          e.value.amount,
        'tax_amount':      e.value.taxAmount,
        'source_grn_no':   e.value.sourceGrnNo,
        'source_grn_date': e.value.sourceGrnDate,
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'PURCHASE_RETURN',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_purchase_return',
          payload:      {'p_header': header, 'p_lines': lines, 'p_batches': batches, 'p_serials': serials, 'p_charges': charges, 'p_user_id': session.userId},
        );
        await _ds.cacheReturnLocally(effectiveReturnNo: localId, header: header, lines: lines, batches: batches, serials: serials, charges: charges);
        if (mounted) {
          setState(() { _returnNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final returnNo = await _ds.save(header: header, lines: lines, batches: batches, serials: serials, charges: charges, userId: session.userId);
        unawaited(_ds.cacheReturnLocally(effectiveReturnNo: returnNo, header: header, lines: lines, batches: batches, serials: serials, charges: charges));
        if (mounted) {
          setState(() { _returnNo = returnNo; _saving = false; });
          _showSnack('Purchase Return $returnNo saved.', color: AppColors.positive);
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

  Future<void> _approveReturn() async {
    if (_returnNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Purchase Return'),
        content: const Text('Once approved, stock will be reduced and the Accrual/Supplier/VAT reversal will be posted '
            'to Finance. This return can no longer be edited. Continue?'),
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
    if (!mounted) return;

    var reopenPo = false;
    if (_lines.any((l) => l.hasSourcePo)) {
      final reopen = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Reopen Purchase Order?'),
          content: const Text('One or more returned lines came from a Purchase Order. Reopen it so it becomes eligible '
              'for further GRNs again? (Received quantity is adjusted either way — this only affects whether the PO\'s '
              'own status re-opens.)'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('No')),
            FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Yes, Reopen')),
          ],
        ),
      );
      reopenPo = reopen ?? false;
    }

    final session = ref.read(sessionProvider)!;
    setState(() { _approving = true; _actionError = null; });
    try {
      await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        returnNo: _returnNo!, returnDate: _fmtDate(_returnDate),
        reopenPo: reopenPo, approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Purchase Return $_returnNo approved.', color: AppColors.positive);
        await _init();
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      // Always reset, regardless of what happened above — previously this
      // only reset inside the catch blocks, so a successful approve()
      // followed by _init() failing internally (it swallows its own errors
      // into _error) left the button spinning forever with no way out,
      // since _status also never got refreshed off 'DRAFT' in that case.
      if (mounted) setState(() => _approving = false);
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    return e.message ?? e.toString();
  }

  // ── Print ─────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    return {
      'company': company,
      'header': {
        'return_no':    _returnNo ?? '',
        'return_date':  _displayDate(_returnDate),
        'status':       _status,
        'supplier_name': _supplierDisplay ?? '',
        'currency_code': _returnCurrencyCode ?? '',
        'reason':       _reason ?? '',
        'remarks':      _remarksCtrl.text,
      },
      'lines': _lines.where((l) => l.returnQty > 0).map((l) => {
        'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
        'source_grn_no': l.sourceGrnNo,
        'return_qty':   l.returnQty,
        'rate':         l.rate,
        'final_amount': l.grossAmount + l.suggestedTaxAmount,
      }).toList(),
      'totals': {
        'taxable_amount': _taxableAmount,
        'tax_amount':     _taxAmount,
        'return_total':   _taxableAmount + _taxAmount,
      },
    };
  }

  Future<void> _printReturn() async {
    if (_returnNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('PURCHASE_RETURN').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_returnNo.pdf');
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
      onPressed: _printing ? null : _printReturn,
    ),
  );

  // ── Helpers ───────────────────────────────────────────────────────────────

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
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2099));
    if (d != null) onPicked(d);
  }

  static Widget _req(String text) => RichText(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
      children: const [
        TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final showLooseQty = (session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';

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
                  if (_returnNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_returnNo != null) _buildPrintButton(),
                      if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_returnNo != null) _buildPrintButton(),
                  if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                ]),
        ),

        const Divider(height: 20),

        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null) ...[_errorBanner(_error!, onRetry: _init), const SizedBox(height: 16)],
                      if (_actionError != null) ...[_errorBanner(_actionError!), const SizedBox(height: 16)],
                      if (isOffline && _isNew) ...[_offlineNewReturnNotice(), const SizedBox(height: 16)],
                      _buildHeaderCard(locked, isMobile),
                      const SizedBox(height: 16),
                      _buildGrnPickerCard(locked),
                      const SizedBox(height: 16),
                      _buildLinesCard(locked, showLooseQty),
                      const SizedBox(height: 16),
                      _buildChargesCard(locked),
                      const SizedBox(height: 16),
                      _buildTotalsCard(locked),
                      if (_status == 'APPROVED' && _postedVouchers.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _buildPostedVouchersSection(),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// Starting a brand-new return needs a live supplier/GRN picker — this
  /// module doesn't cache those (unlike its own header/lines, which DO work
  /// offline once loaded). Shown only for a new, not-yet-saved return; an
  /// already-loaded draft can still be edited and saved offline normally.
  Widget _offlineNewReturnNotice() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: AppColors.secondary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
    ),
    child: const Row(children: [
      Icon(Icons.info_outline, color: AppColors.secondary, size: 18),
      SizedBox(width: 10),
      Expanded(child: Text(
          'Starting a new return needs a live connection to pick a supplier/GRN — an already-loaded draft can still be edited and saved offline.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
    ]),
  );

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_returnNo != null ? 'Purchase Return · $_returnNo' : 'New Purchase Return',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    Row(children: [
      _status == 'APPROVED'
          ? _statusChip(_status)
          : Text(_returnNo != null ? 'Draft' : 'Unsaved draft',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      if (_returnNo != null) ...[
        const SizedBox(width: 8),
        PendingSyncBadge(documentType: 'PURCHASE_RETURN', documentId: _returnNo!),
      ],
    ]),
  ]);

  Widget _statusChip(String status) {
    final color = status == 'APPROVED' ? AppColors.positive : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool canApprove}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : _saveDraft,
      child: _saving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Text('Save Draft'),
    ),
    if (canSave && canApprove) const SizedBox(width: 12),
    if (canApprove) FilledButton(
      onPressed: _approving ? null : _approveReturn,
      style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
      child: _approving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Text('Approve'),
    ),
  ]);

  Widget _errorBanner(String msg, {VoidCallback? onRetry}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: AppColors.negative.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(msg, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
      if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
    ]),
  );

  // ── Header card ───────────────────────────────────────────────────────────

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);
    final supplierLocked = locked || _selectedGrnKeys.isNotEmpty;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Builder(builder: (_) {
            final f1 = SizedBox(
              height: fh,
              child: Autocomplete<Map<String, dynamic>>(
                key: ValueKey(_supplierDisplay ?? ''),
                initialValue: TextEditingValue(text: _supplierDisplay ?? ''),
                displayStringForOption: (s) => '[${s['account_code']}] ${s['account_name']}',
                optionsBuilder: (v) {
                  if (supplierLocked) return const [];
                  final q = v.text.toLowerCase().trim();
                  return q.isEmpty ? _suppliers : _suppliers.where((s) =>
                      (s['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                      (s['account_name'] as String? ?? '').toLowerCase().contains(q));
                },
                onSelected: (s) => _onSupplierSelected(s),
                fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                  controller: textCtrl, focusNode: focusNode, enabled: !supplierLocked,
                  decoration: dec.copyWith(label: _req('Supplier'),
                      helperText: supplierLocked && !locked ? 'Locked once a GRN is picked' : null,
                      helperStyle: const TextStyle(fontSize: 10)),
                  style: const TextStyle(fontSize: 13),
                ),
                optionsViewBuilder: (context, onSel, opts) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(4),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260, minWidth: 260),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: opts.length,
                        itemBuilder: (context, idx) {
                          final s = opts.elementAt(idx);
                          return InkWell(
                            onTap: () => onSel(s),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Text('[${s['account_code']}] ${s['account_name']}', style: const TextStyle(fontSize: 13)),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            final f2 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Return No'),
              child: Text(_returnNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _returnNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f3 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_returnDate, (d) => setState(() => _returnDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(label: _req('Return Date'),
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                        color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_returnDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    Row(children: [Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]),
                  ])
                : Row(children: [
                    Expanded(flex: 3, child: f1), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f3),
                  ]);
          }),
          const SizedBox(height: 12),

          Builder(builder: (_) {
            final currAsync = ref.watch(currenciesProvider);
            return currAsync.when(
              data: (currencies) {
                final selectedCurrency = currencies.where((c) => c['id'] == _returnCurrencyId).firstOrNull;
                final f1 = field(InputDecorator(
                  decoration: dec.copyWith(labelText: 'Currency',
                      helperText: 'Inherited from the selected GRN(s)', helperStyle: const TextStyle(fontSize: 10)),
                  child: Text(
                    selectedCurrency != null ? '${selectedCurrency['currency_id']} — ${selectedCurrency['currency_name']}' : '—',
                    style: const TextStyle(fontSize: 13)),
                ));
                final reasonOptions = <String>{
                  ..._reasons,
                  if (_reason != null && _reason!.isNotEmpty) _reason!,
                }.toList();
                final f2 = field(DropdownButtonFormField<String>(
                  decoration: dec.copyWith(labelText: 'Reason'),
                  isExpanded: true,
                  isDense: true,
                  itemHeight: null,
                  initialValue: (_reason != null && _reason!.isNotEmpty) ? _reason : null,
                  items: reasonOptions.map((r) => DropdownMenuItem(
                      value: r, child: Text(r, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: locked ? null : (v) => setState(() => _reason = v),
                ));
                return isMobile
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                        SizedBox(width: double.infinity, child: f2),
                      ])
                    : Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(flex: 2, child: f2)]);
              },
              loading: () => const SizedBox(height: fh, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => Text('Could not load currencies: $e'),
            );
          }),
        ]),
      ),
    );
  }

  // ── GRN picker card ───────────────────────────────────────────────────────

  Widget _buildGrnPickerCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Approved GRNs', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          if (_supplierId == null)
            const Text('Select a supplier to see their approved GRNs (billed or not).',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else if (_loadingGrns)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_selectableGrns.isEmpty)
            const Text('No approved GRNs for this supplier.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else
            ..._selectableGrns.map((g) {
              final key = _grnKey(g);
              final currency = g['currency'] as Map<String, dynamic>?;
              final isBilled = g['billed_invoice_no'] != null;
              final isSelected = _selectedGrnKeys.contains(key);
              // Fully returned GRNs have nothing left to give — disabled
              // going forward, but a GRN already picked onto THIS document
              // (e.g. re-opening a draft that already fully returned it)
              // stays interactive so the user can still remove it.
              final isFullyReturned = _fullyReturnedGrnKeys.contains(key) && !isSelected;
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: isSelected,
                onChanged: (locked || isFullyReturned) ? null : (v) => _toggleGrn(g, v ?? false),
                title: Row(children: [
                  Text(g['grn_no'] as String, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                      color: isFullyReturned ? AppColors.textDisabled : null)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (isBilled ? AppColors.positive : AppColors.secondary).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(isBilled ? 'Billed' : 'Not Billed',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                            color: isBilled ? AppColors.positive : AppColors.secondary)),
                  ),
                  if (isFullyReturned) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.negative.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Fully Returned',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.negative)),
                    ),
                  ],
                ]),
                subtitle: Text(
                    '${g['grn_date']} · ${currency?['currency_id'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              );
            }),
        ]),
      ),
    );
  }

  // ── Lines card ────────────────────────────────────────────────────────────

  Widget _buildLinesCard(bool locked, bool showLooseQty) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Return Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('GRN quantity is pre-filled as the return quantity — reduce, zero, or remove a line you don\'t want to return.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_lines.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet — pick a GRN above.',
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
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Expanded(
                      flex: 3,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(row.productDisplay, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('GRN ${row.sourceGrnNo} · Received ${row.grnQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}',
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        Text(
                          row.suggestedTaxAmount > 0
                              ? 'Taxable ${row.grossAmount.toStringAsFixed(2)} · VAT ${row.suggestedTaxAmount.toStringAsFixed(2)} '
                                  '· Total ${(row.grossAmount + row.suggestedTaxAmount).toStringAsFixed(2)}'
                              : (row.isBilled ? 'No VAT on this line' : 'Not yet billed — VAT deferred'),
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(width: 100, child: TextFormField(
                      controller: row.qtyPackCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: showLooseQty ? 'Return Qty Pack' : 'Return Qty', suffixText: row.uomLabel),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => _recomputeTotals(),
                    )),
                    if (showLooseQty) ...[
                      const SizedBox(width: 8),
                      SizedBox(width: 100, child: TextFormField(
                        controller: row.qtyLooseCtrl, enabled: !locked,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: dec.copyWith(labelText: 'Return Qty Loose', suffixText: row.uomLabel),
                        style: const TextStyle(fontSize: 12),
                        onChanged: (_) => _recomputeTotals(),
                      )),
                    ],
                    const SizedBox(width: 8),
                    SizedBox(width: 90, child: Text('Rate: ${row.rate.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                    const SizedBox(width: 8),
                    SizedBox(width: 90, child: Text('= ${(row.grossAmount + row.suggestedTaxAmount).toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                    if (!locked) IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                      onPressed: () => _removeLine(row),
                    ),
                  ]),
                  if (row.isBatchTracked || row.isSerialTracked) _buildBatchSerialEditor(row, locked),
                ]),
              ),
            )),
        ]),
      ),
    );
  }

  // ── Batch / Serial picker (per return line) ──────────────────────────────
  // Unlike GRN's free-text batch/serial entry (a GRN is CREATING new
  // batches/serials), this is a PICKER against what the source GRN line
  // already received — the user allocates the return qty across known
  // lots/units, never invents a new batch/serial number here.

  Widget _buildBatchSerialEditor(_ReturnLineRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    final isBatch = row.isBatchTracked;

    if (!row.candidatesLoaded) {
      return const Padding(
        padding: EdgeInsets.only(top: 10),
        child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(isBatch ? 'Select Batches to Return' : 'Select Serial Numbers to Return',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch
              ? '${row.batchQtySum.toStringAsFixed(2)} / ${row.returnQty.toStringAsFixed(2)}'
              : '${row.selectedSerialCount} / ${row.returnQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: (isBatch ? (row.batchQtySum - row.returnQty).abs() < 0.0001
                                  : row.selectedSerialCount == row.returnQty.round())
                      ? AppColors.positive : AppColors.negative)),
        ]),
        const SizedBox(height: 8),
        if (isBatch && row.batchCandidates.isEmpty)
          const Text('No batches found on the source GRN line.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (!isBatch && row.serialCandidates.isEmpty)
          const Text('No serial numbers found on the source GRN line.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (isBatch)
          ...row.batchCandidates.map((b) => Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 130, child: Text(b.batchNo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
              SizedBox(width: 130, child: Text(
                  'Available: ${b.availableBalance.toStringAsFixed(2)}${b.expiryDate != null ? ' · Exp ${b.expiryDate}' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
              SizedBox(width: 100, child: TextFormField(
                controller: b.qtyCtrl, enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Return Qty', suffixText: row.uomLabel),
                style: const TextStyle(fontSize: 12),
                onChanged: (_) => setState(() {}),
              )),
            ]),
          ))
        else
          ...row.serialCandidates.map((s) => Padding(
            padding: const EdgeInsets.only(top: 2),
            child: CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: s.selected,
              onChanged: (locked || s.status != 'IN_STOCK') ? null : (v) => setState(() => s.selected = v ?? false),
              title: Text(s.serialNo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              subtitle: s.status != 'IN_STOCK'
                  ? const Text('Not currently in stock — already sold, transferred, or returned', style: TextStyle(fontSize: 10, color: AppColors.negative))
                  : null,
            ),
          )),
      ]),
    );
  }

  // ── Charges card ──────────────────────────────────────────────────────────

  Widget _buildChargesCard(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    if (_charges.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Additional Charges', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Pulled from the selected GRN(s) as a default — edit if this return doesn\'t carry the full charge.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          ..._charges.map((row) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(flex: 3, child: Text('${row.chargeName} (${row.sourceGrnNo})', style: const TextStyle(fontSize: 13))),
              SizedBox(width: 120, child: TextFormField(
                controller: row.amountCtrl, enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Amount'),
                style: const TextStyle(fontSize: 12),
              )),
            ]),
          )),
        ]),
      ),
    );
  }

  // ── Totals card ───────────────────────────────────────────────────────────

  Widget _buildTotalsCard(bool locked) {
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Amounts', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Auto-filled from the return lines — validate against the supplier\'s debit note and edit only if it differs.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(width: 220, child: field(TextFormField(
              controller: _taxableAmountCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'Taxable Amount'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ))),
            SizedBox(width: 220, child: field(TextFormField(
              controller: _taxAmountCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'VAT / Tax Amount (billed portion only)'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ))),
            SizedBox(width: 220, child: field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Return Total'),
              child: Text('${_returnCurrencyCode ?? ''} ${(_taxableAmount + _taxAmount).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ))),
          ]),
          const SizedBox(height: 12),
          TextFormField(controller: _remarksCtrl, enabled: !locked, maxLines: 2,
              decoration: dec.copyWith(labelText: 'Remarks'), style: const TextStyle(fontSize: 13)),
        ]),
      ),
    );
  }

  // ── Posted Journal Entries — up to two vouchers (JV + SDN) ───────────────

  Widget _buildPostedVouchersSection() {
    Widget colHeader(String label, {TextAlign align = TextAlign.left}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(label, textAlign: align,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
    );
    Widget cell(String text, {TextAlign align = TextAlign.left, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(text, textAlign: align,
          style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Posted Journal Entries',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
                    decoration: BoxDecoration(
                      color: (v['voucher_type_code'] == 'SDN' ? AppColors.secondary : AppColors.primary).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(v['voucher_type_code'] == 'SDN' ? 'Supplier Debit Note' : 'Journal Voucher',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                            color: v['voucher_type_code'] == 'SDN' ? AppColors.secondary : AppColors.primary)),
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
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.06),
                        border: const Border(top: BorderSide(color: AppColors.border)),
                      ),
                      child: Row(children: [
                        const Expanded(flex: 6, child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        )),
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

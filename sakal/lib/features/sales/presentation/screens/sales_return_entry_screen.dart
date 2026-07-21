import 'dart:async';

import 'package:collection/collection.dart';
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
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../domain/repositories/sales_return_repository.dart';
import '../providers/sales_return_providers.dart';

/// One batch this invoice line actually sold — the candidate list for a
/// batch-tracked return line. availableBalance is a UX hint only; the real
/// block is fn_post_stock_movement's strict per-batch check at Approve.
class _SRBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final double soldQty;
  num availableBalance = 0;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');

  _SRBatchCandidate({required this.batchNo, this.expiryDate, required this.soldQty});

  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

class _SRSerialCandidate {
  final String serialNo;
  bool selected = false;
  _SRSerialCandidate({required this.serialNo});
}

class _SRLineRow {
  final int invoiceLineSerial;
  final String productId;
  final String productDisplay;
  final String? uomId;
  final String? uomLabel;
  final double uomConversionFactor;
  final double invoicedQty;
  final double alreadyReturned;
  final double rate;
  final String? taxGroupId;
  final double invoiceGrossAmount;
  final double invoiceTaxAmount;
  final double invoiceFinalAmount;
  final String? barcode;
  final String trackingType;
  final int? existingLineSerialNo;
  final TextEditingController qtyPackCtrl;
  final TextEditingController qtyLooseCtrl;
  List<_SRBatchCandidate>  batchCandidates  = [];
  List<_SRSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  _SRLineRow({
    required this.invoiceLineSerial,
    required this.productId,
    required this.productDisplay,
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    required this.invoicedQty,
    required this.alreadyReturned,
    required this.rate,
    this.taxGroupId,
    required this.invoiceGrossAmount,
    required this.invoiceTaxAmount,
    required this.invoiceFinalAmount,
    this.barcode,
    this.trackingType = 'NONE',
    this.existingLineSerialNo,
    double? initialQtyPack,
    double initialQtyLoose = 0,
  }) : qtyPackCtrl = TextEditingController(text: (initialQtyPack ?? (invoicedQty - alreadyReturned)).toStringAsFixed(2)),
       qtyLooseCtrl = TextEditingController(text: initialQtyLoose.toStringAsFixed(2));

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get returnQty => qtyPack * uomConversionFactor + qtyLoose;
  double get remainingReturnable => invoicedQty - alreadyReturned;
  // Proportional share of the invoice line's own already-fixed amounts —
  // never re-priced, this document only ever reverses at the invoice's own
  // rate/tax.
  double get fraction => invoicedQty > 0 ? returnQty / invoicedQty : 0;
  double get grossAmount => invoiceGrossAmount * fraction;
  double get taxAmount   => invoiceTaxAmount * fraction;
  double get finalAmount => invoiceFinalAmount * fraction;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class _SRChargeRow {
  final int? invoiceChargeSerial;
  final String chargeId;
  final String chargeName;
  final bool   isTaxable;
  final String? taxId;
  final String nature;
  final String? glAccountId;
  // The invoice's own ORIGINAL charge amount/tax — never changes; .amount/
  // .taxAmount below are re-derived from these times this return's own
  // value ratio every time a line qty changes (_recomputeChargesAndRefund).
  final double originalAmount;
  final double originalTaxAmount;
  double amount;
  double taxAmount;

  _SRChargeRow({
    this.invoiceChargeSerial,
    required this.chargeId,
    required this.chargeName,
    required this.isTaxable,
    this.taxId,
    required this.nature,
    this.glAccountId,
    required this.originalAmount,
    required this.originalTaxAmount,
    double? amount,
    double? taxAmount,
  }) : amount = amount ?? originalAmount,
       taxAmount = taxAmount ?? originalTaxAmount;
}

class SalesReturnEntryScreen extends ConsumerStatefulWidget {
  final String? editReturnNo;
  final String? editReturnDate;
  const SalesReturnEntryScreen({super.key, this.editReturnNo, this.editReturnDate});

  @override
  ConsumerState<SalesReturnEntryScreen> createState() => _SalesReturnEntryScreenState();
}

class _SalesReturnEntryScreenState extends ConsumerState<SalesReturnEntryScreen>
    with ScreenPermissionMixin<SalesReturnEntryScreen> {
  // Entry screen is not itself a menu item — Menu -> List -> Entry pattern.
  @override String get screenName => RouteNames.salesReturns;

  SalesReturnRepository get _ds => ref.read(salesReturnRepositoryProvider);

  String?  _returnNo;
  DateTime _returnDate = DateTime.now();
  String   _status     = 'DRAFT';

  String?  _invoiceNo;
  String?  _invoiceDate;
  String?  _customerDisplay;
  String?  _returnCurrencyCode;
  String   _saleType = 'CREDIT';
  String   _stockDispatchMode = 'DEFERRED';
  String   _cashCollectionMode = 'DEFERRED';
  double   _collectedAmountLocal = 0;
  double   _collectedAmountBase  = 0;

  String? _reason;
  final _remarksCtrl = TextEditingController();
  final _refundLocalCtrl = TextEditingController(text: '0');
  final _refundBaseCtrl  = TextEditingController(text: '0');
  double get _refundLocal => double.tryParse(_refundLocalCtrl.text) ?? 0;
  double get _refundBase  => double.tryParse(_refundBaseCtrl.text) ?? 0;

  List<Map<String, dynamic>> _invoiceOptions = [];
  final List<_SRLineRow> _lines = [];
  final List<_SRChargeRow> _charges = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving    = false;
  bool    _approving = false;
  bool    _loadingInvoiceLines = false;
  bool    _printing  = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  bool _loadingVoucherLines = false;

  bool get _isNew => _returnNo == null;
  bool get _showRefundFields => _saleType == 'CASH' && _cashCollectionMode == 'IMMEDIATE';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    _refundLocalCtrl.dispose();
    _refundBaseCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      if (widget.editReturnNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          returnNo: widget.editReturnNo!, returnDate: widget.editReturnDate,
        );
        if (header != null) {
          _returnNo    = header['return_no'] as String;
          _returnDate  = DateTime.parse(header['return_date'] as String);
          _status      = header['status'] as String;
          _invoiceNo   = header['invoice_no'] as String;
          _invoiceDate = header['invoice_date'] as String;
          final customer = header['customer'] as Map<String, dynamic>?;
          _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
          _reason      = header['reason'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';
          _refundLocalCtrl.text = (header['refund_amount_local'] as num? ?? 0).toString();
          _refundBaseCtrl.text  = (header['refund_amount_base']  as num? ?? 0).toString();

          await _loadInvoiceContext();
          await _loadExistingLines(session);
        }
      }
      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadInvoiceContext() async {
    final session = ref.read(sessionProvider)!;
    final invoices = await _ds.getApprovedInvoices(
      clientId: session.clientId, companyId: session.companyId, search: _invoiceNo,
    );
    final match = invoices.where((i) => i['invoice_no'] == _invoiceNo && i['invoice_date'] == _invoiceDate).firstOrNull;
    if (match != null) {
      _saleType            = match['sale_type'] as String? ?? 'CREDIT';
      _stockDispatchMode    = match['stock_dispatch_mode'] as String? ?? 'DEFERRED';
      _cashCollectionMode   = match['cash_collection_mode'] as String? ?? 'DEFERRED';
      _collectedAmountLocal = (match['collected_amount_local'] as num? ?? 0).toDouble();
      _collectedAmountBase  = (match['collected_amount_base']  as num? ?? 0).toDouble();
    }
  }

  Future<void> _loadExistingLines(UserSession session) async {
    final savedLines = await _ds.getLines(
      clientId: session.clientId, companyId: session.companyId,
      returnNo: _returnNo!, returnDate: _fmtDate(_returnDate),
    );
    final invoiceLines = await _ds.getInvoiceLines(
      clientId: session.clientId, companyId: session.companyId,
      invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
    );
    final alreadyReturned = await _fetchAlreadyReturned(session);

    final newLines = <_SRLineRow>[];
    for (final sl in savedLines) {
      final il = invoiceLines.firstWhere(
        (l) => l['serial_no'] == sl['invoice_line_serial'],
        orElse: () => const {},
      );
      final product = il['product'] as Map<String, dynamic>?;
      final uom = sl['uom'] as Map<String, dynamic>?;
      final row = _SRLineRow(
        invoiceLineSerial: sl['invoice_line_serial'] as int,
        productId: sl['product_id'] as String,
        productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
        uomId: sl['uom_id'] as String?,
        uomLabel: uom?['description'] as String?,
        uomConversionFactor: (sl['uom_conversion_factor'] as num? ?? 1).toDouble(),
        invoicedQty: (il['base_qty'] as num? ?? 0).toDouble(),
        alreadyReturned: alreadyReturned[sl['invoice_line_serial'] as int] ?? 0,
        rate: (sl['rate'] as num? ?? 0).toDouble(),
        taxGroupId: sl['tax_group_id'] as String?,
        invoiceGrossAmount: (il['gross_amount'] as num? ?? 0).toDouble(),
        invoiceTaxAmount: (il['tax_amount'] as num? ?? 0).toDouble(),
        invoiceFinalAmount: (il['final_amount'] as num? ?? 0).toDouble(),
        barcode: sl['barcode'] as String?,
        trackingType: product?['tracking_type'] as String? ?? 'NONE',
        existingLineSerialNo: sl['serial_no'] as int,
        initialQtyPack: (sl['qty_pack'] as num? ?? sl['base_qty'] as num? ?? 0).toDouble(),
        initialQtyLoose: (sl['qty_loose'] as num? ?? 0).toDouble(),
      );
      _lines.add(row);
      newLines.add(row);
    }

    final savedCharges = await _ds.getCharges(
      clientId: session.clientId, companyId: session.companyId,
      returnNo: _returnNo!, returnDate: _fmtDate(_returnDate),
    );
    final invoiceCharges = await _ds.getInvoiceCharges(
      clientId: session.clientId, companyId: session.companyId,
      invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
    );
    for (final sc in savedCharges) {
      final ic = invoiceCharges.firstWhere(
        (c) => c['serial_no'] == sc['invoice_charge_serial'],
        orElse: () => sc,
      );
      _charges.add(_SRChargeRow(
        invoiceChargeSerial: sc['invoice_charge_serial'] as int?,
        chargeId: sc['charge_id'] as String,
        chargeName: sc['charge_name'] as String,
        isTaxable: sc['is_taxable'] as bool? ?? false,
        taxId: sc['tax_id'] as String?,
        nature: sc['nature'] as String? ?? 'ADD',
        glAccountId: sc['gl_account_id'] as String?,
        originalAmount: (ic['amount'] as num? ?? 0).toDouble(),
        originalTaxAmount: (ic['tax_amount'] as num? ?? 0).toDouble(),
        amount: (sc['amount'] as num? ?? 0).toDouble(),
        taxAmount: (sc['tax_amount'] as num? ?? 0).toDouble(),
      ));
    }

    for (final row in newLines) {
      if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row));
    }
  }

  Future<Map<int, double>> _fetchAlreadyReturned(UserSession session) async {
    final rows = await _ds.getAlreadyReturnedByLine(
      clientId: session.clientId, companyId: session.companyId,
      invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
    );
    final map = <int, double>{};
    for (final r in rows) {
      // Exclude this same return's own prior save from the "already
      // returned" sum — fn_approve only sums OTHER approved returns, but
      // this client-side fetch has no status filter beyond APPROVED so a
      // reopened DRAFT never contributes here regardless.
      final serial = r['invoice_line_serial'] as int;
      map[serial] = (map[serial] ?? 0) + (r['base_qty'] as num? ?? 0).toDouble();
    }
    return map;
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
          _voucherLines..clear()..addAll(lines);
          _loadingVoucherLines = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingVoucherLines = false);
    }
  }

  // ── Invoice selection ─────────────────────────────────────────────────────

  Future<void> _searchInvoices(String query) async {
    final session = ref.read(sessionProvider)!;
    try {
      final rows = await _ds.getApprovedInvoices(
        clientId: session.clientId, companyId: session.companyId, search: query,
      );
      if (mounted) setState(() => _invoiceOptions = rows);
    } catch (_) { /* picker is best-effort */ }
  }

  Future<void> _onInvoiceSelected(Map<String, dynamic> invoice) async {
    final session = ref.read(sessionProvider)!;
    setState(() {
      _invoiceNo   = invoice['invoice_no'] as String;
      _invoiceDate = invoice['invoice_date'] as String;
      final customer = invoice['customer'] as Map<String, dynamic>?;
      _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
      _saleType            = invoice['sale_type'] as String? ?? 'CREDIT';
      _stockDispatchMode    = invoice['stock_dispatch_mode'] as String? ?? 'DEFERRED';
      _cashCollectionMode   = invoice['cash_collection_mode'] as String? ?? 'DEFERRED';
      _collectedAmountLocal = (invoice['collected_amount_local'] as num? ?? 0).toDouble();
      _collectedAmountBase  = (invoice['collected_amount_base']  as num? ?? 0).toDouble();
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
      _charges.clear();
      _loadingInvoiceLines = true;
    });
    try {
      final invoiceLines = await _ds.getInvoiceLines(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
      );
      final invoiceCharges = await _ds.getInvoiceCharges(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
      );
      final alreadyReturned = await _fetchAlreadyReturned(session);
      if (!mounted) return;
      final newLines = <_SRLineRow>[];
      setState(() {
        for (final il in invoiceLines) {
          final remaining = (il['base_qty'] as num? ?? 0).toDouble() - (alreadyReturned[il['serial_no'] as int] ?? 0);
          if (remaining <= 0) continue; // fully returned already — nothing left to offer
          final product = il['product'] as Map<String, dynamic>?;
          final uom = il['uom'] as Map<String, dynamic>?;
          final row = _SRLineRow(
            invoiceLineSerial: il['serial_no'] as int,
            productId: il['product_id'] as String,
            productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
            uomId: il['uom_id'] as String?,
            uomLabel: uom?['description'] as String?,
            uomConversionFactor: (il['uom_conversion_factor'] as num? ?? 1).toDouble(),
            invoicedQty: (il['base_qty'] as num? ?? 0).toDouble(),
            alreadyReturned: alreadyReturned[il['serial_no'] as int] ?? 0,
            rate: (il['rate'] as num? ?? 0).toDouble(),
            taxGroupId: il['tax_group_id'] as String?,
            invoiceGrossAmount: (il['gross_amount'] as num? ?? 0).toDouble(),
            invoiceTaxAmount: (il['tax_amount'] as num? ?? 0).toDouble(),
            invoiceFinalAmount: (il['final_amount'] as num? ?? 0).toDouble(),
            barcode: il['barcode'] as String?,
            trackingType: product?['tracking_type'] as String? ?? 'NONE',
          );
          _lines.add(row);
          newLines.add(row);
        }
        for (final ic in invoiceCharges) {
          _charges.add(_SRChargeRow(
            invoiceChargeSerial: ic['serial_no'] as int,
            chargeId: ic['charge_id'] as String,
            chargeName: ic['charge_name'] as String,
            isTaxable: ic['is_taxable'] as bool? ?? false,
            taxId: ic['tax_id'] as String?,
            nature: ic['nature'] as String? ?? 'ADD',
            glAccountId: ic['gl_account_id'] as String?,
            originalAmount: (ic['amount'] as num? ?? 0).toDouble(),
            originalTaxAmount: (ic['tax_amount'] as num? ?? 0).toDouble(),
          ));
        }
        _loadingInvoiceLines = false;
      });
      _recomputeChargesAndRefund();
      for (final row in newLines) {
        if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row));
      }
    } catch (e) {
      if (mounted) { setState(() => _loadingInvoiceLines = false); _showSnack('Could not load invoice lines: $e', color: AppColors.negative); }
    }
  }

  void _removeLine(_SRLineRow row) {
    setState(() { _lines.remove(row); row.dispose(); });
    _recomputeChargesAndRefund();
  }

  /// Candidates = exactly what this invoice line sold, minus whatever a
  /// prior APPROVED Sales Return against this same invoice line already
  /// consumed. A UX hint only — the authoritative, strict check is
  /// fn_post_stock_movement's own per-batch/serial balance rule at Approve.
  Future<void> _loadCandidates(_SRLineRow row) async {
    final session = ref.read(sessionProvider)!;
    try {
      final priorKeys = await _ds.getPriorReturnLineKeys(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
      );
      final priorForThisLine = priorKeys.where((k) => k['invoice_line_serial'] == row.invoiceLineSerial).toList();
      final priorReturnNos = priorForThisLine.map((k) => k['return_no'] as String).toSet().toList();

      if (row.isBatchTracked) {
        final sold = await _ds.getInvoiceLineBatches(
          clientId: session.clientId, companyId: session.companyId,
          invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!, lineSerial: row.invoiceLineSerial,
        );
        final consumed = await _ds.getAlreadyReturnedBatches(
          clientId: session.clientId, companyId: session.companyId, returnNos: priorReturnNos,
        );
        final consumedByBatch = <String, double>{};
        for (final c in consumed) {
          final matchesThisLine = priorForThisLine.any((k) => k['return_no'] == c['source_doc_no'] && k['serial_no'] == c['line_serial']);
          if (!matchesThisLine) continue;
          final b = c['batch_no'] as String;
          consumedByBatch[b] = (consumedByBatch[b] ?? 0) + (c['base_qty'] as num? ?? 0).toDouble();
        }
        Map<String, num> savedByBatch = const {};
        if (row.existingLineSerialNo != null) {
          // If reopening THIS return's own draft, its own already-saved
          // batch allocation should pre-fill (not be double-subtracted as
          // "consumed" — but a DRAFT return is never in priorReturnNos
          // since that list is APPROVED-only, so no double-count risk).
        }
        final candidates = <_SRBatchCandidate>[];
        for (final b in sold) {
          final batchNo = b['batch_no'] as String;
          final soldQty = (b['base_qty'] as num? ?? 0).toDouble();
          final remaining = soldQty - (consumedByBatch[batchNo] ?? 0);
          if (remaining <= 0) continue;
          final c = _SRBatchCandidate(batchNo: batchNo, expiryDate: b['expiry_date'] as String?, soldQty: soldQty);
          c.availableBalance = remaining;
          final saved = savedByBatch[batchNo];
          if (saved != null) c.qtyCtrl.text = saved.toDouble().toStringAsFixed(2);
          candidates.add(c);
        }
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final sold = await _ds.getInvoiceLineSerials(
          clientId: session.clientId, companyId: session.companyId,
          invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!, lineSerial: row.invoiceLineSerial,
        );
        final consumed = await _ds.getAlreadyReturnedSerials(
          clientId: session.clientId, companyId: session.companyId, returnNos: priorReturnNos,
        );
        final consumedSerials = <String>{};
        for (final c in consumed) {
          final matchesThisLine = priorForThisLine.any((k) => k['return_no'] == c['source_doc_no'] && k['serial_no'] == c['line_serial']);
          if (matchesThisLine) consumedSerials.add(c['serial_no'] as String);
        }
        final candidates = sold
            .map((s) => s['serial_no'] as String)
            .where((s) => !consumedSerials.contains(s))
            .map((s) => _SRSerialCandidate(serialNo: s))
            .toList();
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  /// Mandatory whenever return qty > 0 on a tracked line — same strictness
  /// as Purchase Return, since a batch/serial is a specific identifiable
  /// lot/unit, not a fungible quantity.
  String? _batchSerialError(_SRLineRow row) {
    if (row.returnQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No returnable batches found for "${row.productDisplay}".';
      if ((row.batchQtySum - row.returnQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} '
            'but the return quantity is ${row.returnQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialCandidates.isEmpty) return 'No returnable serial numbers found for "${row.productDisplay}".';
      if (row.selectedSerialCount != row.returnQty.round() || (row.returnQty - row.returnQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the return quantity '
            '(${row.returnQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  String? _qtyError(_SRLineRow row) {
    if (row.returnQty < 0) return 'Return qty for "${row.productDisplay}" cannot be negative.';
    if (row.returnQty > row.remainingReturnable + 0.0001) {
      return 'Return qty for "${row.productDisplay}" (${row.returnQty.toStringAsFixed(2)}) '
          'cannot exceed what remains returnable (${row.remainingReturnable.toStringAsFixed(2)}).';
    }
    return null;
  }

  /// Charges + refund defaults recompute whenever lines change — charges
  /// fan out from the invoice's own charge amounts proportional to this
  /// return's own value vs. the invoice's total line value (header-level
  /// ratio, since a charge applies to the whole document, not one line).
  /// Refund defaults to the same proportion of what was actually collected.
  void _recomputeChargesAndRefund() {
    final invoiceTotalFinal = _lines.fold(0.0, (s, l) => s + l.invoiceFinalAmount);
    final returnedFinal     = _lines.fold(0.0, (s, l) => s + l.finalAmount);
    final ratio = invoiceTotalFinal > 0 ? returnedFinal / invoiceTotalFinal : 0.0;

    setState(() {
      // Charges live at document level, not per-line — re-derive each
      // charge's amount/tax fresh from its own ORIGINAL invoice amount
      // times this return's own value ratio.
      for (final c in _charges) {
        c.amount    = c.originalAmount * ratio;
        c.taxAmount = c.originalTaxAmount * ratio;
      }
      _refundLocalCtrl.text = (_collectedAmountLocal * ratio).toStringAsFixed(2);
      _refundBaseCtrl.text  = (_collectedAmountBase * ratio).toStringAsFixed(2);
    });
  }

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_invoiceNo == null) { _showSnack('Select an invoice to return against.', color: AppColors.negative); return false; }
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
              'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate,
              'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty,
            });
          }
        } else if (l.isSerialTracked) {
          for (final s in l.serialCandidates.where((s) => s.selected)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
          }
        }
      }

      final taxableTotal = returnableLines.fold(0.0, (s, l) => s + l.grossAmount);
      final taxTotal     = returnableLines.fold(0.0, (s, l) => s + l.taxAmount);
      final chargesTotal = _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));

      final header = {
        'client_id':            session.clientId,
        'company_id':           session.companyId,
        'return_no':            _returnNo,
        'return_date':          _fmtDate(_returnDate),
        'invoice_no':           _invoiceNo,
        'invoice_date':         _invoiceDate,
        'taxable_amount':       taxableTotal,
        'tax_amount':           taxTotal,
        'charges_amount':       chargesTotal,
        'return_total':         taxableTotal + taxTotal + chargesTotal,
        'refund_amount_local':  _showRefundFields ? _refundLocal : 0,
        'refund_amount_base':   _showRefundFields ? _refundBase  : 0,
        'reason':               _reason ?? '',
        'remarks':              _remarksCtrl.text.trim(),
      };
      final lines = returnableLines.asMap().entries.map((e) => {
        'serial_no':            e.key + 1,
        'invoice_line_serial':  e.value.invoiceLineSerial,
        'product_id':           e.value.productId,
        'barcode':              e.value.barcode ?? '',
        'uom_id':                e.value.uomId,
        'uom_conversion_factor': e.value.uomConversionFactor,
        'qty_pack':              e.value.qtyPack,
        'qty_loose':             e.value.qtyLoose,
        'base_qty':              e.value.returnQty,
        'rate':                  e.value.rate,
        'tax_group_id':          e.value.taxGroupId,
        'gross_amount':          e.value.grossAmount,
        'tax_amount':            e.value.taxAmount,
        'final_amount':          e.value.finalAmount,
      }).toList();
      final charges = _charges.asMap().entries.map((e) => {
        'serial_no':             e.key + 1,
        'invoice_charge_serial': e.value.invoiceChargeSerial,
        'charge_id':             e.value.chargeId,
        'charge_name':           e.value.chargeName,
        'is_taxable':            e.value.isTaxable,
        'tax_id':                e.value.taxId,
        'nature':                e.value.nature,
        'gl_account_id':         e.value.glAccountId,
        'amount':                e.value.amount,
        'tax_amount':            e.value.taxAmount,
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'SALES_RETURN',
          documentId: localId,
          endpoint: '/rpc/fn_save_sales_return',
          payload: {'p_header': header, 'p_lines': lines, 'p_batches': batches, 'p_serials': serials, 'p_charges': charges, 'p_user_id': session.userId},
        );
        await _ds.cacheReturnLocally(effectiveReturnNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() { _returnNo = localId; _saving = false; });
          _showSnack('Saved offline as $localId — will sync when online, then wait for Pending Approvals to post.', color: AppColors.secondary);
        }
        return true;
      }

      final returnNo = await _ds.save(header: header, lines: lines, batches: batches, serials: serials, charges: charges, userId: session.userId);
      if (mounted) {
        setState(() { _returnNo = returnNo; _saving = false; });
        _showSnack('Sales Return $returnNo saved.', color: AppColors.positive);
      }
      return true;
    } on DioException catch (e) {
      setState(() { _saving = false; _actionError = _serverError(e); });
      return false;
    } catch (e) {
      setState(() { _saving = false; _actionError = 'Unexpected error: $e'; });
      return false;
    }
  }

  Future<void> _approveReturn() async {
    final session = ref.read(sessionProvider)!;
    // Approve is always online-only — it posts real stock/GL under a live
    // row-lock only the central database can serialize across devices, and
    // needs a fresh "how much of this invoice line has already been
    // returned" read. If offline, the most this action can do is Save
    // (queued); the actual approval is deferred to whoever reviews the
    // Pending Approvals screen once this device reconnects.
    if (session.offlineMode) {
      if (_returnNo == null) {
        final saved = await _saveDraft();
        if (saved && mounted) {
          _showSnack('Saved offline — approval requires an online connection. Use Pending Approvals once this syncs.', color: AppColors.secondary);
        }
      } else {
        _showSnack('Approval requires an online connection.', color: AppColors.negative);
      }
      return;
    }
    if (_returnNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Sales Return'),
        content: Text('Once approved, the Customer/Sales/Tax reversal will be posted to Finance'
            '${_stockDispatchMode == 'IMMEDIATE' ? ', stock will be received back' : ''}'
            '${_showRefundFields && (_refundLocal > 0 || _refundBase > 0) ? ', and a cash refund will be paid out' : ''}. '
            'This return can no longer be edited. Continue?'),
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

    setState(() { _approving = true; _actionError = null; });
    try {
      await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        returnNo: _returnNo!, returnDate: _fmtDate(_returnDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Return $_returnNo approved.', color: AppColors.positive);
        await _init();
      }
    } on DioException catch (e) {
      setState(() { _actionError = _serverError(e); });
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

  // ── Print ─────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    return {
      'company': company,
      'header': {
        'return_no':     _returnNo ?? '',
        'return_date':   _displayDate(_returnDate),
        'status':        _status,
        'invoice_no':    _invoiceNo ?? '',
        'customer_name': _customerDisplay ?? '',
        'currency_code': _returnCurrencyCode ?? '',
        'reason':        _reason ?? '',
        'remarks':       _remarksCtrl.text,
        'signatures': {'prepared_by': null, 'authorised_by': null},
      },
      'lines': _lines.where((l) => l.returnQty > 0).map((l) => {
        'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
        'return_qty':   l.returnQty,
        'rate':         l.rate,
        'final_amount': l.finalAmount,
      }).toList(),
      'totals': {
        'taxable_amount': _lines.fold(0.0, (s, l) => s + l.grossAmount),
        'tax_amount':     _lines.fold(0.0, (s, l) => s + l.taxAmount),
        'return_total':   _lines.fold(0.0, (s, l) => s + l.finalAmount),
      },
    };
  }

  Future<void> _printReturn() async {
    if (_returnNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('SALES_RETURN').future);
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final showLooseQty = (ref.watch(sessionProvider)?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';

    final canSave     = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final showApprove = _status == 'DRAFT' && canApprove && !_isNew;
    final locked      = _status != 'DRAFT';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                      _buildHeaderCard(locked, isMobile),
                      const SizedBox(height: 16),
                      _buildLinesCard(locked, showLooseQty, isMobile),
                      const SizedBox(height: 16),
                      if (_charges.isNotEmpty) ...[_buildChargesCard(isMobile), const SizedBox(height: 16)],
                      _buildTotalsCard(locked, isMobile),
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

  Widget _buildTitleBlock() => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_returnNo != null ? 'Sales Return · $_returnNo' : 'New Sales Return',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        _status == 'APPROVED'
            ? _statusChip(_status)
            : Text(_returnNo != null ? 'Draft' : 'Unsaved draft',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ]),
    ],
  );

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
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final invoiceLocked = locked || _lines.isNotEmpty || !_isNew;

    final invoiceField = SakalFieldCard(
      label: 'Invoice', required: true, editable: !invoiceLocked,
      child: SakalAutocomplete<Map<String, dynamic>>(
        key: ValueKey(_invoiceNo ?? ''),
        initialValue: TextEditingValue(text: _invoiceNo != null ? '$_invoiceNo — ${_customerDisplay ?? ''}' : ''),
        displayStringForOption: (i) {
          final c = i['customer'] as Map<String, dynamic>?;
          return '${i['invoice_no']} — ${c != null ? '[${c['account_code']}] ${c['account_name']}' : ''}';
        },
        optionsBuilder: (v) {
          if (invoiceLocked) return const [];
          unawaited(_searchInvoices(v.text));
          return _invoiceOptions;
        },
        onSelected: (i) => _onInvoiceSelected(i),
        enabled: !invoiceLocked,
        decoration: bare,
        style: style,
      ),
    );
    final returnNoField = SakalFieldCard.readOnly(label: 'Return No', value: _returnNo ?? '(auto on save)');
    final returnDateField = SakalFieldCard(
      label: 'Return Date', required: true, editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(_returnDate, (d) => setState(() => _returnDate = d)),
        child: Row(children: [
          Expanded(child: Text(_displayDate(_returnDate), style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final customerField = SakalFieldCard.readOnly(label: 'Customer', value: _customerDisplay ?? '—');
    final saleTypeField = SakalFieldCard.readOnly(label: 'Sale Type', value: _saleType == 'CASH' ? 'Cash' : 'Credit');
    final reasonField = SakalFieldCard(
      label: 'Reason', editable: !locked,
      child: TextFormField(
        initialValue: _reason,
        enabled: !locked, decoration: bare, style: style,
        onChanged: (v) => _reason = v,
      ),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SakalFieldRow(isMobile: isMobile, children: [invoiceField, returnNoField, returnDateField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [customerField, saleTypeField, reasonField]),
        ]),
      ),
    );
  }

  // ── Lines card ────────────────────────────────────────────────────────────

  Widget _buildLinesCard(bool locked, bool showLooseQty, bool isMobile) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Return Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Remaining-returnable quantity is pre-filled — reduce, zero, or remove a line you don\'t want to return.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_loadingInvoiceLines)
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_lines.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet — pick an invoice above.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._lines.map((row) => _buildLineCard(row, locked, showLooseQty, isMobile)),
        ]),
      ),
    );
  }

  Widget _buildLineCard(_SRLineRow row, bool locked, bool showLooseQty, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';

    final unitField = SakalFieldCard.readOnly(label: 'Unit', value: row.uomLabel ?? '—');
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Return Qty Pack' : 'Return Qty', editable: !locked,
      child: TextFormField(
        controller: row.qtyPackCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: bare, style: style,
        onChanged: (_) => setState(_recomputeChargesAndRefund),
      ),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Return Qty Loose', editable: !locked,
      child: TextFormField(
        controller: row.qtyLooseCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: bare, style: style,
        onChanged: (_) => setState(_recomputeChargesAndRefund),
      ),
    );
    final rateField = SakalFieldCard.readOnly(label: 'Rate', value: AppNumberFormat.amount(row.rate, numberFormat), numeric: true);
    final amountField = SakalFieldCard.readOnly(
      label: 'Amount', value: AppNumberFormat.amount(row.finalAmount, numberFormat), numeric: true);

    return SakalLineItemCard(
      title: row.productDisplay.isEmpty ? 'Line' : row.productDisplay,
      subtitle: 'Invoiced ${row.invoicedQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}'
          '${row.alreadyReturned > 0 ? ' · Already returned ${row.alreadyReturned.toStringAsFixed(2)}' : ''}'
          ' · Remaining ${row.remainingReturnable.toStringAsFixed(2)}',
      onDelete: locked ? null : () => _removeLine(row),
      fields: [
        SizedBox(width: 70, height: 56, child: unitField),
        SizedBox(width: 110, child: qtyPackField),
        if (showLooseQty) SizedBox(width: 110, child: qtyLooseField),
        SizedBox(width: 100, height: 56, child: rateField),
        SizedBox(width: 110, height: 56, child: amountField),
      ],
      body: row.isBatchTracked || row.isSerialTracked
          ? _buildBatchSerialEditor(row, locked, isMobile)
          : const SizedBox.shrink(),
    );
  }

  // ── Batch / Serial picker (per return line) ──────────────────────────────

  Widget _buildBatchSerialEditor(_SRLineRow row, bool locked, bool isMobile) {
    final isBatch = row.isBatchTracked;
    final fieldTextStyle = SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider));

    if (!row.candidatesLoaded) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator());
    }

    Widget batchFields() {
      final fields = row.batchCandidates.map((b) => SakalFieldCard(
            label: '${b.batchNo} (avail ${b.availableBalance})${b.expiryDate != null ? ' · exp ${b.expiryDate}' : ''}',
            editable: !locked,
            child: TextFormField(
              controller: b.qtyCtrl, enabled: !locked, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: SakalFieldCard.bareDecoration,
              style: fieldTextStyle,
              onChanged: (_) => setState(() {}),
            ),
          )).toList();
      if (isMobile || fields.length <= 4) {
        return SakalFieldRow(isMobile: isMobile, children: fields);
      }
      return Wrap(spacing: 10, runSpacing: 10, children: fields.map((f) => SizedBox(width: 220, child: f)).toList());
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
          const Text('No returnable batches found for this line.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (!isBatch && row.serialCandidates.isEmpty)
          const Text('No returnable serial numbers found for this line.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (isBatch)
          batchFields()
        else
          Wrap(spacing: 8, runSpacing: 8, children: row.serialCandidates.map((s) => FilterChip(
                label: Text(s.serialNo, style: const TextStyle(fontSize: 12)),
                selected: s.selected,
                onSelected: locked ? null : (v) => setState(() => s.selected = v),
              )).toList()),
      ]),
    );
  }

  // ── Charges card (read-only, carried forward from the invoice) ──────────

  Widget _buildChargesCard(bool isMobile) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Additional Charges', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Carried forward from the invoice, proportional to this return\'s value — read-only.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          ..._charges.map((row) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SakalFieldRow(isMobile: isMobile, spans: const [8, 4], children: [
              SakalFieldCard.readOnly(label: 'Charge', value: row.chargeName),
              SakalFieldCard.readOnly(label: 'Amount', value: row.amount.toStringAsFixed(2), numeric: true),
            ]),
          )),
        ]),
      ),
    );
  }

  // ── Totals card ───────────────────────────────────────────────────────────

  Widget _buildTotalsCard(bool locked, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';

    final taxable = _lines.fold(0.0, (s, l) => s + l.grossAmount);
    final tax     = _lines.fold(0.0, (s, l) => s + l.taxAmount);
    final charges = _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));

    final taxableField = SakalFieldCard.readOnly(label: 'Taxable Amount', value: AppNumberFormat.amount(taxable, numberFormat), numeric: true);
    final taxField     = SakalFieldCard.readOnly(label: 'Tax Amount', value: AppNumberFormat.amount(tax, numberFormat), numeric: true);
    final totalField   = SakalFieldCard.readOnly(
      label: 'Return Total', value: '${_returnCurrencyCode ?? ''} ${AppNumberFormat.amount(taxable + tax + charges, numberFormat)}');
    final remarksField = SakalFieldCard(
      label: 'Remarks', editable: !locked, height: 72,
      child: TextFormField(controller: _remarksCtrl, enabled: !locked, maxLines: 2, decoration: bare, style: style),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Amounts', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [taxableField, taxField, totalField]),
          const SizedBox(height: 12),
          remarksField,
          if (_showRefundFields) ...[
            const SizedBox(height: 16),
            const Text('Cash Refund', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            Text('This invoice was paid in cash and collected — a refund will be posted at Approve, capped at what remains collected '
                '(local ${_collectedAmountLocal.toStringAsFixed(2)}, base ${_collectedAmountBase.toStringAsFixed(2)}).',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            SakalFieldRow(isMobile: isMobile, children: [
              SakalFieldCard(
                label: 'Refund Amount (Local)', editable: !locked,
                child: TextFormField(
                  controller: _refundLocalCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: bare, style: style,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SakalFieldCard(
                label: 'Refund Amount (Base)', editable: !locked,
                child: TextFormField(
                  controller: _refundBaseCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: bare, style: style,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  // ── Posted Journal Entries — up to three vouchers (CRN + COS + CPV) ─────

  Widget _buildPostedVouchersSection() {
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
            final lines = _voucherLines[transNo] ?? const [];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    child: Text(transNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primary)),
                  ),
                  Row(children: [
                    Expanded(flex: 4, child: cell('Ledger Name', bold: true)),
                    Expanded(flex: 2, child: cell('Debit', align: TextAlign.right, bold: true)),
                    Expanded(flex: 2, child: cell('Credit', align: TextAlign.right, bold: true)),
                  ]),
                  for (final l in lines) Builder(builder: (_) {
                    final account = l['account'] as Map<String, dynamic>?;
                    final isDr = l['trans_nature'] == 'DR';
                    final amount = (l['trans_amount'] as num? ?? 0).toDouble();
                    return Row(children: [
                      Expanded(flex: 4, child: cell(account != null ? '[${account['account_code']}] ${account['account_name']}' : '—')),
                      Expanded(flex: 2, child: cell(isDr ? amount.toStringAsFixed(2) : '', align: TextAlign.right)),
                      Expanded(flex: 2, child: cell(!isDr ? amount.toStringAsFixed(2) : '', align: TextAlign.right)),
                    ]);
                  }),
                ]),
              ),
            );
          }),
      ],
    );
  }
}

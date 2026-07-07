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
import '../../domain/repositories/stock_receipt_repository.dart';
import '../providers/stock_receipt_providers.dart';

/// A batch the source transfer actually dispatched — the candidate list for
/// a batch-tracked receipt line. Unlike Material Issue (draws from whatever
/// is currently on hand), these specific units are in transit, not yet in
/// any location's own stock, so the only valid candidates are exactly what
/// was sent (fn_approve_stock_receipt's own model, see migration 074).
class _ReceiptBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final num dispatchedQty;
  final TextEditingController qtyCtrl;
  _ReceiptBatchCandidate({required this.batchNo, this.expiryDate, required this.dispatchedQty})
      : qtyCtrl = TextEditingController(text: dispatchedQty.toStringAsFixed(2));
  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

class _ReceiptSerialCandidate {
  final String serialNo;
  bool selected;
  _ReceiptSerialCandidate({required this.serialNo, this.selected = true});
}

class _ReceiptLineRow {
  final int    sourceTransferLineSerial;
  final String productId;
  final String productDisplay;
  final String? uomId;
  final String? uomLabel;
  final double uomConversionFactor;
  final double dispatchedQty; // ceiling — the transfer line's own base_qty
  final String trackingType;
  final TextEditingController qtyPackCtrl;
  final TextEditingController qtyLooseCtrl;
  final TextEditingController remarksCtrl = TextEditingController();
  List<_ReceiptBatchCandidate>  batchCandidates  = [];
  List<_ReceiptSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  _ReceiptLineRow({
    required this.sourceTransferLineSerial,
    required this.productId,
    required this.productDisplay,
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    required this.dispatchedQty,
    this.trackingType = 'NONE',
    double initialQtyPack = 0,
    double initialQtyLoose = 0,
  }) : qtyPackCtrl = TextEditingController(text: initialQtyPack.toStringAsFixed(2)),
       qtyLooseCtrl = TextEditingController(text: initialQtyLoose.toStringAsFixed(2));

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get receivedQty  => qtyPack * uomConversionFactor + qtyLoose;
  double get shortfallQty => dispatchedQty - receivedQty;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    remarksCtrl.dispose();
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class StockReceiptEntryScreen extends ConsumerStatefulWidget {
  final String? editReceiptNo;
  final String? editReceiptDate;
  const StockReceiptEntryScreen({super.key, this.editReceiptNo, this.editReceiptDate});

  @override
  ConsumerState<StockReceiptEntryScreen> createState() => _StockReceiptEntryScreenState();
}

class _StockReceiptEntryScreenState extends ConsumerState<StockReceiptEntryScreen>
    with ScreenPermissionMixin<StockReceiptEntryScreen> {
  @override String get screenName => RouteNames.stockReceipts;

  StockReceiptRepository get _ds => ref.read(stockReceiptRepositoryProvider);

  String?  _receiptNo;
  DateTime _receiptDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _sourceTransferNo;
  String?  _sourceTransferDate;
  String?  _fromLocationName;
  String?  _toLocationName;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _receivableTransfers = [];
  bool _loadingTransfers = false;
  final List<_ReceiptLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  bool _loadingVoucherLines = false;

  bool get _isNew => _receiptNo == null;
  bool get _transferLocked => _sourceTransferNo != null;

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
      if (widget.editReceiptNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          receiptNo: widget.editReceiptNo!, receiptDate: widget.editReceiptDate,
        );
        if (header != null) {
          _receiptNo          = header['receipt_no'] as String;
          _receiptDate         = DateTime.parse(header['receipt_date'] as String);
          _status               = header['status'] as String;
          _sourceTransferNo      = header['source_transfer_no'] as String?;
          _sourceTransferDate     = header['source_transfer_date'] as String?;
          final from = header['from_location'] as Map<String, dynamic>?;
          final to   = header['to_location'] as Map<String, dynamic>?;
          _fromLocationName = from?['location_name'] as String?;
          _toLocationName   = to?['location_name'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';

          // Fetch the transfer's own lines first — they're the source of
          // truth for each line's dispatched-qty ceiling.
          final transferLines = await _ds.getTransferLines(
            clientId: session.clientId, companyId: session.companyId,
            transferNo: _sourceTransferNo!, transferDate: _sourceTransferDate!,
          );
          final dispatchedQtyBySerial = { for (final tl in transferLines) tl['serial_no'] as int: (tl['base_qty'] as num? ?? 0).toDouble() };

          final savedLines = await _ds.getLines(
            clientId: session.clientId, companyId: session.companyId,
            receiptNo: _receiptNo!, receiptDate: _fmtDate(_receiptDate),
          );
          final newRows = <_ReceiptLineRow>[];
          for (final sl in savedLines) {
            final product = sl['product'] as Map<String, dynamic>?;
            final uom     = sl['uom'] as Map<String, dynamic>?;
            final sourceSerial = sl['source_transfer_line_serial'] as int;
            final row = _ReceiptLineRow(
              sourceTransferLineSerial: sourceSerial,
              productId: sl['product_id'] as String,
              productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
              uomId: sl['uom_id'] as String?,
              uomLabel: uom?['description'] as String?,
              uomConversionFactor: (sl['uom_conversion_factor'] as num? ?? 1).toDouble(),
              dispatchedQty: dispatchedQtyBySerial[sourceSerial] ?? 0,
              trackingType: product?['tracking_type'] as String? ?? 'NONE',
              initialQtyPack: (sl['received_qty_pack'] as num? ?? 0).toDouble(),
              initialQtyLoose: (sl['received_qty_loose'] as num? ?? 0).toDouble(),
            );
            row.remarksCtrl.text = sl['remarks'] as String? ?? '';
            _lines.add(row);
            newRows.add(row);
          }

          for (final row in newRows) {
            if (row.isBatchTracked || row.isSerialTracked) {
              unawaited(_loadExistingCandidates(row, newRows.indexOf(row) + 1));
            }
          }
        }
      } else {
        unawaited(_loadReceivableTransfers());
      }

      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadReceivableTransfers() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingTransfers = true);
    try {
      final rows = await _ds.getReceivableTransfers(clientId: session.clientId, companyId: session.companyId);
      if (mounted) setState(() { _receivableTransfers = rows; _loadingTransfers = false; });
    } catch (e) {
      if (mounted) { setState(() => _loadingTransfers = false); _showSnack('Could not load receivable transfers: $e', color: AppColors.negative); }
    }
  }

  Future<void> _selectTransfer(Map<String, dynamic> transfer) async {
    final session = ref.read(sessionProvider)!;
    final transferNo   = transfer['transfer_no'] as String;
    final transferDate = transfer['transfer_date'] as String;
    try {
      final transferLines = await _ds.getTransferLines(
        clientId: session.clientId, companyId: session.companyId, transferNo: transferNo, transferDate: transferDate,
      );
      if (!mounted) return;
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
      final newRows = <_ReceiptLineRow>[];
      final from = transfer['from_location'] as Map<String, dynamic>?;
      final to   = transfer['to_location'] as Map<String, dynamic>?;
      setState(() {
        _sourceTransferNo   = transferNo;
        _sourceTransferDate = transferDate;
        _fromLocationName   = from?['location_name'] as String?;
        _toLocationName     = to?['location_name'] as String?;
        for (final tl in transferLines) {
          final product = tl['product'] as Map<String, dynamic>?;
          final uom     = tl['uom'] as Map<String, dynamic>?;
          final row = _ReceiptLineRow(
            sourceTransferLineSerial: tl['serial_no'] as int,
            productId: tl['product_id'] as String,
            productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
            uomId: tl['uom_id'] as String?,
            uomLabel: uom?['description'] as String?,
            uomConversionFactor: (tl['uom_conversion_factor'] as num? ?? 1).toDouble(),
            dispatchedQty: (tl['base_qty'] as num? ?? 0).toDouble(),
            trackingType: product?['tracking_type'] as String? ?? 'NONE',
            // Default to fully received — user reduces to record a shortfall.
            initialQtyPack: (tl['base_qty'] as num? ?? 0).toDouble(),
          );
          _lines.add(row);
          newRows.add(row);
        }
      });
      for (final row in newRows) {
        if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidatesForNewLine(row));
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load transfer lines: $e', color: AppColors.negative);
    }
  }

  Future<void> _loadCandidatesForNewLine(_ReceiptLineRow row) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final rows = await _ds.getDispatchedBatches(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: _sourceTransferNo!, transferDate: _sourceTransferDate!, lineSerial: row.sourceTransferLineSerial,
        );
        final candidates = rows.map((b) => _ReceiptBatchCandidate(
          batchNo: b['batch_no'] as String, expiryDate: b['expiry_date'] as String?, dispatchedQty: b['base_qty'] as num? ?? 0,
        )).toList();
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final rows = await _ds.getDispatchedSerials(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: _sourceTransferNo!, transferDate: _sourceTransferDate!, lineSerial: row.sourceTransferLineSerial,
        );
        final candidates = rows.map((s) => _ReceiptSerialCandidate(serialNo: s['serial_no'] as String)).toList();
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  Future<void> _loadExistingCandidates(_ReceiptLineRow row, int lineSerial) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final dispatched = await _ds.getDispatchedBatches(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: _sourceTransferNo!, transferDate: _sourceTransferDate!, lineSerial: row.sourceTransferLineSerial,
        );
        final saved = await _ds.getReceiptLineBatches(
          clientId: session.clientId, companyId: session.companyId,
          receiptNo: _receiptNo!, receiptDate: _fmtDate(_receiptDate), lineSerial: lineSerial,
        );
        final savedMap = { for (final s in saved) s['batch_no'] as String: s['base_qty'] as num? ?? 0 };
        final candidates = dispatched.map((b) {
          final batchNo = b['batch_no'] as String;
          final c = _ReceiptBatchCandidate(batchNo: batchNo, expiryDate: b['expiry_date'] as String?, dispatchedQty: b['base_qty'] as num? ?? 0);
          if (savedMap.containsKey(batchNo)) c.qtyCtrl.text = savedMap[batchNo].toString();
          return c;
        }).toList();
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final dispatched = await _ds.getDispatchedSerials(
          clientId: session.clientId, companyId: session.companyId,
          transferNo: _sourceTransferNo!, transferDate: _sourceTransferDate!, lineSerial: row.sourceTransferLineSerial,
        );
        final saved = await _ds.getReceiptLineSerials(
          clientId: session.clientId, companyId: session.companyId,
          receiptNo: _receiptNo!, receiptDate: _fmtDate(_receiptDate), lineSerial: lineSerial,
        );
        final savedSet = saved.map((s) => s['serial_no'] as String).toSet();
        final candidates = dispatched.map((s) => _ReceiptSerialCandidate(serialNo: s['serial_no'] as String, selected: savedSet.contains(s['serial_no']))).toList();
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingVoucherLines = true);
    try {
      final vouchers = await _ds.getPostedVouchers(clientId: session.clientId, companyId: session.companyId, receiptNo: _receiptNo!);
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

  /// Mandatory allocation whenever receivedQty > 0 — same reasoning as
  /// Material Issue/Purchase Return: leaving it unallocated would silently
  /// fall through into the plain aggregate movement, bypassing the strict
  /// per-batch/serial check.
  String? _batchSerialError(_ReceiptLineRow row) {
    if (row.receivedQty <= 0) return null;
    if (row.isBatchTracked) {
      if ((row.batchQtySum - row.receivedQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} but the received quantity is ${row.receivedQty.toStringAsFixed(2)}.';
      }
      for (final b in row.batchCandidates) {
        if (b.allocatedQty > b.dispatchedQty + 0.0001) {
          return 'Batch ${b.batchNo} for "${row.productDisplay}": received qty cannot exceed the dispatched qty (${b.dispatchedQty}).';
        }
      }
    } else if (row.isSerialTracked) {
      if (row.selectedSerialCount != row.receivedQty.round() || (row.receivedQty - row.receivedQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the received quantity (${row.receivedQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  String? _qtyError(_ReceiptLineRow row) {
    if (row.receivedQty < 0) return 'Received qty for "${row.productDisplay}" cannot be negative.';
    if (row.receivedQty > row.dispatchedQty + 0.0001) {
      return 'Received qty for "${row.productDisplay}" (${row.receivedQty.toStringAsFixed(2)}) cannot exceed the dispatched qty (${row.dispatchedQty.toStringAsFixed(2)}).';
    }
    return null;
  }

  Future<bool> _saveDraft() async {
    if (_sourceTransferNo == null) { _showSnack('Select a Stock Transfer to receive.', color: AppColors.negative); return false; }
    if (_lines.isEmpty) { _showSnack('The selected transfer has no lines.', color: AppColors.negative); return false; }
    for (final l in _lines) {
      final qtyErr = _qtyError(l);
      if (qtyErr != null) { _showSnack(qtyErr, color: AppColors.negative); return false; }
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (var i = 0; i < _lines.length; i++) {
        final l = _lines[i];
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

      final receiptNo = await _ds.save(
        header: {
          'client_id':            session.clientId,
          'company_id':           session.companyId,
          'receipt_no':           _receiptNo,
          'receipt_date':         _fmtDate(_receiptDate),
          'source_transfer_no':   _sourceTransferNo,
          'source_transfer_date': _sourceTransferDate,
          'remarks':              _remarksCtrl.text.trim(),
        },
        lines: _lines.asMap().entries.map((e) => {
          'serial_no':                     e.key + 1,
          'source_transfer_line_serial':    e.value.sourceTransferLineSerial,
          'product_id':                      e.value.productId,
          'uom_id':                            e.value.uomId,
          'uom_conversion_factor':              e.value.uomConversionFactor,
          'received_qty_pack':                   e.value.qtyPack,
          'received_qty_loose':                   e.value.qtyLoose,
          'received_base_qty':                      e.value.receivedQty,
          'remarks':                                 e.value.remarksCtrl.text.trim(),
        }).toList(),
        batches: batches,
        serials: serials,
        userId: session.userId,
      );
      if (mounted) {
        setState(() { _receiptNo = receiptNo; _saving = false; });
        _showSnack('Stock Receipt $receiptNo saved.', color: AppColors.positive);
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

  Future<void> _approveReceipt() async {
    if (_receiptNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (_receiptDate.isAfter(DateTime.now())) {
      _showSnack('Receipt date cannot be in the future.', color: AppColors.negative);
      return;
    }

    final hasShortfall = _lines.any((l) => l.shortfallQty > 0.0001);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Stock Receipt'),
        content: Text(hasShortfall
            ? 'Once approved, stock will be added to the To Location and the transfer will close. The shortfall on one or more lines will be written off to the Stock Transfer Loss account immediately and finally. This receipt can no longer be edited. Continue?'
            : 'Once approved, stock will be added to the To Location and the transfer will close. This receipt can no longer be edited. Continue?'),
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
        receiptNo: _receiptNo!, receiptDate: _fmtDate(_receiptDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Stock Receipt $_receiptNo approved.', color: AppColors.positive);
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
                    if (!_transferLocked) ...[
                      _buildTransferPickerCard(locked),
                      const SizedBox(height: 16),
                    ],
                    if (_lines.isNotEmpty) _buildLinesCard(locked),
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
    Text(_receiptNo != null ? 'Stock Receipt · $_receiptNo' : 'New Stock Receipt',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    _status == 'APPROVED' ? _statusChip(_status) : Text(_receiptNo != null ? 'Draft' : 'Unsaved draft',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
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
      onPressed: _approving ? null : _approveReceipt,
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

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Builder(builder: (_) {
            final f1 = field(InputDecorator(decoration: dec.copyWith(labelText: 'Source Transfer'),
                child: Text(_sourceTransferNo ?? '(select below)', style: TextStyle(fontSize: 13, color: _sourceTransferNo != null ? AppColors.textPrimary : AppColors.textDisabled))));
            final f2 = field(InputDecorator(decoration: dec.copyWith(labelText: 'From Location'),
                child: Text(_fromLocationName ?? '—', style: const TextStyle(fontSize: 13))));
            final f3 = field(InputDecorator(decoration: dec.copyWith(labelText: 'To Location'),
                child: Text(_toLocationName ?? '—', style: const TextStyle(fontSize: 13))));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f3),
                  ])
                : Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]);
          }),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(InputDecorator(decoration: dec.copyWith(labelText: 'Receipt No'),
                child: Text(_receiptNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _receiptNo != null ? AppColors.textPrimary : AppColors.textDisabled))));
            final f2 = field(InkWell(onTap: locked ? null : () => _pickDate(_receiptDate, (d) => setState(() => _receiptDate = d)),
                child: InputDecorator(decoration: dec.copyWith(labelText: 'Receipt Date *',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                    child: Text(_displayDate(_receiptDate), style: const TextStyle(fontSize: 13)))));
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

  Widget _buildTransferPickerCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Approved Stock Transfers Awaiting Receipt', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Pick the transfer this receipt confirms — one receipt per transfer.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_loadingTransfers)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_receivableTransfers.isEmpty)
            const Text('No approved transfers awaiting receipt.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else
            RadioGroup<String>(
              groupValue: _sourceTransferNo,
              onChanged: (v) {
                if (locked) return;
                final t = _receivableTransfers.where((x) => x['transfer_no'] == v).firstOrNull;
                if (t != null) _selectTransfer(t);
              },
              child: Column(children: _receivableTransfers.map((t) {
                final from = t['from_location'] as Map<String, dynamic>?;
                final to   = t['to_location'] as Map<String, dynamic>?;
                return RadioListTile<String>(
                  dense: true, contentPadding: EdgeInsets.zero,
                  value: t['transfer_no'] as String,
                  title: Text(t['transfer_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  subtitle: Text('${t['transfer_date']} · ${from?['location_name'] ?? '—'} → ${to?['location_name'] ?? '—'}',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                );
              }).toList()),
            ),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Receipt Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Dispatched quantity is pre-filled as fully received — reduce a line to record a shortfall.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          ..._lines.map((row) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: 0,
            color: AppColors.background,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(row.productDisplay, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('Dispatched ${row.dispatchedQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    if (row.shortfallQty > 0.0001) Text('Shortfall ${row.shortfallQty.toStringAsFixed(2)} — will be written off',
                        style: const TextStyle(fontSize: 11, color: AppColors.negative, fontWeight: FontWeight.w600)),
                  ])),
                  const SizedBox(width: 8),
                  SizedBox(width: 100, child: TextFormField(
                    controller: row.qtyPackCtrl, enabled: !locked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Received Qty'),
                    style: const TextStyle(fontSize: 12),
                    onChanged: (_) => setState(() {}),
                  )),
                ]),
                if (row.isBatchTracked || row.isSerialTracked) _buildBatchSerialEditor(row, locked),
              ]),
            ),
          )),
        ]),
      ),
    );
  }

  Widget _buildBatchSerialEditor(_ReceiptLineRow row, bool locked) {
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
          Text(isBatch ? 'Confirm Batches Received' : 'Confirm Serial Numbers Received',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch ? '${row.batchQtySum.toStringAsFixed(2)} / ${row.receivedQty.toStringAsFixed(2)}' : '${row.selectedSerialCount} / ${row.receivedQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: (isBatch ? (row.batchQtySum - row.receivedQty).abs() < 0.0001 : row.selectedSerialCount == row.receivedQty.round()) ? AppColors.positive : AppColors.negative)),
        ]),
        const SizedBox(height: 8),
        if (isBatch)
          ...row.batchCandidates.map((b) => Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 130, child: Text(b.batchNo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
              SizedBox(width: 150, child: Text('Dispatched: ${b.dispatchedQty.toStringAsFixed(2)}${b.expiryDate != null ? ' · Exp ${b.expiryDate}' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
              SizedBox(width: 90, child: TextFormField(
                controller: b.qtyCtrl, enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Received'),
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

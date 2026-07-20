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
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../../../core/widgets/sakal_table_header_bar.dart';
import '../../domain/repositories/material_issue_repository.dart';
import '../providers/material_issue_providers.dart';

/// A batch currently in stock for this product/location — the candidate
/// list for a batch-tracked issue line. Unlike Purchase Return (which
/// returns to a SPECIFIC receiving line), Material Issue draws from
/// whatever is currently on hand, so candidates come from the live balance
/// view, not any one originating document.
class _IssueBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final String? manufacturingDate;
  num availableBalance;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');

  _IssueBatchCandidate({required this.batchNo, this.expiryDate, this.manufacturingDate, required this.availableBalance});

  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

class _IssueSerialCandidate {
  final String serialNo;
  bool selected = false;
  _IssueSerialCandidate({required this.serialNo});
}

class _IssueLineRow {
  final String sourceRequisitionNo;
  final String sourceRequisitionDate;
  final int    sourceRequisitionLineSerial;
  final String productId;
  final String productDisplay;
  final String? uomId;
  final String? uomLabel;
  final double uomConversionFactor;
  final double requisitionRemainingQty; // base_qty - issued_qty on the requisition line
  final String? departmentId;
  final String? departmentLabel;
  final String? consumptionAreaId;
  final String? consumptionAreaLabel;
  final String? barcode; // carried forward from the source requisition line, if any
  final String trackingType;
  final TextEditingController qtyPackCtrl;
  final TextEditingController qtyLooseCtrl;
  List<_IssueBatchCandidate>  batchCandidates  = [];
  List<_IssueSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  _IssueLineRow({
    required this.sourceRequisitionNo,
    required this.sourceRequisitionDate,
    required this.sourceRequisitionLineSerial,
    required this.productId,
    required this.productDisplay,
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    required this.requisitionRemainingQty,
    this.departmentId,
    this.departmentLabel,
    this.consumptionAreaId,
    this.consumptionAreaLabel,
    this.barcode,
    this.trackingType = 'NONE',
  }) : qtyPackCtrl = TextEditingController(text: requisitionRemainingQty.toStringAsFixed(2)),
       qtyLooseCtrl = TextEditingController(text: '0');

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get baseQty  => qtyPack * uomConversionFactor + qtyLoose;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class MaterialIssueEntryScreen extends ConsumerStatefulWidget {
  final String? editIssueNo;
  final String? editIssueDate;
  const MaterialIssueEntryScreen({super.key, this.editIssueNo, this.editIssueDate});

  @override
  ConsumerState<MaterialIssueEntryScreen> createState() => _MaterialIssueEntryScreenState();
}

class _MaterialIssueEntryScreenState extends ConsumerState<MaterialIssueEntryScreen>
    with ScreenPermissionMixin<MaterialIssueEntryScreen> {
  @override String get screenName => RouteNames.materialIssues;

  MaterialIssueRepository get _ds => ref.read(materialIssueRepositoryProvider);

  String?  _issueNo;
  DateTime _issueDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  String?  _locationName;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _pendingRequisitions = [];
  final Set<String> _selectedRequisitionKeys = {};
  final List<_IssueLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _printing = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  bool _loadingVoucherLines = false;

  bool get _isNew => _issueNo == null;

  String _reqKey(Map<String, dynamic> r) => '${r['requisition_no']}|${r['requisition_date']}';

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

      if (widget.editIssueNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          issueNo: widget.editIssueNo!, issueDate: widget.editIssueDate,
        );
        if (header != null) {
          _issueNo    = header['issue_no'] as String;
          _issueDate  = DateTime.parse(header['issue_date'] as String);
          _status     = header['status'] as String;
          _locationId = header['location_id'] as String?;
          _locationName = (header['location'] as Map<String, dynamic>?)?['location_name'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';
        }
      }

      if (_locationId != null) {
        _pendingRequisitions = await _ds.getFulfillableRequisitions(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!,
        );
      }

      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingVoucherLines = true);
    try {
      final vouchers = await _ds.getPostedVouchers(clientId: session.clientId, companyId: session.companyId, issueNo: _issueNo!);
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

  Future<void> _toggleRequisition(Map<String, dynamic> req, bool checked) async {
    final session = ref.read(sessionProvider)!;
    final reqNo   = req['requisition_no'] as String;
    final reqDate = req['requisition_date'] as String;

    if (checked) {
      setState(() => _selectedRequisitionKeys.add(_reqKey(req)));
      try {
        final reqLines = await _ds.getRequisitionLines(
          clientId: session.clientId, companyId: session.companyId, requisitionNo: reqNo, requisitionDate: reqDate,
        );
        if (!mounted) return;
        final newLines = <_IssueLineRow>[];
        setState(() {
          for (final rl in reqLines) {
            final remaining = (rl['base_qty'] as num? ?? 0).toDouble() - (rl['issued_qty'] as num? ?? 0).toDouble();
            if (remaining <= 0) continue; // fully issued already — nothing left on this line
            final product    = rl['product'] as Map<String, dynamic>?;
            final uom        = rl['uom'] as Map<String, dynamic>?;
            final department = rl['department'] as Map<String, dynamic>?;
            final area       = rl['area'] as Map<String, dynamic>?;
            final row = _IssueLineRow(
              sourceRequisitionNo: reqNo, sourceRequisitionDate: reqDate,
              sourceRequisitionLineSerial: rl['serial_no'] as int,
              productId: rl['product_id'] as String,
              productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
              uomId: rl['uom_id'] as String?,
              uomLabel: uom?['description'] as String?,
              uomConversionFactor: (rl['uom_conversion_factor'] as num? ?? 1).toDouble(),
              requisitionRemainingQty: remaining,
              departmentId: rl['department_id'] as String?,
              departmentLabel: department?['description'] as String?,
              consumptionAreaId: rl['consumption_area_id'] as String?,
              consumptionAreaLabel: area?['description'] as String?,
              barcode: rl['barcode'] as String?,
              trackingType: product?['tracking_type'] as String? ?? 'NONE',
            );
            _lines.add(row);
            newLines.add(row);
          }
        });
        for (final row in newLines) {
          if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row));
        }
      } catch (e) {
        if (mounted) _showSnack('Could not load requisition lines: $e', color: AppColors.negative);
      }
    } else {
      setState(() {
        _selectedRequisitionKeys.remove(_reqKey(req));
        _lines.removeWhere((l) {
          if (l.sourceRequisitionNo == reqNo && l.sourceRequisitionDate == reqDate) { l.dispose(); return true; }
          return false;
        });
      });
    }
  }

  void _removeLine(_IssueLineRow row) => setState(() { _lines.remove(row); row.dispose(); });

  Future<void> _loadCandidates(_IssueLineRow row) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final rows = await _ds.getAvailableBatches(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId,
        );
        final candidates = rows.map((b) => _IssueBatchCandidate(
          batchNo: b['batch_no'] as String,
          expiryDate: b['expiry_date'] as String?,
          manufacturingDate: b['manufacturing_date'] as String?,
          availableBalance: b['balance'] as num? ?? 0,
        )).toList();
        if (mounted) setState(() { row.batchCandidates = candidates; row.candidatesLoaded = true; });
      } else if (row.isSerialTracked) {
        final rows = await _ds.getAvailableSerials(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId,
        );
        final candidates = rows.map((s) => _IssueSerialCandidate(serialNo: s['serial_no'] as String)).toList();
        if (mounted) setState(() { row.serialCandidates = candidates; row.candidatesLoaded = true; });
      }
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  /// Mandatory allocation whenever issueQty > 0 — same reasoning as
  /// Purchase Return: leaving it unallocated would silently fall through
  /// fn_approve_material_issue's v_has_batches/v_has_serials check into the
  /// plain aggregate movement, bypassing the strict per-batch/serial check.
  String? _batchSerialError(_IssueLineRow row) {
    if (row.baseQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No batches currently in stock for "${row.productDisplay}".';
      if ((row.batchQtySum - row.baseQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} but the issue quantity is ${row.baseQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialCandidates.isEmpty) return 'No serial numbers currently in stock for "${row.productDisplay}".';
      if (row.selectedSerialCount != row.baseQty.round() || (row.baseQty - row.baseQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the issue quantity (${row.baseQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  String? _qtyError(_IssueLineRow row) {
    if (row.baseQty < 0) return 'Issue qty for "${row.productDisplay}" cannot be negative.';
    if (row.baseQty > row.requisitionRemainingQty + 0.0001) {
      return 'Issue qty for "${row.productDisplay}" (${row.baseQty.toStringAsFixed(2)}) cannot exceed the requisition\'s remaining qty (${row.requisitionRemainingQty.toStringAsFixed(2)}).';
    }
    return null;
  }

  Future<bool> _saveDraft() async {
    if (_locationId == null) { _showSnack('Select a From Location.', color: AppColors.negative); return false; }
    final issuableLines = _lines.where((l) => l.baseQty > 0).toList();
    if (issuableLines.isEmpty) { _showSnack('Enter an issue quantity for at least one line.', color: AppColors.negative); return false; }
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
      for (var i = 0; i < issuableLines.length; i++) {
        final l = issuableLines[i];
        final lineSerial = i + 1;
        if (l.isBatchTracked) {
          for (final b in l.batchCandidates.where((b) => b.allocatedQty > 0)) {
            batches.add({'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate, 'manufacturing_date': b.manufacturingDate, 'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty});
          }
        } else if (l.isSerialTracked) {
          for (final s in l.serialCandidates.where((s) => s.selected)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
          }
        }
      }

      final header = {
        'client_id':   session.clientId,
        'company_id':  session.companyId,
        'location_id': _locationId,
        'issue_no':    _issueNo,
        'issue_date':  _fmtDate(_issueDate),
        'remarks':     _remarksCtrl.text.trim(),
      };
      final lines = issuableLines.asMap().entries.map((e) => {
        'serial_no':                     e.key + 1,
        'source_requisition_no':          e.value.sourceRequisitionNo,
        'source_requisition_date':        e.value.sourceRequisitionDate,
        'source_requisition_line_serial': e.value.sourceRequisitionLineSerial,
        'product_id':                     e.value.productId,
        'uom_id':                         e.value.uomId,
        'uom_conversion_factor':          e.value.uomConversionFactor,
        'qty_pack':                       e.value.qtyPack,
        'qty_loose':                      e.value.qtyLoose,
        'base_qty':                       e.value.baseQty,
        'department_id':                  e.value.departmentId,
        'consumption_area_id':            e.value.consumptionAreaId,
        'barcode':                        e.value.barcode ?? '',
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'MATERIAL_ISSUE',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_material_issue',
          payload:      {'p_header': header, 'p_lines': lines, 'p_batches': batches, 'p_serials': serials, 'p_user_id': session.userId},
        );
        await _ds.cacheIssueLocally(effectiveIssueNo: localId, header: header, lines: lines, batches: batches, serials: serials);
        if (mounted) {
          setState(() { _issueNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final issueNo = await _ds.save(header: header, lines: lines, batches: batches, serials: serials, userId: session.userId);
        unawaited(_ds.cacheIssueLocally(effectiveIssueNo: issueNo, header: header, lines: lines, batches: batches, serials: serials));
        if (mounted) {
          setState(() { _issueNo = issueNo; _saving = false; });
          _showSnack('Material Issue $issueNo saved.', color: AppColors.positive);
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

  Future<void> _approveIssue() async {
    if (_issueNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;
    if (_issueDate.isAfter(DateTime.now())) {
      _showSnack('Issue date cannot be in the future.', color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Material Issue'),
        content: const Text('Once approved, stock will be reduced and the Consumption Expense/Stock entry will be posted to Finance. This issue can no longer be edited. Continue?'),
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
        issueNo: _issueNo!, issueDate: _fmtDate(_issueDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Material Issue $_issueNo approved.', color: AppColors.positive);
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

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) => {
    'company': company,
    'header': {
      'issue_no':      _issueNo ?? '',
      'issue_date':    _displayDate(_issueDate),
      'status':        _status,
      'location_name': _locationName ?? '',
      'remarks':       _remarksCtrl.text,
    },
    'lines': _lines.map((l) => {
      'product_name':          l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
      'source_requisition_no': l.sourceRequisitionNo,
      'issue_qty':             l.baseQty,
      'department_name':       l.departmentLabel ?? '',
      'area_name':             l.consumptionAreaLabel ?? '',
    }).toList(),
  };

  Future<void> _printIssue() async {
    if (_issueNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('MATERIAL_ISSUE').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_issueNo.pdf');
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
      onPressed: _printing ? null : _printIssue,
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
                  if (_issueNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_issueNo != null) _buildPrintButton(),
                      if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_issueNo != null) _buildPrintButton(),
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
                    _buildRequisitionPickerCard(locked),
                    const SizedBox(height: 16),
                    _buildLinesCard(locked, showLooseQty, isMobile),
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

  Widget _buildTitleBlock() => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (context.canPop())
        IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back', onPressed: () => context.pop()),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_issueNo != null ? 'Material Issue · $_issueNo' : 'New Material Issue',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        Row(children: [
          _status == 'APPROVED' ? _statusChip(_status) : Text(_issueNo != null ? 'Draft' : 'Unsaved draft',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (_issueNo != null) ...[
            const SizedBox(width: 8),
            PendingSyncBadge(documentType: 'MATERIAL_ISSUE', documentId: _issueNo!),
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
      onPressed: _approving ? null : _approveIssue,
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
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final issueNoField = SakalFieldCard.readOnly(label: 'Issue No', value: _issueNo ?? '(auto on save)');
    final issueDateField = SakalFieldCard(
      label: 'Issue Date', required: true, editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(_issueDate, (d) => setState(() => _issueDate = d)),
        child: Row(children: [
          Expanded(child: Text(_displayDate(_issueDate), style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
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
        child: SakalFieldRow(isMobile: isMobile, spans: const [3, 3, 6], children: [issueNoField, issueDateField, remarksField]),
      ),
    );
  }

  Widget _buildRequisitionPickerCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Fulfillable Requisitions', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Approved or partially-issued requisitions at this location.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_locationId == null)
            const Text('Set a From Location first.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else if (_pendingRequisitions.isEmpty)
            const Text('No fulfillable requisitions at this location.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))
          else
            ..._pendingRequisitions.map((r) {
              final key = _reqKey(r);
              return CheckboxListTile(
                dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
                value: _selectedRequisitionKeys.contains(key),
                onChanged: locked ? null : (v) => _toggleRequisition(r, v ?? false),
                title: Text(r['requisition_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                subtitle: Text('${r['requisition_date']} · ${r['requested_by'] ?? ''} · ${r['status']}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              );
            }),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked, bool showLooseQty, bool isMobile) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Issue Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Remaining requested quantity is pre-filled — reduce or zero a line you\'re not issuing yet.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_lines.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet — pick a requisition above.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._lines.map((row) => _buildLineCard(row, locked, showLooseQty, isMobile)),
        ]),
      ),
    );
  }

  Widget _buildLineCard(_IssueLineRow row, bool locked, bool showLooseQty, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final unitField = SakalFieldCard.readOnly(label: 'Unit', value: row.uomLabel ?? '—');
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Issue Qty Pack' : 'Issue Qty', editable: !locked,
      child: TextFormField(
        controller: row.qtyPackCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Issue Qty Loose', editable: !locked,
      child: TextFormField(
        controller: row.qtyLooseCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: bare, style: style,
        onChanged: (_) => setState(() {}),
      ),
    );

    return SakalLineItemCard(
      title: row.productDisplay.isEmpty ? 'Line' : row.productDisplay,
      subtitle: 'Req ${row.sourceRequisitionNo} · Remaining ${row.requisitionRemainingQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}'
          ' · ${row.departmentLabel ?? '—'} / ${row.consumptionAreaLabel ?? '—'}',
      onDelete: locked ? null : () => _removeLine(row),
      fields: [
        SizedBox(width: 70, height: 56, child: unitField),
        SizedBox(width: 110, child: qtyPackField),
        if (showLooseQty) SizedBox(width: 110, child: qtyLooseField),
      ],
      body: (row.isBatchTracked || row.isSerialTracked) ? _buildBatchSerialEditor(row, locked, isMobile) : null,
    );
  }

  Widget _buildBatchSerialEditor(_IssueLineRow row, bool locked, bool isMobile) {
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
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(isBatch ? 'Select Batches to Issue' : 'Select Serial Numbers to Issue',
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

  Widget _buildPostedVouchersSection() {
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';
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
                    child: const Text('Material Consumption Voucher', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary)),
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
                    SakalTableHeaderBar(cells: [
                      Expanded(flex: 2, child: SakalTableHeaderBar.label('Serial No')),
                      Expanded(flex: 4, child: SakalTableHeaderBar.label('Ledger Name')),
                      Expanded(flex: 2, child: SakalTableHeaderBar.label('Debit', textAlign: TextAlign.right)),
                      Expanded(flex: 2, child: SakalTableHeaderBar.label('Credit', textAlign: TextAlign.right)),
                    ]),
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
                          Expanded(flex: 2, child: cell(isDr ? AppNumberFormat.amount(amount, numberFormat) : '—', align: TextAlign.right)),
                          Expanded(flex: 2, child: cell(!isDr ? AppNumberFormat.amount(amount, numberFormat) : '—', align: TextAlign.right)),
                        ]),
                      );
                    }),
                    Container(
                      decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.06), border: const Border(top: BorderSide(color: AppColors.border))),
                      child: Row(children: [
                        const Expanded(flex: 6, child: Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))),
                        Expanded(flex: 2, child: cell(AppNumberFormat.amount(totalDebit, numberFormat), align: TextAlign.right, bold: true)),
                        Expanded(flex: 2, child: cell(AppNumberFormat.amount(totalCredit, numberFormat), align: TextAlign.right, bold: true)),
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

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
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
  num availableBalance;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');

  _IssueBatchCandidate({required this.batchNo, this.expiryDate, required this.availableBalance});

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
  final String trackingType;
  final TextEditingController qtyCtrl;
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
    this.trackingType = 'NONE',
  }) : qtyCtrl = TextEditingController(text: requisitionRemainingQty.toStringAsFixed(2));

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get issueQty => double.tryParse(qtyCtrl.text) ?? 0;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyCtrl.dispose();
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
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _pendingRequisitions = [];
  final Set<String> _selectedRequisitionKeys = {};
  final List<_IssueLineRow> _lines = [];

  bool    _loading = true;
  bool    _loadingRequisitions = false;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;

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
    if (row.issueQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No batches currently in stock for "${row.productDisplay}".';
      if ((row.batchQtySum - row.issueQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} but the issue quantity is ${row.issueQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialCandidates.isEmpty) return 'No serial numbers currently in stock for "${row.productDisplay}".';
      if (row.selectedSerialCount != row.issueQty.round() || (row.issueQty - row.issueQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the issue quantity (${row.issueQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  String? _qtyError(_IssueLineRow row) {
    if (row.issueQty < 0) return 'Issue qty for "${row.productDisplay}" cannot be negative.';
    if (row.issueQty > row.requisitionRemainingQty + 0.0001) {
      return 'Issue qty for "${row.productDisplay}" (${row.issueQty.toStringAsFixed(2)}) cannot exceed the requisition\'s remaining qty (${row.requisitionRemainingQty.toStringAsFixed(2)}).';
    }
    return null;
  }

  Future<bool> _saveDraft() async {
    if (_locationId == null) { _showSnack('Select a From Location.', color: AppColors.negative); return false; }
    final issuableLines = _lines.where((l) => l.issueQty > 0).toList();
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
            batches.add({'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate, 'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty});
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
        // Issue is entered directly in base units (no pack/loose split
        // here, unlike Requisition/GRN) — conversion_factor is always 1
        // on this line so qty_pack * factor + qty_loose == base_qty holds
        // regardless of whatever factor the requisition line itself used.
        'uom_conversion_factor':          1,
        'qty_pack':                       e.value.issueQty,
        'qty_loose':                      0,
        'base_qty':                       e.value.issueQty,
        'department_id':                  e.value.departmentId,
        'consumption_area_id':            e.value.consumptionAreaId,
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
                    _buildRequisitionPickerCard(locked),
                    const SizedBox(height: 16),
                    _buildLinesCard(locked),
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
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: isMobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                field(InputDecorator(decoration: dec.copyWith(labelText: 'Issue No'),
                    child: Text(_issueNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _issueNo != null ? AppColors.textPrimary : AppColors.textDisabled)))),
                const SizedBox(height: 8),
                field(InkWell(onTap: locked ? null : () => _pickDate(_issueDate, (d) => setState(() => _issueDate = d)),
                    child: InputDecorator(decoration: dec.copyWith(labelText: 'Issue Date *'), child: Text(_displayDate(_issueDate), style: const TextStyle(fontSize: 13))))),
                const SizedBox(height: 8),
                TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Remarks')),
              ])
            : Row(children: [
                Expanded(flex: 2, child: field(InputDecorator(decoration: dec.copyWith(labelText: 'Issue No'),
                    child: Text(_issueNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _issueNo != null ? AppColors.textPrimary : AppColors.textDisabled))))),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: field(InkWell(onTap: locked ? null : () => _pickDate(_issueDate, (d) => setState(() => _issueDate = d)),
                    child: InputDecorator(decoration: dec.copyWith(labelText: 'Issue Date *',
                        suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                        child: Text(_displayDate(_issueDate), style: const TextStyle(fontSize: 13)))))),
                const SizedBox(width: 12),
                Expanded(flex: 3, child: field(TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Remarks')))),
              ]),
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
          else if (_loadingRequisitions)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
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

  Widget _buildLinesCard(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
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
                      Text('Req ${row.sourceRequisitionNo} · Remaining ${row.requisitionRemainingQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      Text('${row.departmentLabel ?? '—'} / ${row.consumptionAreaLabel ?? '—'}',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    ])),
                    const SizedBox(width: 8),
                    SizedBox(width: 100, child: TextFormField(
                      controller: row.qtyCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(labelText: 'Issue Qty'),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (_) => setState(() {}),
                    )),
                    if (!locked) IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative), onPressed: () => _removeLine(row)),
                  ]),
                  if (row.isBatchTracked || row.isSerialTracked) _buildBatchSerialEditor(row, locked),
                ]),
              ),
            )),
        ]),
      ),
    );
  }

  Widget _buildBatchSerialEditor(_IssueLineRow row, bool locked) {
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
          Text(isBatch ? 'Select Batches to Issue' : 'Select Serial Numbers to Issue',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch ? '${row.batchQtySum.toStringAsFixed(2)} / ${row.issueQty.toStringAsFixed(2)}' : '${row.selectedSerialCount} / ${row.issueQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: (isBatch ? (row.batchQtySum - row.issueQty).abs() < 0.0001 : row.selectedSerialCount == row.issueQty.round()) ? AppColors.positive : AppColors.negative)),
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
                decoration: dec.copyWith(labelText: 'Issue Qty'),
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

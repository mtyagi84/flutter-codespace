import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../domain/repositories/stock_count_review_repository.dart';
import '../providers/stock_count_review_providers.dart';

class StockCountReviewEntryScreen extends ConsumerStatefulWidget {
  final String? editReviewNo;
  final String? editReviewDate;
  const StockCountReviewEntryScreen({super.key, this.editReviewNo, this.editReviewDate});

  @override
  ConsumerState<StockCountReviewEntryScreen> createState() => _StockCountReviewEntryScreenState();
}

class _StockCountReviewEntryScreenState extends ConsumerState<StockCountReviewEntryScreen>
    with ScreenPermissionMixin<StockCountReviewEntryScreen> {
  @override String get screenName => RouteNames.stockCountReview;

  StockCountReviewRepository get _ds => ref.read(stockCountReviewRepositoryProvider);

  String?  _reviewNo;
  DateTime _reviewDate = DateTime.now();
  DateTime _asOfDate   = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  String?  _reasonId;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _reasons   = [];
  List<Map<String, dynamic>> _availableCounts = [];
  final Set<String> _selectedCountKeys = {};
  final Map<String, List<Map<String, dynamic>>> _countLinesByKey = {};
  List<Map<String, dynamic>> _variance = [];
  String? _postedAdjustmentNo;

  bool    _loading = true;
  bool    _refreshingVariance = false;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _printing = false;
  final Set<String> _expandedDrillDown = {};

  bool get _isNew => _reviewNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    super.dispose();
  }

  String _countKey(Map<String, dynamic> c) => '${c['count_no']}|${c['count_date']}';

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _locations  = await _ds.getLocations(clientId: session.clientId, companyId: session.companyId);
      _reasons    = await _ds.getReasons(clientId: session.clientId, companyId: session.companyId);
      final defaultReason = _reasons.where((r) => (r['description'] as String?) == 'Physical Count Variance').toList();
      _reasonId = defaultReason.isNotEmpty ? defaultReason.first['id'] as String : null;

      if (widget.editReviewNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          reviewNo: widget.editReviewNo!, reviewDate: widget.editReviewDate,
        );
        if (header != null) {
          _reviewNo    = header['review_no'] as String;
          _reviewDate  = DateTime.parse(header['review_date'] as String);
          _asOfDate    = DateTime.parse(header['as_of_date'] as String);
          _status      = header['status'] as String;
          _locationId  = header['location_id'] as String?;
          _reasonId    = header['reason_id'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';
          _postedAdjustmentNo = header['posted_adjustment_no'] as String?;

          final sources = await _ds.getSources(
            clientId: session.clientId, companyId: session.companyId,
            reviewNo: _reviewNo!, reviewDate: _fmtDate(_reviewDate),
          );
          for (final s in sources) {
            _selectedCountKeys.add('${s['source_count_no']}|${s['source_count_date']}');
          }
        }
      }

      if (_locationId != null) await _loadAvailableCounts();
      if (_reviewNo != null) await _refreshVariance();

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadAvailableCounts() async {
    final session = ref.read(sessionProvider)!;
    try {
      final counts = await _ds.getSubmittedCounts(
        clientId: session.clientId, companyId: session.companyId,
        locationId: _locationId!, currentReviewNo: _reviewNo,
      );
      if (mounted) setState(() => _availableCounts = counts);
    } catch (e) {
      if (mounted) _showSnack('Could not load submitted counts: $e', color: AppColors.negative);
    }
  }

  Future<void> _toggleCount(Map<String, dynamic> count, bool checked) async {
    final key = _countKey(count);
    setState(() => checked ? _selectedCountKeys.add(key) : _selectedCountKeys.remove(key));
    if (checked) unawaited(_loadCountLines(count));
    if (_selectedCountKeys.isEmpty) {
      setState(() => _variance = []);
      return;
    }
    final saved = await _saveDraft(showSnack: false);
    if (saved) unawaited(_refreshVariance());
  }

  Future<void> _loadCountLines(Map<String, dynamic> count) async {
    final session = ref.read(sessionProvider)!;
    final key = _countKey(count);
    try {
      final lines = await _ds.getCountLines(
        clientId: session.clientId, companyId: session.companyId,
        countNo: count['count_no'] as String, countDate: count['count_date'] as String,
      );
      if (mounted) setState(() => _countLinesByKey[key] = lines);
    } catch (_) { /* drill-down is advisory only */ }
  }

  Future<bool> _saveDraft({bool showSnack = true}) async {
    if (_locationId == null) { _showSnack('Select a Store/Location.', color: AppColors.negative); return false; }
    if (_selectedCountKeys.isEmpty) { _showSnack('Select at least one submitted Stock Count.', color: AppColors.negative); return false; }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':    session.clientId,
        'company_id':   session.companyId,
        'location_id':  _locationId,
        'review_no':    _reviewNo,
        'review_date':  _fmtDate(_reviewDate),
        'as_of_date':   _fmtDate(_asOfDate),
        'reason_id':    _reasonId,
        'remarks':      _remarksCtrl.text.trim(),
      };
      final sourceRefs = _selectedCountKeys.map((k) {
        final parts = k.split('|');
        return {'source_count_no': parts[0], 'source_count_date': parts[1]};
      }).toList();

      final reviewNo = await _ds.save(header: header, sourceRefs: sourceRefs, userId: session.userId);
      if (mounted) {
        setState(() { _reviewNo = reviewNo; _saving = false; });
        if (showSnack) _showSnack('Stock Count Review $reviewNo saved.', color: AppColors.positive);
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

  Future<void> _refreshVariance() async {
    if (_reviewNo == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() => _refreshingVariance = true);
    try {
      final variance = await _ds.computeVariance(
        clientId: session.clientId, companyId: session.companyId,
        reviewNo: _reviewNo!, reviewDate: _fmtDate(_reviewDate),
      );
      if (mounted) setState(() { _variance = variance; _refreshingVariance = false; });
    } catch (e) {
      if (mounted) { setState(() => _refreshingVariance = false); _showSnack('Could not compute variance: $e', color: AppColors.negative); }
    }
  }

  Future<void> _onAsOfDateChanged(DateTime d) async {
    setState(() => _asOfDate = d);
    if (_selectedCountKeys.isEmpty) return;
    final saved = await _saveDraft(showSnack: false);
    if (saved) unawaited(_refreshVariance());
  }

  List<Map<String, dynamic>> get _postableRows => _variance.where((r) => r['is_unknown_serial'] != true && r['adjust_flag'] != null).toList();
  List<Map<String, dynamic>> get _exceptionRows => _variance.where((r) => r['is_unknown_serial'] == true).toList();
  List<Map<String, dynamic>> get _matchedRows => _variance.where((r) => r['is_unknown_serial'] != true && r['adjust_flag'] == null).toList();

  Future<void> _approve() async {
    if (_reasonId == null) { _showSnack('Select a Reason.', color: AppColors.negative); return; }
    if (_postableRows.isEmpty) { _showSnack('No variance to post.', color: AppColors.negative); return; }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Stock Count Review'),
        content: Text('This will post a Stock Adjustment for ${_postableRows.length} line(s) and finalize this review. '
            '${_exceptionRows.isNotEmpty ? '${_exceptionRows.length} exception(s) will be skipped and need manual resolution. ' : ''}'
            'This cannot be undone. Continue?'),
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
      final adjNo = await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        reviewNo: _reviewNo!, reviewDate: _fmtDate(_reviewDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Stock Count Review $_reviewNo approved — Stock Adjustment $adjNo posted.', color: AppColors.positive);
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
      'review_no':   _reviewNo ?? '',
      'review_date': _displayDate(_reviewDate),
      'as_of_date':  _displayDate(_asOfDate),
      'status':      _status,
      'location_name': _locationLabel(_locationId),
      'posted_adjustment_no': _postedAdjustmentNo ?? '',
      'remarks':     _remarksCtrl.text,
    },
    'lines': _postableRows.map((r) => {
      'product_name': '[${r['product_code']}] ${r['product_name']}',
      'batch_no':     r['batch_no'] ?? '',
      'serial_no':    r['serial_no'] ?? '',
      'counted_qty':  r['counted_qty'],
      'system_qty':   r['system_qty'],
      'variance_qty': r['variance_qty'],
      'adjust_flag':  r['adjust_flag'],
    }).toList(),
  };

  Future<void> _printReview() async {
    if (_reviewNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('STOCK_COUNT_REVIEW').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_reviewNo.pdf');
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
      onPressed: _printing ? null : _printReview,
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

    final canSave    = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final canPost    = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;
    final locked     = _status != 'DRAFT';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildTitleBlock(),
                  if (_reviewNo != null || canSave || canPost) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_reviewNo != null) _buildPrintButton(),
                      if (canSave || canPost) Expanded(child: _buildActionButtons(canSave: canSave, canApprove: canPost)),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_reviewNo != null) _buildPrintButton(),
                  if (canSave || canPost) _buildActionButtons(canSave: canSave, canApprove: canPost),
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
                    _buildSourcePickerCard(locked),
                    const SizedBox(height: 16),
                    _buildVarianceCard(),
                    if (_exceptionRows.isNotEmpty) ...[const SizedBox(height: 16), _buildExceptionsCard()],
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_reviewNo != null ? 'Stock Count Review · $_reviewNo' : 'New Stock Count Review',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    _status == 'APPROVED' ? _statusChip() : Text(_reviewNo != null ? 'Draft' : 'Unsaved draft',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
  ]);

  Widget _statusChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
    child: const Text('APPROVED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
  );

  Widget _buildActionButtons({required bool canSave, required bool canApprove}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : () => _saveDraft(),
      child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save Draft'),
    ),
    if (canSave && canApprove) const SizedBox(width: 12),
    if (canApprove) FilledButton(
      onPressed: _approving ? null : _approve,
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
    final locationLocked = locked || _selectedCountKeys.isNotEmpty;

    final locationField = field(DropdownButtonFormField<String>(
      decoration: dec.copyWith(labelText: 'Store / Location *'),
      isExpanded: true, isDense: true, itemHeight: null,
      initialValue: _locationId,
      items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
          child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
      onChanged: locationLocked ? null : (v) { setState(() => _locationId = v); _loadAvailableCounts(); },
    ));
    final reviewDateField = field(InkWell(
      onTap: locked ? null : () => _pickDate(_reviewDate, (d) => setState(() => _reviewDate = d)),
      child: InputDecorator(
        decoration: dec.copyWith(labelText: 'Review Date *',
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
        child: Text(_displayDate(_reviewDate), style: const TextStyle(fontSize: 13)),
      ),
    ));
    final asOfDateField = field(InkWell(
      onTap: locked ? null : () => _pickDate(_asOfDate, _onAsOfDateChanged),
      child: InputDecorator(
        decoration: dec.copyWith(labelText: 'As Of Date *',
            helperText: 'System stock is compared as of this date',
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
        child: Text(_displayDate(_asOfDate), style: const TextStyle(fontSize: 13)),
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
                field(InputDecorator(decoration: dec.copyWith(labelText: 'Review No'),
                    child: Text(_reviewNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _reviewNo != null ? AppColors.textPrimary : AppColors.textDisabled)))),
                const SizedBox(height: 8),
                locationField, const SizedBox(height: 8),
                reviewDateField, const SizedBox(height: 8),
                asOfDateField, const SizedBox(height: 8),
                reasonField, const SizedBox(height: 8),
                remarksField,
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(flex: 2, child: field(InputDecorator(decoration: dec.copyWith(labelText: 'Review No'),
                      child: Text(_reviewNo ?? '(auto on save)', style: TextStyle(fontSize: 13, color: _reviewNo != null ? AppColors.textPrimary : AppColors.textDisabled))))),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: locationField),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: reviewDateField),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: asOfDateField),
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

  Widget _buildSourcePickerCard(bool locked) {
    if (_locationId == null) return const SizedBox.shrink();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Submitted Stock Counts at this Location', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          if (_availableCounts.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No submitted counts available at this location yet.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._availableCounts.map((c) => CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
              value: _selectedCountKeys.contains(_countKey(c)),
              onChanged: locked ? null : (v) => _toggleCount(c, v ?? false),
              title: Text(c['count_no'] as String, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text('${c['count_date']}${(c['remarks'] as String?)?.isNotEmpty == true ? ' · ${c['remarks']}' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            )),
        ]),
      ),
    );
  }

  Widget _buildVarianceCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Variance', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (_refreshingVariance) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 8),
          if (_variance.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Select at least one submitted Stock Count to see variance.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else ...[
            Container(
              decoration: const BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.vertical(top: Radius.circular(6))),
              child: Row(children: [
                _th('Product', flex: 3), _th('Lot', flex: 2), _th('Counted', flex: 2, align: TextAlign.right),
                _th('System', flex: 2, align: TextAlign.right), _th('Variance', flex: 2, align: TextAlign.right), _th('', flex: 1),
              ]),
            ),
            ..._postableRows.asMap().entries.map((e) => _buildVarianceRow(e.value, e.key.isEven)),
            if (_matchedRows.isNotEmpty) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${_matchedRows.length} product(s) matched exactly (no variance) and will not be posted.',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _th(String label, {int flex = 1, TextAlign align = TextAlign.left}) => Expanded(
    flex: flex,
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(label, textAlign: align, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 11))),
  );

  Widget _buildVarianceRow(Map<String, dynamic> r, bool isEven) {
    final lot = (r['batch_no'] as String?) ?? (r['serial_no'] as String?) ?? '—';
    final counted  = (r['counted_qty'] as num?)?.toDouble() ?? 0;
    final system   = (r['system_qty'] as num?)?.toDouble() ?? 0;
    final variance = (r['variance_qty'] as num?)?.toDouble() ?? 0;
    final flag = r['adjust_flag'] as String?;
    final rowKey = '${r['product_id']}|${r['batch_no']}|${r['serial_no']}';
    final expanded = _expandedDrillDown.contains(rowKey);

    return Column(children: [
      InkWell(
        onTap: () => setState(() => expanded ? _expandedDrillDown.remove(rowKey) : _expandedDrillDown.add(rowKey)),
        child: Container(
          color: isEven ? Colors.white : AppColors.background,
          child: Row(children: [
            Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Text('[${r['product_code']}] ${r['product_name']}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
            Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(lot, style: const TextStyle(fontSize: 12)))),
            Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(counted.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
            Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(system.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)))),
            Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('${flag ?? ''}${variance.abs().toStringAsFixed(2)}', textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: flag == '+' ? AppColors.positive : AppColors.negative)))),
            Expanded(flex: 1, child: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: AppColors.textSecondary)),
          ]),
        ),
      ),
      if (expanded) _buildDrillDown(r),
    ]);
  }

  Widget _buildDrillDown(Map<String, dynamic> r) {
    final productId = r['product_id'] as String?;
    final batchNo    = r['batch_no'] as String?;
    final serialNo   = r['serial_no'] as String?;
    final contributions = <String>[];
    for (final key in _selectedCountKeys) {
      final lines = _countLinesByKey[key] ?? const [];
      for (final l in lines) {
        if (l['product_id'] != productId) continue;
        final countNo = key.split('|').first;
        if (batchNo != null || serialNo != null) {
          contributions.add('$countNo — ${l['counted_base_qty']}');
        } else {
          contributions.add('$countNo — ${l['counted_base_qty']}');
        }
      }
    }
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(20, 4, 10, 8),
      child: contributions.isEmpty
          ? const Text('No source detail available.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary))
          : Text('Contributed by: ${contributions.join(', ')}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
    );
  }

  Widget _buildExceptionsCard() {
    return Card(
      elevation: 0,
      color: AppColors.negative.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: AppColors.negative.withValues(alpha: 0.3))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.negative, size: 18),
            const SizedBox(width: 8),
            Text('Exceptions — ${_exceptionRows.length} unrecognized serial(s)',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.negative)),
          ]),
          const SizedBox(height: 6),
          const Text('These serial numbers were physically counted but the system has no record of them at this location. '
              'They cannot be safely auto-adjusted (no established cost/origin) and are excluded from posting — resolve manually.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 10),
          ..._exceptionRows.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('[${r['product_code']}] ${r['product_name']} — serial ${r['serial_no']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          )),
        ]),
      ),
    );
  }
}

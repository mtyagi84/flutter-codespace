import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../domain/repositories/stock_transfer_request_repository.dart';
import '../providers/stock_transfer_request_providers.dart';

class _RequestLineRow {
  String? productId;
  String  productDisplay = '';
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  final TextEditingController remarksCtrl  = TextEditingController();
  double transferredQty = 0; // rollup, only set when reloading an existing line

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get baseQty  => qtyPack * uomConversionFactor + qtyLoose;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    remarksCtrl.dispose();
  }
}

class StockTransferRequestEntryScreen extends ConsumerStatefulWidget {
  final String? editRequestNo;
  final String? editRequestDate;
  const StockTransferRequestEntryScreen({super.key, this.editRequestNo, this.editRequestDate});

  @override
  ConsumerState<StockTransferRequestEntryScreen> createState() => _StockTransferRequestEntryScreenState();
}

class _StockTransferRequestEntryScreenState extends ConsumerState<StockTransferRequestEntryScreen>
    with ScreenPermissionMixin<StockTransferRequestEntryScreen> {
  @override String get screenName => RouteNames.stockTransferRequests;

  StockTransferRequestRepository get _ds => ref.read(stockTransferRequestRepositoryProvider);

  String?  _requestNo;
  DateTime _requestDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _fromLocationId;
  String?  _toLocationId;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  final List<_RequestLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;

  bool get _isNew => _requestNo == null;

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
      _fromLocationId = session.locationId;
      _locations = await _ds.getLocations(clientId: session.clientId, companyId: session.companyId);

      if (widget.editRequestNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          requestNo: widget.editRequestNo!, requestDate: widget.editRequestDate,
        );
        if (header != null) {
          _requestNo      = header['request_no'] as String;
          _requestDate    = DateTime.parse(header['request_date'] as String);
          _status         = header['status'] as String;
          _fromLocationId = header['from_location_id'] as String?;
          _toLocationId   = header['to_location_id'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';

          final savedLines = await _ds.getLines(
            clientId: session.clientId, companyId: session.companyId,
            requestNo: _requestNo!, requestDate: _fmtDate(_requestDate),
          );
          for (final sl in savedLines) {
            final product = sl['product'] as Map<String, dynamic>?;
            final uom     = sl['uom'] as Map<String, dynamic>?;
            final row = _RequestLineRow()
              ..productId = sl['product_id'] as String?
              ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
              ..uomId = sl['uom_id'] as String?
              ..uomLabel = uom?['description'] as String?
              ..uomConversionFactor = (sl['uom_conversion_factor'] as num? ?? 1).toDouble()
              ..transferredQty = (sl['transferred_qty'] as num? ?? 0).toDouble();
            row.qtyPackCtrl.text = (sl['qty_pack'] as num? ?? 0).toString();
            row.qtyLooseCtrl.text = (sl['qty_loose'] as num? ?? 0).toString();
            row.remarksCtrl.text = sl['remarks'] as String? ?? '';
            _lines.add(row);
          }
        }
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  void _addLine() => setState(() => _lines.add(_RequestLineRow()));

  void _removeLine(_RequestLineRow row) {
    setState(() { _lines.remove(row); row.dispose(); });
  }

  bool _isDuplicateProduct(String productId, {_RequestLineRow? excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  Future<void> _onProductSelected(_RequestLineRow row, Map<String, dynamic> product) async {
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
  }

  Future<bool> _saveDraft() async {
    if (_fromLocationId == null || _toLocationId == null) {
      _showSnack('Select both From Location and To Location.', color: AppColors.negative);
      return false;
    }
    if (_fromLocationId == _toLocationId) {
      _showSnack('From Location and To Location cannot be the same.', color: AppColors.negative);
      return false;
    }
    final validLines = _lines.where((l) => l.productId != null && l.baseQty > 0).toList();
    if (validLines.isEmpty) { _showSnack('Add at least one line with a product and quantity.', color: AppColors.negative); return false; }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final requestNo = await _ds.save(
        header: {
          'client_id':        session.clientId,
          'company_id':       session.companyId,
          'from_location_id': _fromLocationId,
          'to_location_id':   _toLocationId,
          'request_no':       _requestNo,
          'request_date':     _fmtDate(_requestDate),
          'remarks':          _remarksCtrl.text.trim(),
        },
        lines: validLines.asMap().entries.map((e) => {
          'serial_no':              e.key + 1,
          'product_id':             e.value.productId,
          'uom_id':                 e.value.uomId,
          'uom_conversion_factor':  e.value.uomConversionFactor,
          'qty_pack':               e.value.qtyPack,
          'qty_loose':              e.value.qtyLoose,
          'base_qty':               e.value.baseQty,
          'remarks':                e.value.remarksCtrl.text.trim(),
        }).toList(),
        userId: session.userId,
      );
      if (mounted) {
        setState(() { _requestNo = requestNo; _saving = false; });
        _showSnack('Stock Transfer Request $requestNo saved.', color: AppColors.positive);
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

  Future<void> _approve() async {
    if (_requestNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (_requestDate.isAfter(DateTime.now())) {
      _showSnack('Request date cannot be in the future.', color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Stock Transfer Request'),
        content: const Text('Once approved, this request becomes available for Stock Transfer and can no longer be edited. Continue?'),
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
        requestNo: _requestNo!, requestDate: _fmtDate(_requestDate),
        approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Stock Transfer Request $_requestNo approved.', color: AppColors.positive);
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
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime.now());
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
                  if (canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    _buildActionButtons(canSave: canSave, canApprove: showApprove),
                  ],
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
                    _buildLinesCard(locked, showLooseQty),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_requestNo != null ? 'Stock Transfer Request · $_requestNo' : 'New Stock Transfer Request',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    _status != 'DRAFT' ? _statusChip(_status) : Text(_requestNo != null ? 'Draft' : 'Unsaved draft',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
  ]);

  Widget _statusChip(String status) {
    final color = status == 'DRAFT' ? AppColors.secondary
        : status == 'CLOSED' ? AppColors.textSecondary : AppColors.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status.replaceAll('_', ' '), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
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
      onPressed: _approving ? null : _approve,
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

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    const fh = 56.0;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget field(Widget child) => SizedBox(height: fh, child: child);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'From Location *'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _fromLocationId,
              items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() => _fromLocationId = v),
            ));
            final f2 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'To Location *'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _toLocationId,
              items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() => _toLocationId = v),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2),
                  ])
                : Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]);
          }),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Request No'),
              child: Text(_requestNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _requestNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f2 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_requestDate, (d) => setState(() => _requestDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'Request Date *',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_requestDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            final f3 = field(TextFormField(
              controller: _remarksCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Remarks'),
              style: const TextStyle(fontSize: 13),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f3),
                  ])
                : Row(children: [
                    Expanded(flex: 2, child: f1), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                    Expanded(flex: 3, child: f3),
                  ]);
          }),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked, bool showLooseQty) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
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
                child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(
                    width: 260,
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
                        decoration: dec.copyWith(labelText: 'Product'),
                        style: const TextStyle(fontSize: 13),
                      ),
                      optionsViewBuilder: (context, onSel, opts) => Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4, borderRadius: BorderRadius.circular(4),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 260, minWidth: 260),
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
                  SizedBox(width: 90, child: TextFormField(
                    controller: row.qtyPackCtrl, enabled: !locked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: showLooseQty ? 'Qty Pack' : 'Quantity'),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                  )),
                  if (showLooseQty) SizedBox(width: 90, child: TextFormField(
                    controller: row.qtyLooseCtrl, enabled: !locked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Qty Loose'),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                  )),
                  SizedBox(width: 220, child: TextFormField(
                    controller: row.remarksCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'Remarks'),
                    style: const TextStyle(fontSize: 13),
                  )),
                  if (row.transferredQty > 0) SizedBox(width: 110, child: Text('Transferred: ${row.transferredQty.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                  if (!locked) IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                    onPressed: () => _removeLine(row),
                  ),
                ]),
              ),
            )),
        ]),
      ),
    );
  }
}

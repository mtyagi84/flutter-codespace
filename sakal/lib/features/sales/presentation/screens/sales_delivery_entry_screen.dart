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
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../domain/repositories/sales_delivery_repository.dart';
import '../providers/sales_delivery_providers.dart';

/// A batch currently in stock at this location — candidates come from LIVE
/// stock (v_batch_stock_balance), never from the source invoice (a DEFERRED
/// invoice never stages rid_transaction_line_batches at all). availableBalance
/// is a UX hint only; the real block is fn_post_stock_movement's strict
/// per-batch check at Approve.
class _SDBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final String? manufacturingDate;
  final num availableBalance;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');
  _SDBatchCandidate({required this.batchNo, this.expiryDate, this.manufacturingDate, required this.availableBalance});
  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
  void dispose() => qtyCtrl.dispose();
}

class _SDSerialCandidate {
  final String serialNo;
  bool selected = false;
  _SDSerialCandidate({required this.serialNo});
}

class _SDLineRow {
  final int invoiceLineSerial;
  final String productId;
  final String productDisplay;
  final String? uomId;
  final String? uomLabel;
  final double uomConversionFactor;
  final double pendingQty; // invoice line's own base_qty - delivered_qty
  final String? barcode;
  final String trackingType;
  final int? existingLineSerialNo;
  final TextEditingController qtyPackCtrl;
  final TextEditingController qtyLooseCtrl;
  List<_SDBatchCandidate>  batchCandidates  = [];
  List<_SDSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;

  _SDLineRow({
    required this.invoiceLineSerial,
    required this.productId,
    required this.productDisplay,
    this.uomId,
    this.uomLabel,
    this.uomConversionFactor = 1,
    required this.pendingQty,
    this.barcode,
    this.trackingType = 'NONE',
    this.existingLineSerialNo,
    double? initialQtyPack,
    double initialQtyLoose = 0,
  }) : qtyPackCtrl = TextEditingController(text: (initialQtyPack ?? pendingQty).toStringAsFixed(2)),
       qtyLooseCtrl = TextEditingController(text: initialQtyLoose.toStringAsFixed(2));

  bool get isBatchTracked  => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get deliveryQty => qtyPack * uomConversionFactor + qtyLoose;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int    get selectedSerialCount => serialCandidates.where((s) => s.selected).length;

  void dispose() {
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    for (final b in batchCandidates) { b.dispose(); }
  }
}

class SalesDeliveryEntryScreen extends ConsumerStatefulWidget {
  final String? editDeliveryNo;
  final String? editDeliveryDate;
  const SalesDeliveryEntryScreen({super.key, this.editDeliveryNo, this.editDeliveryDate});

  @override
  ConsumerState<SalesDeliveryEntryScreen> createState() => _SalesDeliveryEntryScreenState();
}

class _SalesDeliveryEntryScreenState extends ConsumerState<SalesDeliveryEntryScreen>
    with ScreenPermissionMixin<SalesDeliveryEntryScreen> {
  // Entry screen is not itself a menu item — Menu -> List -> Entry pattern.
  @override String get screenName => RouteNames.salesDeliveries;

  SalesDeliveryRepository get _ds => ref.read(salesDeliveryRepositoryProvider);

  String?  _deliveryNo;
  DateTime _deliveryDate = DateTime.now();
  String   _status       = 'DRAFT';
  String?  _locationId;
  String?  _locationName;

  String?  _invoiceNo;
  String?  _invoiceDate;
  String?  _customerId;
  String?  _customerDisplay;

  // Ship-to snapshot — copied from a saved rim_customer_delivery_locations
  // row (or typed ad-hoc), never a live FK read at print time.
  String?  _shipToLocationId;
  final _shipToLocationNameCtrl = TextEditingController();
  final _shipToAddressLine1Ctrl = TextEditingController();
  final _shipToAddressLine2Ctrl = TextEditingController();
  String?  _shipToCityId;
  final _shipToContactPersonCtrl = TextEditingController();
  final _shipToContactPhoneCtrl  = TextEditingController();
  List<Map<String, dynamic>> _customerDeliveryLocations = [];

  // Transport Details (optional, migration 101 — generic table).
  final _vehicleNoCtrl       = TextEditingController();
  final _transporterNameCtrl = TextEditingController();
  final _driverNameCtrl      = TextEditingController();
  final _driverPhoneCtrl     = TextEditingController();

  final _receivedByNameCtrl = TextEditingController();
  String? _reason;
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _invoiceOptions = [];
  final List<_SDLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving    = false;
  bool    _approving = false;
  bool    _loadingInvoiceLines = false;
  bool    _printing  = false;

  List<Map<String, dynamic>> _postedVouchers = [];
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};

  // _users loaded once in _init (getUsersForAutocomplete) — resolves real
  // prepared_by/authorised_by names for print, same pattern Sales Invoice
  // uses (never Material Issue's own known-broken silent-blank pattern).
  List<Map<String, dynamic>> _users = [];
  String? _createdByUserId;
  String? _approvedByUserId;
  String? _resolveUserName(String? userId) {
    if (userId == null) return null;
    final match = _users.firstWhere((u) => u['id'] == userId, orElse: () => const {});
    return match['full_name'] as String?;
  }

  bool get _isNew => _deliveryNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _shipToLocationNameCtrl.dispose();
    _shipToAddressLine1Ctrl.dispose();
    _shipToAddressLine2Ctrl.dispose();
    _shipToContactPersonCtrl.dispose();
    _shipToContactPhoneCtrl.dispose();
    _vehicleNoCtrl.dispose();
    _transporterNameCtrl.dispose();
    _driverNameCtrl.dispose();
    _driverPhoneCtrl.dispose();
    _receivedByNameCtrl.dispose();
    _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      _locationId = session.locationId;
      _users = await _ds.getUsersForAutocomplete(clientId: session.clientId, companyId: session.companyId);

      if (widget.editDeliveryNo != null) {
        final header = await _ds.getHeader(
          clientId: session.clientId, companyId: session.companyId,
          deliveryNo: widget.editDeliveryNo!, deliveryDate: widget.editDeliveryDate,
        );
        if (header != null) {
          _deliveryNo   = header['delivery_no'] as String;
          _deliveryDate = DateTime.parse(header['delivery_date'] as String);
          _status       = header['status'] as String;
          _locationId   = header['location_id'] as String?;
          final location = header['location'] as Map<String, dynamic>?;
          _locationName = location?['location_name'] as String?;
          _invoiceNo    = header['invoice_no'] as String;
          _invoiceDate  = header['invoice_date'] as String;
          _customerId   = header['customer_id'] as String?;
          final customer = header['customer'] as Map<String, dynamic>?;
          _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
          _shipToLocationId = header['ship_to_location_id'] as String?;
          _shipToLocationNameCtrl.text = header['ship_to_location_name'] as String? ?? '';
          _shipToAddressLine1Ctrl.text = header['ship_to_address_line1'] as String? ?? '';
          _shipToAddressLine2Ctrl.text = header['ship_to_address_line2'] as String? ?? '';
          _shipToCityId = header['ship_to_city_id'] as String?;
          _shipToContactPersonCtrl.text = header['ship_to_contact_person'] as String? ?? '';
          _shipToContactPhoneCtrl.text  = header['ship_to_contact_phone'] as String? ?? '';
          _receivedByNameCtrl.text = header['received_by_name'] as String? ?? '';
          _reason = header['reason'] as String?;
          _remarksCtrl.text = header['remarks'] as String? ?? '';
          _createdByUserId  = header['created_by'] as String?;
          _approvedByUserId = header['approved_by'] as String?;

          if (_customerId != null) unawaited(_loadCustomerDeliveryLocations());
          unawaited(_loadTransportDetails());
          await _loadExistingLines(session);
        }
      }
      if (mounted) setState(() => _loading = false);
      if (_status == 'APPROVED') unawaited(_loadPostedVouchers());
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load: $e'; });
    }
  }

  Future<void> _loadExistingLines(UserSession session) async {
    final savedLines = await _ds.getLines(
      clientId: session.clientId, companyId: session.companyId,
      deliveryNo: _deliveryNo!, deliveryDate: _fmtDate(_deliveryDate),
    );
    final invoiceLines = await _ds.getInvoiceLines(
      clientId: session.clientId, companyId: session.companyId,
      invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
    );

    final newLines = <_SDLineRow>[];
    for (final sl in savedLines) {
      final il = invoiceLines.firstWhere(
        (l) => l['serial_no'] == sl['invoice_line_serial'],
        orElse: () => const {},
      );
      final product = il['product'] as Map<String, dynamic>?;
      final uom = sl['uom'] as Map<String, dynamic>?;
      final invoicedBaseQty = (il['base_qty'] as num? ?? 0).toDouble();
      final deliveredQty    = (il['delivered_qty'] as num? ?? 0).toDouble();
      final row = _SDLineRow(
        invoiceLineSerial: sl['invoice_line_serial'] as int,
        productId: sl['product_id'] as String,
        productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
        uomId: sl['uom_id'] as String?,
        uomLabel: uom?['description'] as String?,
        uomConversionFactor: (sl['uom_conversion_factor'] as num? ?? 1).toDouble(),
        // This delivery's own already-saved qty still counts as "pending"
        // from the reopened-draft's own perspective, so add it back.
        pendingQty: (invoicedBaseQty - deliveredQty) + (sl['base_qty'] as num? ?? 0).toDouble(),
        barcode: sl['barcode'] as String?,
        trackingType: product?['tracking_type'] as String? ?? 'NONE',
        existingLineSerialNo: sl['serial_no'] as int,
        initialQtyPack: (sl['qty_pack'] as num? ?? sl['base_qty'] as num? ?? 0).toDouble(),
        initialQtyLoose: (sl['qty_loose'] as num? ?? 0).toDouble(),
      );
      _lines.add(row);
      newLines.add(row);
    }
    if (mounted) setState(() {});
    for (final row in newLines) {
      if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row, autoAllocate: false));
    }
  }

  Future<void> _loadPostedVouchers() async {
    final session = ref.read(sessionProvider)!;
    try {
      final vouchers = await _ds.getPostedVouchers(
        clientId: session.clientId, companyId: session.companyId, deliveryNo: _deliveryNo!,
      );
      final lines = <String, List<Map<String, dynamic>>>{};
      for (final v in vouchers) {
        lines[v['trans_no'] as String] = await _ds.getPostedVoucherLines(
          clientId: session.clientId, companyId: session.companyId,
          voucherNo: v['trans_no'] as String, voucherDate: v['trans_date'] as String,
        );
      }
      if (mounted) setState(() { _postedVouchers = vouchers; _voucherLines..clear()..addAll(lines); });
    } catch (_) { /* best-effort */ }
  }

  Future<void> _loadCustomerDeliveryLocations() async {
    final session = ref.read(sessionProvider)!;
    if (_customerId == null) return;
    try {
      final rows = await _ds.getCustomerDeliveryLocations(
        clientId: session.clientId, companyId: session.companyId, customerId: _customerId!,
      );
      if (mounted) setState(() => _customerDeliveryLocations = rows);
      // Pre-fill the default location on a brand-new delivery only — never
      // silently overwrite an already-chosen/typed ship-to on reopen.
      if (_isNew && _shipToLocationNameCtrl.text.isEmpty) {
        final def = rows.firstWhereOrNull((r) => r['is_default'] == true) ?? rows.firstOrNull;
        if (def != null) _applyShipToLocation(def);
      }
    } catch (_) { /* best-effort */ }
  }

  void _applyShipToLocation(Map<String, dynamic> loc) {
    setState(() {
      _shipToLocationId = loc['id'] as String?;
      _shipToLocationNameCtrl.text = loc['location_name'] as String? ?? '';
      _shipToAddressLine1Ctrl.text = loc['address_line1'] as String? ?? '';
      _shipToAddressLine2Ctrl.text = loc['address_line2'] as String? ?? '';
      _shipToCityId = loc['city_id'] as String?;
      _shipToContactPersonCtrl.text = loc['contact_person'] as String? ?? '';
      _shipToContactPhoneCtrl.text  = loc['contact_phone'] as String? ?? '';
    });
  }

  Future<void> _loadTransportDetails() async {
    final session = ref.read(sessionProvider)!;
    if (_deliveryNo == null) return;
    try {
      final t = await _ds.getTransportDetails(
        clientId: session.clientId, companyId: session.companyId,
        deliveryNo: _deliveryNo!, deliveryDate: _fmtDate(_deliveryDate),
      );
      if (t != null && mounted) {
        setState(() {
          _vehicleNoCtrl.text       = t['vehicle_no'] as String? ?? '';
          _transporterNameCtrl.text = t['transporter_name'] as String? ?? '';
          _driverNameCtrl.text      = t['driver_name'] as String? ?? '';
          _driverPhoneCtrl.text     = t['driver_phone'] as String? ?? '';
        });
      }
    } catch (_) { /* best-effort, optional field */ }
  }

  // ── Invoice selection ─────────────────────────────────────────────────────

  Future<void> _searchInvoices(String query) async {
    final session = ref.read(sessionProvider)!;
    try {
      final rows = await _ds.getPendingDeliveryInvoices(
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
      _customerId  = invoice['customer_id'] as String?;
      final customer = invoice['customer'] as Map<String, dynamic>?;
      _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
      _locationId = invoice['location_id'] as String?;
      final location = invoice['location'] as Map<String, dynamic>?;
      _locationName = location?['location_name'] as String?;
      for (final l in _lines) { l.dispose(); }
      _lines.clear();
      _loadingInvoiceLines = true;
    });
    unawaited(_loadCustomerDeliveryLocations());
    try {
      final invoiceLines = await _ds.getInvoiceLines(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!,
      );
      if (!mounted) return;
      final newLines = <_SDLineRow>[];
      setState(() {
        for (final il in invoiceLines) {
          final invoicedBaseQty = (il['base_qty'] as num? ?? 0).toDouble();
          final deliveredQty    = (il['delivered_qty'] as num? ?? 0).toDouble();
          final pending = invoicedBaseQty - deliveredQty;
          if (pending <= 0) continue; // fully delivered already — nothing left to offer
          final product = il['product'] as Map<String, dynamic>?;
          final uom = il['uom'] as Map<String, dynamic>?;
          final row = _SDLineRow(
            invoiceLineSerial: il['serial_no'] as int,
            productId: il['product_id'] as String,
            productDisplay: product != null ? '[${product['product_code']}] ${product['product_name']}' : '',
            uomId: il['uom_id'] as String?,
            uomLabel: uom?['description'] as String?,
            uomConversionFactor: (il['uom_conversion_factor'] as num? ?? 1).toDouble(),
            pendingQty: pending,
            barcode: il['barcode'] as String?,
            trackingType: product?['tracking_type'] as String? ?? 'NONE',
          );
          _lines.add(row);
          newLines.add(row);
        }
        _loadingInvoiceLines = false;
      });
      for (final row in newLines) {
        if (row.isBatchTracked || row.isSerialTracked) unawaited(_loadCandidates(row, autoAllocate: true));
      }
    } catch (e) {
      if (mounted) { setState(() => _loadingInvoiceLines = false); _showSnack('Could not load invoice lines: $e', color: AppColors.negative); }
    }
  }

  void _removeLine(_SDLineRow row) {
    setState(() { _lines.remove(row); row.dispose(); });
  }

  /// Candidates = LIVE stock at this location (v_batch_stock_balance/
  /// v_serial_stock_status) — a DEFERRED invoice never staged any source-
  /// document allocation to scope against, unlike Sales Return. Optionally
  /// FEFO auto-allocates once loaded (earliest-expiry-first, already the
  /// view's own sort order — never a Dart-side sort), same greedy-fill
  /// algorithm as Sales Invoice's own DIRECT-mode dispatch.
  Future<void> _loadCandidates(_SDLineRow row, {required bool autoAllocate}) async {
    if (_locationId == null) return;
    final session = ref.read(sessionProvider)!;
    try {
      if (row.isBatchTracked) {
        final rows = await _ds.getBatchStockBalance(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId,
        );
        row.batchCandidates = rows.map((b) => _SDBatchCandidate(
          batchNo: b['batch_no'] as String,
          expiryDate: b['expiry_date'] as String?,
          manufacturingDate: b['manufacturing_date'] as String?,
          availableBalance: b['balance'] as num? ?? 0,
        )).toList();
      } else if (row.isSerialTracked) {
        final rows = await _ds.getSerialStockStatus(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId,
        );
        row.serialCandidates = rows.map((s) => _SDSerialCandidate(serialNo: s['serial_no'] as String)).toList();
      }
      if (mounted) setState(() => row.candidatesLoaded = true);
      if (autoAllocate) _autoAllocateFefo(row);
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  /// FEFO auto-fill (earliest expiry/manufacturing date first — this app's
  /// established convention everywhere, not literal receipt-order FIFO),
  /// mirroring Sales Invoice's own _autoAllocateBatchSerial exactly: greedy
  /// fill in candidate order (already expiry_date.asc.nullslast from the
  /// view), capped per candidate at its own available balance. Always
  /// user-editable afterward — "Reset to FEFO" re-triggers this.
  void _autoAllocateFefo(_SDLineRow row) {
    if (!row.candidatesLoaded) return;
    final needed = row.deliveryQty;
    if (needed <= 0) return;
    if (row.isBatchTracked) {
      var remaining = needed;
      for (final b in row.batchCandidates) {
        final available = b.availableBalance.toDouble();
        final take = remaining <= 0 ? 0.0 : (available < remaining ? available : remaining);
        b.qtyCtrl.text = take > 0 ? take.toStringAsFixed(2) : '0';
        remaining -= take;
      }
    } else if (row.isSerialTracked) {
      final count = needed.round();
      for (var i = 0; i < row.serialCandidates.length; i++) {
        row.serialCandidates[i].selected = i < count;
      }
    }
    if (mounted) setState(() {});
  }

  /// Mandatory whenever delivery qty > 0 on a tracked line — same strictness
  /// as every other consolidation-shaped module in this schema.
  String? _batchSerialError(_SDLineRow row) {
    if (row.deliveryQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No stock found for "${row.productDisplay}".';
      if ((row.batchQtySum - row.deliveryQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} '
            'but the delivery quantity is ${row.deliveryQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialCandidates.isEmpty) return 'No in-stock serial numbers found for "${row.productDisplay}".';
      if (row.selectedSerialCount != row.deliveryQty.round() || (row.deliveryQty - row.deliveryQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers selected for "${row.productDisplay}" (${row.selectedSerialCount}) must match the delivery quantity '
            '(${row.deliveryQty.toStringAsFixed(2)}).';
      }
    }
    return null;
  }

  /// Zero/negative delivery qty is never allowed (req: user cannot deliver
  /// zero qty) — also enforced server-side (DELIVERY_QTY_ZERO_NOT_ALLOWED)
  /// as defense-in-depth.
  String? _qtyError(_SDLineRow row) {
    if (row.deliveryQty <= 0) return 'Delivery qty for "${row.productDisplay}" must be greater than zero — remove the line instead of leaving it at zero.';
    if (row.deliveryQty > row.pendingQty + 0.0001) {
      return 'Delivery qty for "${row.productDisplay}" (${row.deliveryQty.toStringAsFixed(2)}) '
          'cannot exceed what remains pending (${row.pendingQty.toStringAsFixed(2)}).';
    }
    return null;
  }

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_invoiceNo == null) { _showSnack('Select an invoice to deliver against.', color: AppColors.negative); return false; }
    if (_lines.where((l) => l.deliveryQty > 0).isEmpty) { _showSnack('Enter a delivery quantity for at least one line.', color: AppColors.negative); return false; }

    for (final l in _lines) {
      final qtyErr = _qtyError(l);
      if (qtyErr != null) { _showSnack(qtyErr, color: AppColors.negative); return false; }
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final deliverableLines = _lines.where((l) => l.deliveryQty > 0).toList();
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (var i = 0; i < deliverableLines.length; i++) {
        final l = deliverableLines[i];
        final lineSerial = i + 1;
        if (l.isBatchTracked) {
          for (final b in l.batchCandidates.where((b) => b.allocatedQty > 0)) {
            batches.add({
              'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate,
              'manufacturing_date': b.manufacturingDate,
              'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty,
            });
          }
        } else if (l.isSerialTracked) {
          for (final s in l.serialCandidates.where((s) => s.selected)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
          }
        }
      }

      final header = {
        'client_id':              session.clientId,
        'company_id':             session.companyId,
        'delivery_no':            _deliveryNo,
        'delivery_date':          _fmtDate(_deliveryDate),
        'invoice_no':             _invoiceNo,
        'invoice_date':           _invoiceDate,
        'ship_to_location_id':    _shipToLocationId,
        'ship_to_location_name':  _shipToLocationNameCtrl.text.trim(),
        'ship_to_address_line1':  _shipToAddressLine1Ctrl.text.trim(),
        'ship_to_address_line2':  _shipToAddressLine2Ctrl.text.trim(),
        'ship_to_city_id':        _shipToCityId,
        'ship_to_contact_person': _shipToContactPersonCtrl.text.trim(),
        'ship_to_contact_phone':  _shipToContactPhoneCtrl.text.trim(),
        'received_by_name':       _receivedByNameCtrl.text.trim(),
        'reason':                 _reason ?? '',
        'remarks':                _remarksCtrl.text.trim(),
      };
      final lines = deliverableLines.asMap().entries.map((e) => {
        'serial_no':             e.key + 1,
        'invoice_line_serial':   e.value.invoiceLineSerial,
        'product_id':            e.value.productId,
        'barcode':               e.value.barcode ?? '',
        'uom_id':                e.value.uomId,
        'uom_conversion_factor': e.value.uomConversionFactor,
        'qty_pack':              e.value.qtyPack,
        'qty_loose':             e.value.qtyLoose,
        'base_qty':              e.value.deliveryQty,
      }).toList();
      final transport = (_vehicleNoCtrl.text.trim().isEmpty &&
              _transporterNameCtrl.text.trim().isEmpty &&
              _driverNameCtrl.text.trim().isEmpty &&
              _driverPhoneCtrl.text.trim().isEmpty)
          ? null
          : {
              'vehicle_no':       _vehicleNoCtrl.text.trim(),
              'transporter_name': _transporterNameCtrl.text.trim(),
              'driver_name':      _driverNameCtrl.text.trim(),
              'driver_phone':     _driverPhoneCtrl.text.trim(),
            };

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'SALES_DELIVERY',
          documentId: localId,
          endpoint: '/rpc/fn_save_sales_delivery',
          payload: {'p_header': header, 'p_lines': lines, 'p_batches': batches, 'p_serials': serials, 'p_transport': transport, 'p_user_id': session.userId},
        );
        await _ds.cacheDeliveryLocally(effectiveDeliveryNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() { _deliveryNo = localId; _saving = false; });
          _showSnack('Saved offline as $localId — will sync when online, then wait for Pending Approvals to post.', color: AppColors.secondary);
        }
        return true;
      }

      final deliveryNo = await _ds.save(header: header, lines: lines, batches: batches, serials: serials, transport: transport, userId: session.userId);
      if (mounted) {
        setState(() { _deliveryNo = deliveryNo; _saving = false; });
        _showSnack('Sales Delivery $deliveryNo saved.', color: AppColors.positive);
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

  Future<void> _approveDelivery() async {
    final session = ref.read(sessionProvider)!;
    // Approve is always online-only — it posts real stock/GL under a live
    // row-lock only the central database can serialize across devices. If
    // offline, the most this action can do is Save (queued); the actual
    // approval is deferred to whoever reviews the Pending Approvals screen
    // once this device reconnects.
    if (session.offlineMode) {
      if (_deliveryNo == null) {
        final saved = await _saveDraft();
        if (saved && mounted) {
          _showSnack('Saved offline — approval requires an online connection. Use Pending Approvals once this syncs.', color: AppColors.secondary);
        }
      } else {
        _showSnack('Approval requires an online connection.', color: AppColors.negative);
      }
      return;
    }
    if (_deliveryNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Sales Delivery'),
        content: const Text('Once approved, stock will be dispatched and a Cost of Sales entry will be posted to Finance. '
            'This delivery can no longer be edited. Continue?'),
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
        deliveryNo: _deliveryNo!, deliveryDate: _fmtDate(_deliveryDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Delivery $_deliveryNo approved.', color: AppColors.positive);
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
        'delivery_no':            _deliveryNo ?? '',
        'delivery_date':          _displayDate(_deliveryDate),
        'status':                 _status,
        'invoice_no':             _invoiceNo ?? '',
        'invoice_date':           _invoiceDate ?? '',
        'customer_name':          _customerDisplay ?? '',
        'location_name':          _locationName ?? '',
        'ship_to_location_name':  _shipToLocationNameCtrl.text,
        'ship_to_address_line1':  _shipToAddressLine1Ctrl.text,
        'ship_to_address_line2':  _shipToAddressLine2Ctrl.text,
        'ship_to_contact_person': _shipToContactPersonCtrl.text,
        'ship_to_contact_phone':  _shipToContactPhoneCtrl.text,
        'received_by_name':       _receivedByNameCtrl.text,
        'vehicle_no':             _vehicleNoCtrl.text,
        'transporter_name':       _transporterNameCtrl.text,
        'driver_name':            _driverNameCtrl.text,
        'driver_phone':           _driverPhoneCtrl.text,
        'reason':                 _reason ?? '',
        'remarks':                _remarksCtrl.text,
        'signatures': {
          'prepared_by':   _resolveUserName(_createdByUserId) ?? '',
          'authorised_by': _resolveUserName(_approvedByUserId) ?? '',
        },
      },
      'lines': _lines.where((l) => l.deliveryQty > 0).map((l) => {
        'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
        'barcode':      l.barcode ?? '',
        'uom_name':     l.uomLabel ?? '',
        'qty_pack':     l.qtyPack,
        'qty_loose':    l.qtyLoose,
        'base_qty':     l.deliveryQty,
      }).toList(),
      'totals': {},
    };
  }

  Future<void> _printDelivery() async {
    if (_deliveryNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('SALES_DELIVERY').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_deliveryNo.pdf');
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
      onPressed: _printing ? null : _printDelivery,
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
    // No future dates — hard client-side guard mirroring the server's own
    // unconditional FUTURE_DATE_NOT_ALLOWED check at Approve.
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime.now());
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
                  if (_deliveryNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_deliveryNo != null) _buildPrintButton(),
                      if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_deliveryNo != null) _buildPrintButton(),
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
                      _buildShipToCard(locked, isMobile),
                      const SizedBox(height: 16),
                      _buildTransportCard(locked, isMobile),
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
        Text(_deliveryNo != null ? 'Sales Delivery · $_deliveryNo' : 'New Sales Delivery',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        _status == 'APPROVED'
            ? _statusChip(_status)
            : Text(_deliveryNo != null ? 'Draft' : 'Unsaved draft',
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
      onPressed: _approving ? null : _approveDelivery,
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
          final loc = i['location'] as Map<String, dynamic>?;
          final pending = (i['pending_qty'] as num?)?.toStringAsFixed(2) ?? '';
          return '${i['invoice_no']} — ${c != null ? '[${c['account_code']}] ${c['account_name']}' : ''}'
              '${loc != null ? ' · ${loc['location_name']}' : ''} · Pending $pending';
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
    final deliveryNoField = SakalFieldCard.readOnly(label: 'Delivery No', value: _deliveryNo ?? '(auto on save)');
    final deliveryDateField = SakalFieldCard(
      label: 'Delivery Date', required: true, editable: !locked,
      child: InkWell(
        onTap: locked ? null : () => _pickDate(_deliveryDate, (d) => setState(() => _deliveryDate = d)),
        child: Row(children: [
          Expanded(child: Text(_displayDate(_deliveryDate), style: style)),
          Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary),
        ]),
      ),
    );
    final customerField = SakalFieldCard.readOnly(label: 'Customer', value: _customerDisplay ?? '—');
    // Dispatch location is always as-per-invoice — displayed, never editable.
    final locationField = SakalFieldCard.readOnly(label: 'Dispatch Location', value: _locationName ?? '—');
    final receivedByField = SakalFieldCard(
      label: 'Received By', editable: !locked,
      child: TextFormField(
        controller: _receivedByNameCtrl, enabled: !locked, decoration: bare, style: style,
      ),
    );
    final reasonField = SakalFieldCard(
      label: 'Reason', editable: !locked,
      child: TextFormField(
        initialValue: _reason,
        enabled: !locked, decoration: bare, style: style,
        onChanged: (v) => _reason = v,
      ),
    );
    final remarksField = SakalFieldCard(
      label: 'Remarks', editable: !locked,
      child: TextFormField(
        controller: _remarksCtrl, enabled: !locked, decoration: bare, style: style,
      ),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SakalFieldRow(isMobile: isMobile, children: [invoiceField, deliveryNoField, deliveryDateField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [customerField, locationField, receivedByField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [reasonField, remarksField]),
        ]),
      ),
    );
  }

  // ── Ship-To card ──────────────────────────────────────────────────────────

  Widget _buildShipToCard(bool locked, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final pickerField = SakalFieldCard(
      label: 'Saved Delivery Location', editable: !locked,
      child: DropdownButtonFormField<String?>(
        initialValue: _shipToLocationId,
        isExpanded: true, isDense: true, itemHeight: null,
        decoration: bare, style: style,
        items: [
          const DropdownMenuItem(value: null, child: Text('— Type address manually —')),
          ..._customerDeliveryLocations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))),
        ],
        onChanged: locked ? null : (v) {
          final loc = _customerDeliveryLocations.firstWhereOrNull((l) => l['id'] == v);
          if (loc != null) _applyShipToLocation(loc);
        },
      ),
    );
    final addr1Field = SakalFieldCard(
      label: 'Address Line 1', editable: !locked,
      child: TextFormField(controller: _shipToAddressLine1Ctrl, enabled: !locked, decoration: bare, style: style),
    );
    final addr2Field = SakalFieldCard(
      label: 'Address Line 2', editable: !locked,
      child: TextFormField(controller: _shipToAddressLine2Ctrl, enabled: !locked, decoration: bare, style: style),
    );
    final contactPersonField = SakalFieldCard(
      label: 'Contact Person', editable: !locked,
      child: TextFormField(controller: _shipToContactPersonCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final contactPhoneField = SakalFieldCard(
      label: 'Contact Phone', editable: !locked,
      child: TextFormField(controller: _shipToContactPhoneCtrl, enabled: !locked, decoration: bare, style: style),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ship To', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Defaults to the customer\'s saved delivery address, if one exists — editable per delivery.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [pickerField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [addr1Field, addr2Field]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [contactPersonField, contactPhoneField]),
        ]),
      ),
    );
  }

  // ── Transport Details card (optional) ────────────────────────────────────

  Widget _buildTransportCard(bool locked, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final vehicleField = SakalFieldCard(
      label: 'Vehicle No', editable: !locked,
      child: TextFormField(controller: _vehicleNoCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final transporterField = SakalFieldCard(
      label: 'Transporter', editable: !locked,
      child: TextFormField(controller: _transporterNameCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final driverField = SakalFieldCard(
      label: 'Driver Name', editable: !locked,
      child: TextFormField(controller: _driverNameCtrl, enabled: !locked, decoration: bare, style: style),
    );
    final driverPhoneField = SakalFieldCard(
      label: 'Driver Phone', editable: !locked,
      child: TextFormField(controller: _driverPhoneCtrl, enabled: !locked, decoration: bare, style: style),
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Transport Details', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Optional.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [vehicleField, transporterField]),
          const SizedBox(height: 12),
          SakalFieldRow(isMobile: isMobile, children: [driverField, driverPhoneField]),
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
          const Text('Delivery Lines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Pending quantity is pre-filled — reduce or remove a line you don\'t want to deliver yet.',
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

  Widget _buildLineCard(_SDLineRow row, bool locked, bool showLooseQty, bool isMobile) {
    final isCompact = ref.watch(isCompactDensityProvider);
    const bare  = SakalFieldCard.bareDecoration;
    final style = SakalFieldCard.valueTextStyle(isCompact);

    final unitField = SakalFieldCard.readOnly(label: 'Unit', value: row.uomLabel ?? '—');
    final barcodeField = SakalFieldCard.readOnly(label: 'Barcode', value: (row.barcode?.isNotEmpty ?? false) ? row.barcode! : '—');
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Delivery Qty Pack' : 'Delivery Qty', editable: !locked,
      child: TextFormField(
        controller: row.qtyPackCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: bare, style: style,
        onChanged: (_) { setState(() {}); if (row.isBatchTracked || row.isSerialTracked) _autoAllocateFefo(row); },
      ),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Delivery Qty Loose', editable: !locked,
      child: TextFormField(
        controller: row.qtyLooseCtrl, enabled: !locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: bare, style: style,
        onChanged: (_) { setState(() {}); if (row.isBatchTracked || row.isSerialTracked) _autoAllocateFefo(row); },
      ),
    );

    return SakalLineItemCard(
      title: row.productDisplay.isEmpty ? 'Line' : row.productDisplay,
      subtitle: 'Pending ${row.pendingQty.toStringAsFixed(2)}${row.uomLabel != null ? ' ${row.uomLabel}' : ''}',
      onDelete: locked ? null : () => _removeLine(row),
      fields: [
        SizedBox(width: 70, height: 56, child: unitField),
        SizedBox(width: 130, height: 56, child: barcodeField),
        SizedBox(width: 110, child: qtyPackField),
        if (showLooseQty) SizedBox(width: 110, child: qtyLooseField),
      ],
      body: row.isBatchTracked || row.isSerialTracked
          ? _buildBatchSerialEditor(row, locked, isMobile)
          : const SizedBox.shrink(),
    );
  }

  // ── Batch / Serial picker (per delivery line, FEFO from live stock) ──────

  Widget _buildBatchSerialEditor(_SDLineRow row, bool locked, bool isMobile) {
    final isBatch = row.isBatchTracked;
    final fieldTextStyle = SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider));

    if (!row.candidatesLoaded) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator());
    }

    Widget batchFields() {
      final fields = row.batchCandidates.map((b) => SakalFieldCard(
            label: '${b.batchNo} (avail ${b.availableBalance})'
                '${b.manufacturingDate != null ? ' · mfg ${b.manufacturingDate}' : ''}'
                '${b.expiryDate != null ? ' · exp ${b.expiryDate}' : ''}',
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
      return Wrap(spacing: 10, runSpacing: 10, children: fields.map((f) => SizedBox(width: 240, child: f)).toList());
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
          Text(isBatch ? 'Batches to Deliver (FEFO auto-allocated)' : 'Serial Numbers to Deliver (FEFO auto-allocated)',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch
              ? '${row.batchQtySum.toStringAsFixed(2)} / ${row.deliveryQty.toStringAsFixed(2)}'
              : '${row.selectedSerialCount} / ${row.deliveryQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: (isBatch ? (row.batchQtySum - row.deliveryQty).abs() < 0.0001
                                  : row.selectedSerialCount == row.deliveryQty.round())
                      ? AppColors.positive : AppColors.negative)),
          const Spacer(),
          TextButton.icon(
            onPressed: locked ? null : () => _autoAllocateFefo(row),
            icon: const Icon(Icons.auto_fix_high, size: 14),
            label: const Text('Reset to FEFO', style: TextStyle(fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 8),
        if (isBatch && row.batchCandidates.isEmpty)
          const Text('No stock found for this product at this location.', style: TextStyle(fontSize: 11, color: AppColors.negative))
        else if (!isBatch && row.serialCandidates.isEmpty)
          const Text('No in-stock serial numbers found for this product at this location.', style: TextStyle(fontSize: 11, color: AppColors.negative))
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

  // ── Posted Journal Entries ────────────────────────────────────────────────

  Widget _buildPostedVouchersSection() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Posted Journal Entries', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          ..._postedVouchers.map((v) {
            final lines = _voucherLines[v['trans_no']] ?? const [];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${v['voucher_type_code']} · ${v['trans_no']}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary)),
                const SizedBox(height: 6),
                ...lines.map((l) {
                  final acc = l['account'] as Map<String, dynamic>?;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Expanded(child: Text(acc != null ? '[${acc['account_code']}] ${acc['account_name']}' : '—', style: const TextStyle(fontSize: 12))),
                      SizedBox(width: 50, child: Text(l['trans_nature'] as String? ?? '', style: const TextStyle(fontSize: 12))),
                      SizedBox(width: 90, child: Text(((l['trans_amount'] as num?) ?? 0).toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                    ]),
                  );
                }),
              ]),
            );
          }),
        ]),
      ),
    );
  }
}

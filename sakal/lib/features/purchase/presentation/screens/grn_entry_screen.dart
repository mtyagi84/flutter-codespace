import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/config/master_type_keys.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../domain/repositories/grn_repository.dart';
import '../providers/grn_providers.dart';

// ── UI-state row classes (live editing — not DB models) ──────────────────────

class _GrnBatchRow {
  final TextEditingController batchNoCtrl = TextEditingController();
  DateTime? expiryDate;
  DateTime? manufacturingDate;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');

  double get qtyPack  => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose => double.tryParse(qtyLooseCtrl.text) ?? 0;

  void dispose() { batchNoCtrl.dispose(); qtyPackCtrl.dispose(); qtyLooseCtrl.dispose(); }
}

class _GrnSerialRow {
  final TextEditingController serialCtrl = TextEditingController();
  void dispose() => serialCtrl.dispose();
}

class _GrnLineRow {
  String? productId;
  String  productDisplay = '';
  String  trackingType   = 'NONE'; // NONE / BATCH / SERIAL / BATCH_WITH_EXPIRY
  final TextEditingController barcodeCtrl = TextEditingController();
  String? matchedBarcode; // the exact barcode string that resolved this line's product/UOM
  bool    descExpanded = false;
  final TextEditingController descCtrl = TextEditingController();
  String? uomId;
  bool    convFactorLocked = false;
  final TextEditingController convFactorCtrl  = TextEditingController(text: '1');
  final TextEditingController qtyPackCtrl     = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl    = TextEditingController(text: '0');
  final TextEditingController rateCtrl        = TextEditingController(text: '0');
  final TextEditingController discountPctCtrl = TextEditingController(text: '0');
  String? taxGroupId;
  String? departmentId;
  String? consumptionAreaId;

  // Against-PO traceability — null for a Direct-mode / manually-added line.
  String? sourcePoOrderNo;
  String? sourcePoOrderDate;
  int?    sourcePoLineSerial;

  // Cost-variance warning — allowedCostVariance from rim_products
  // (0 = not configured, check skipped); lastCostPrice from
  // rim_product_location.cost_price at this GRN's location, in base
  // currency (null = no prior stock/cost yet, nothing to compare against).
  double  allowedCostVariance = 0;
  double? lastCostPrice;

  final List<_GrnBatchRow>  batchRows  = [];
  final List<_GrnSerialRow> serialRows = [];

  // Computed by _recompute()
  double baseQty        = 0;
  double grossAmount    = 0;
  double discountAmount = 0;
  double taxableAmount  = 0;
  double taxAmount      = 0;
  double finalAmount    = 0;
  double chargeAmount   = 0;
  double landedAmount   = 0;

  bool get isFromPo => sourcePoOrderNo != null;

  double get qtyPack     => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose    => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get convFactor  => double.tryParse(convFactorCtrl.text) ?? 1;
  double get rate        => double.tryParse(rateCtrl.text) ?? 0;
  double get discountPct => double.tryParse(discountPctCtrl.text) ?? 0;

  double get batchQtySum => batchRows.fold(0.0, (s, b) => s + b.qtyPack * convFactor + b.qtyLoose);

  void dispose() {
    barcodeCtrl.dispose(); descCtrl.dispose(); convFactorCtrl.dispose(); qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose(); rateCtrl.dispose(); discountPctCtrl.dispose();
    for (final b in batchRows) { b.dispose(); }
    for (final s in serialRows) { s.dispose(); }
  }
}

class _GrnChargeRow {
  String  chargeId;
  String  chargeName;
  bool    isTaxable;
  String? taxId;
  String  nature;           // ADD / DEDUCT
  String? glAccountId;
  String  amountOrPercent;  // AMOUNT / PERCENT — locked from master
  String? sourcePoOrderNo;
  String? sourcePoOrderDate;
  final TextEditingController valueCtrl;

  double amount           = 0;
  double taxAmount        = 0;
  double allocationFactor = 0;

  _GrnChargeRow({
    required this.chargeId,
    required this.chargeName,
    required this.isTaxable,
    this.taxId,
    required this.nature,
    this.glAccountId,
    required this.amountOrPercent,
    this.sourcePoOrderNo,
    this.sourcePoOrderDate,
    String initialValue = '0',
  }) : valueCtrl = TextEditingController(text: initialValue);

  double get value => double.tryParse(valueCtrl.text) ?? 0;

  void dispose() => valueCtrl.dispose();
}

// ── Screen ────────────────────────────────────────────────────────────────────

class GrnEntryScreen extends ConsumerStatefulWidget {
  final String? editGrnNo;
  final String? editGrnDate;
  const GrnEntryScreen({super.key, this.editGrnNo, this.editGrnDate});

  @override
  ConsumerState<GrnEntryScreen> createState() => _GrnEntryScreenState();
}

class _GrnEntryScreenState extends ConsumerState<GrnEntryScreen>
    with ScreenPermissionMixin<GrnEntryScreen> {
  // Same key as the list screen — entry screen is not itself a menu item,
  // per the shared ERP navigation pattern (Menu -> List -> Entry).
  @override String get screenName => RouteNames.goodsReceipt;

  GrnRepository get _ds => ref.read(grnRepositoryProvider);

  // ── Header state ─────────────────────────────────────────────────────────
  String?  _grnNo;
  DateTime _grnDate   = DateTime.now();
  String   _status    = 'DRAFT';
  String   _receiptMode = 'DIRECT'; // DIRECT / AGAINST_PO
  String?  _locationId;
  String?  _supplierId;
  String?  _supplierDisplay;
  final _supplierDeliveryNoCtrl = TextEditingController();
  DateTime? _supplierDeliveryDate;
  String?  _grnCurrencyId;
  String?  _grnCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  double   get _rateToBase  => double.tryParse(_rateToBaseCtrl.text) ?? 1;
  double   get _rateToLocal => double.tryParse(_rateToLocalCtrl.text) ?? 1;
  final _billToCtrl  = TextEditingController();
  final _shipToCtrl  = TextEditingController();
  final _remarksCtrl = TextEditingController();

  // ── Lines / Charges ───────────────────────────────────────────────────────
  final List<_GrnLineRow>   _lines   = [];
  final List<_GrnChargeRow> _charges = [];
  final Set<String> _consolidatedPoOrderNos = {};

  // ── Reference data ───────────────────────────────────────────────────────
  List<Map<String, dynamic>> _suppliers    = [];
  List<Map<String, dynamic>> _products     = [];
  List<Map<String, dynamic>> _uoms         = [];
  List<Map<String, dynamic>> _taxGroups    = [];
  List<Map<String, dynamic>> _additionalCharges = [];
  List<Map<String, dynamic>> _departments  = [];
  List<Map<String, dynamic>> _consumptionAreas = [];
  List<Map<String, dynamic>> _locations    = [];
  Map<String, double> _taxGroupRatePct = {};
  Map<String, double> _taxRatePct      = {};
  String _baseCurrency  = '';
  String _localCurrency = '';

  bool    _loading = true;
  String? _error;
  bool    _saving  = false;
  bool    _approving = false;
  bool    _printing = false;
  bool    _consolidating = false;
  String? _actionError;

  // ── Posted journal entries (read-only, APPROVED GRNs only) ──────────────
  String? _postedVoucherNo;
  String? _postedVoucherDate;
  List<Map<String, dynamic>> _voucherLines = [];
  bool _loadingVoucherLines = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _supplierDeliveryNoCtrl.dispose(); _rateToBaseCtrl.dispose(); _rateToLocalCtrl.dispose();
    _billToCtrl.dispose(); _shipToCtrl.dispose(); _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    for (final c in _charges) { c.dispose(); }
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    _locationId = session.locationId;
    try {
      final results = await Future.wait<dynamic>([
        ref.read(accountsProvider.future),
        _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.unit),
        _ds.getTaxGroups(clientId: session.clientId, companyId: session.companyId),
        _ds.getAdditionalCharges(clientId: session.clientId, companyId: session.companyId),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.department),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.consumptionArea),
        ref.read(locationsProvider.future),
        ref.read(baseCurrencyProvider.future),
        ref.read(localCurrencyProvider.future),
      ]);

      final accounts = results[0] as List<Map<String, dynamic>>;
      _suppliers          = accounts.where((a) => a['account_nature'] == 'Supplier').toList();
      _products            = results[1] as List<Map<String, dynamic>>;
      _uoms                = results[2] as List<Map<String, dynamic>>;
      _taxGroups           = results[3] as List<Map<String, dynamic>>;
      _additionalCharges   = results[4] as List<Map<String, dynamic>>;
      _departments         = results[5] as List<Map<String, dynamic>>;
      _consumptionAreas    = results[6] as List<Map<String, dynamic>>;
      _locations           = results[7] as List<Map<String, dynamic>>;
      _baseCurrency        = results[8] as String;
      _localCurrency       = results[9] as String;

      await _loadTaxRates();

      if (widget.editGrnNo != null) {
        await _loadExisting(widget.editGrnNo!, widget.editGrnDate);
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load data: $e'; });
    }
  }

  Future<void> _loadTaxRates() async {
    final today = _fmtDate(DateTime.now());
    final groupIds = _taxGroups.map((g) => g['id'] as String).toList();
    final memberMap = await _ds.getTaxGroupMemberTaxIds(groupIds);
    final chargeTaxIds = _additionalCharges
        .where((c) => c['is_taxable'] == true && c['tax_id'] != null)
        .map((c) => c['tax_id'] as String)
        .toSet();
    final allTaxIds = <String>{...memberMap.values.expand((v) => v), ...chargeTaxIds}.toList();
    _taxRatePct = await _ds.getTaxRatesByIds(taxIds: allTaxIds, asOfDate: today);
    _taxGroupRatePct = {
      for (final entry in memberMap.entries)
        entry.key: entry.value.fold<double>(0, (s, taxId) => s + (_taxRatePct[taxId] ?? 0)),
    };
  }

  Future<void> _loadExisting(String grnNo, [String? grnDate]) async {
    final session = ref.read(sessionProvider)!;
    try {
      final header = await _ds.getHeader(clientId: session.clientId, companyId: session.companyId,
          grnNo: grnNo, grnDate: grnDate);
      if (header == null || !mounted) { setState(() => _loading = false); return; }
      final lines   = await _ds.getLines(clientId: session.clientId, companyId: session.companyId,
          grnNo: grnNo, grnDate: header.grnDate);
      final charges = await _ds.getCharges(clientId: session.clientId, companyId: session.companyId,
          grnNo: grnNo, grnDate: header.grnDate);

      for (final l in _lines) { l.dispose(); }
      for (final c in _charges) { c.dispose(); }
      _lines.clear();
      _charges.clear();
      _consolidatedPoOrderNos.clear();

      for (final l in lines) {
        final row = _GrnLineRow()
          ..productId       = l.productId
          ..productDisplay  = l.productCode != null ? '[${l.productCode}] ${l.productName}' : ''
          ..uomId           = l.uomId
          ..taxGroupId      = l.taxGroupId
          ..departmentId    = l.departmentId
          ..consumptionAreaId = l.consumptionAreaId
          ..sourcePoOrderNo   = l.sourcePoOrderNo
          ..sourcePoOrderDate = l.sourcePoOrderDate
          ..sourcePoLineSerial = l.sourcePoLineSerial;
        row.descCtrl.text        = l.itemDescription ?? '';
        row.convFactorCtrl.text  = l.uomConversionFactor.toString();
        row.qtyPackCtrl.text     = l.qtyPack.toString();
        row.qtyLooseCtrl.text    = l.qtyLoose.toString();
        row.rateCtrl.text        = l.rate.toString();
        row.discountPctCtrl.text = l.discountPercent.toString();
        for (final b in l.batches) {
          final br = _GrnBatchRow()
            ..expiryDate = DateTime.tryParse(b.expiryDate ?? '')
            ..manufacturingDate = DateTime.tryParse(b.manufacturingDate ?? '');
          br.batchNoCtrl.text  = b.batchNo;
          br.qtyPackCtrl.text  = b.qtyPack.toString();
          br.qtyLooseCtrl.text = b.qtyLoose.toString();
          row.batchRows.add(br);
        }
        for (final s in l.serials) {
          final sr = _GrnSerialRow()..serialCtrl.text = s.serialNo;
          row.serialRows.add(sr);
        }
        row.trackingType = l.batches.isNotEmpty
            ? (row.batchRows.any((b) => b.expiryDate != null) ? 'BATCH_WITH_EXPIRY' : 'BATCH')
            : (l.serials.isNotEmpty ? 'SERIAL' : 'NONE');
        if (l.sourcePoOrderNo != null) _consolidatedPoOrderNos.add(l.sourcePoOrderNo!);
        _lines.add(row);
      }

      for (final c in charges) {
        _charges.add(_GrnChargeRow(
          chargeId:        c.chargeId,
          chargeName:      c.chargeName,
          isTaxable:       c.isTaxable,
          taxId:           c.taxId,
          nature:          c.nature,
          glAccountId:     c.glAccountId,
          amountOrPercent: c.amountOrPercent,
          sourcePoOrderNo:   c.sourcePoOrderNo,
          sourcePoOrderDate: c.sourcePoOrderDate,
          initialValue:    (c.amountOrPercent == 'PERCENT' ? c.percent : c.amount)?.toString() ?? '0',
        ));
      }

      if (mounted) {
        setState(() {
          _grnNo            = header.grnNo;
          _grnDate          = DateTime.tryParse(header.grnDate) ?? DateTime.now();
          _status           = header.status;
          _receiptMode      = header.receiptMode;
          _locationId       = header.locationId;
          _supplierId       = header.supplierId;
          _supplierDisplay  = header.supplierName != null ? '[${header.supplierCode}] ${header.supplierName}' : '';
          _supplierDeliveryNoCtrl.text = header.supplierDeliveryNo ?? '';
          _supplierDeliveryDate = header.supplierDeliveryDate != null ? DateTime.tryParse(header.supplierDeliveryDate!) : null;
          _grnCurrencyId    = header.grnCurrencyId;
          _grnCurrencyCode  = header.grnCurrencyCode;
          _rateToBaseCtrl.text  = header.rateToBase.toString();
          _rateToLocalCtrl.text = header.rateToLocal.toString();
          _billToCtrl.text  = header.billTo ?? '';
          _shipToCtrl.text  = header.shipTo ?? '';
          _remarksCtrl.text = header.remarks ?? '';
          _postedVoucherNo   = header.postedVoucherNo;
          _postedVoucherDate = header.postedVoucherDate;
          _loading = false;
        });
      }
      if (_postedVoucherNo != null && _postedVoucherDate != null) {
        unawaited(_loadPostedVoucherLines());
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load GRN: $e'; });
    }
  }

  Future<void> _loadPostedVoucherLines() async {
    if (_postedVoucherNo == null || _postedVoucherDate == null) return;
    setState(() => _loadingVoucherLines = true);
    final session = ref.read(sessionProvider)!;
    try {
      final lines = await _ds.getPostedVoucherLines(
        clientId: session.clientId, companyId: session.companyId,
        voucherNo: _postedVoucherNo!, voucherDate: _postedVoucherDate!,
      );
      if (mounted) setState(() { _voucherLines = lines; _loadingVoucherLines = false; });
    } catch (e) {
      if (mounted) setState(() => _loadingVoucherLines = false);
    }
  }

  // ── Lines / Charges management ───────────────────────────────────────────

  void _addLine() => setState(() => _lines.add(_GrnLineRow()));

  void _removeLine(_GrnLineRow row) => setState(() { row.dispose(); _lines.remove(row); });

  void _addCharge() {
    if (_additionalCharges.isEmpty) return;
    final first = _additionalCharges.first;
    setState(() => _charges.add(_GrnChargeRow(
      chargeId:        first['id'] as String,
      chargeName:      first['charge_name'] as String,
      isTaxable:       first['is_taxable'] as bool? ?? false,
      taxId:           first['tax_id'] as String?,
      nature:          first['nature'] as String? ?? 'ADD',
      glAccountId:     first['default_gl_account_id'] as String?,
      amountOrPercent: first['amount_or_percent'] as String? ?? 'AMOUNT',
      initialValue:    ((first['amount_or_percent'] == 'PERCENT'
          ? first['default_percent'] : first['default_amount']) ?? 0).toString(),
    )));
  }

  void _removeCharge(_GrnChargeRow row) => setState(() { row.dispose(); _charges.remove(row); });

  bool _isDuplicateProduct(String productId, {required _GrnLineRow excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  /// Cost-variance warning (advisory only — never blocks save/approve).
  /// Compares this line's rate, converted to base currency with the
  /// header's own rate_to_base, against the product's last moving-average
  /// cost at this location. Null = nothing to show: either the product has
  /// no allowed_cost_variance configured, or there's no prior cost/stock
  /// yet at this location to compare against.
  double? _costVariancePct(_GrnLineRow row) {
    final lastCost = row.lastCostPrice;
    if (lastCost == null || lastCost <= 0 || row.allowedCostVariance <= 0) return null;
    final newCostBase = row.rate * _rateToBase;
    final pct = ((newCostBase - lastCost).abs() / lastCost) * 100;
    return pct > row.allowedCostVariance ? pct : null;
  }

  Future<void> _onProductSelected(_GrnLineRow row, Map<String, dynamic> product, {bool fromBarcode = false}) async {
    final productId = product['id'] as String;
    if (_isDuplicateProduct(productId, excluding: row)) {
      _showSnack('This product is already on another line — edit that line\'s quantity instead.', color: AppColors.negative);
      return;
    }
    setState(() {
      row.productId      = productId;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.descCtrl.text  = product['product_name'] as String? ?? '';
      row.trackingType   = product['tracking_type'] as String? ?? 'NONE';
      if (!fromBarcode) {
        row.uomId            = product['base_uom_id'] as String?;
        row.convFactorLocked = false;
      }
      row.taxGroupId     = product['purchase_tax_group_id'] as String?;
      row.allowedCostVariance = (product['allowed_cost_variance'] as num? ?? 0).toDouble();
      final cost = (product['last_purchase_cost'] as num?) ?? (product['standard_cost'] as num?) ?? 0;
      row.rateCtrl.text  = cost.toString();
    });
    await _loadLastCostPrice(row, productId);
  }

  /// Fetches this product's moving-average cost at the GRN's location, in
  /// base currency — the baseline the cost-variance warning compares
  /// against. No-op (leaves lastCostPrice null) until a location is picked.
  Future<void> _loadLastCostPrice(_GrnLineRow row, String productId) async {
    if (_locationId == null) return;
    try {
      final cost = await _ds.getProductLastCostPrice(productId: productId, locationId: _locationId!);
      if (mounted) setState(() => row.lastCostPrice = cost);
    } catch (_) { /* advisory only — a failed lookup just skips the warning */ }
  }

  Future<void> _onBarcodeSubmitted(_GrnLineRow row, String rawBarcode) async {
    final barcode = rawBarcode.trim();
    if (barcode.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    Map<String, dynamic>? match;
    try {
      match = await _ds.getProductByBarcode(clientId: session.clientId, companyId: session.companyId, barcode: barcode);
    } on DioException catch (e) {
      if (mounted) _showSnack('Barcode lookup failed: ${_serverError(e)}', color: AppColors.negative);
      return;
    } catch (e) {
      if (mounted) _showSnack('Barcode lookup failed: $e', color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    if (match == null) {
      _showSnack('No product found for barcode "$barcode".', color: AppColors.negative);
      return;
    }
    final matchedProduct = match;
    await _onProductSelected(row, matchedProduct, fromBarcode: true);
    if (mounted && row.productId == matchedProduct['id']) {
      setState(() {
        row.uomId               = matchedProduct['matched_uom_id'] as String? ?? row.uomId;
        row.convFactorCtrl.text = (matchedProduct['matched_uom_conversion_factor'] as num? ?? 1).toString();
        row.convFactorLocked    = true;
        row.matchedBarcode      = barcode;
        row.barcodeCtrl.clear();
      });
    }
  }

  Future<void> _onSupplierSelected(Map<String, dynamic> account) async {
    setState(() {
      _supplierId      = account['id'] as String;
      _supplierDisplay = '[${account['account_code']}] ${account['account_name']}';
    });
    if (_receiptMode == 'AGAINST_PO') return; // currency comes from the consolidated PO(s) instead
    final currRel = account['rim_currencies'];
    final supplierCurrency = currRel is Map ? currRel['currency_id'] as String? : null;
    if (supplierCurrency != null) {
      final match = (await ref.read(currenciesProvider.future))
          .where((c) => c['currency_id'] == supplierCurrency).toList();
      if (match.isNotEmpty && mounted) {
        await _onCurrencySelected(match.first);
      }
    }
  }

  Future<void> _onCurrencySelected(Map<String, dynamic> currency) async {
    setState(() {
      _grnCurrencyId   = currency['id'] as String;
      _grnCurrencyCode = currency['currency_id'] as String;
      _rateToBaseCtrl.text  = '1';
      _rateToLocalCtrl.text = '1';
    });
    await _fetchRates();
  }

  Future<void> _fetchRates() async {
    if (_grnCurrencyCode == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    if (_grnCurrencyCode != _baseCurrency && _baseCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _grnCurrencyCode!, toCurrency: _baseCurrency, rateDate: _fmtDate(_grnDate));
      if (mounted && r != null) setState(() => _rateToBaseCtrl.text = r.toString());
    } else if (mounted) {
      setState(() => _rateToBaseCtrl.text = '1');
    }
    if (_localCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _grnCurrencyCode!, toCurrency: _localCurrency, rateDate: _fmtDate(_grnDate));
      if (mounted && r != null) setState(() => _rateToLocalCtrl.text = r.toString());
    }
  }

  // ── Against-PO consolidation ──────────────────────────────────────────────
  // Supplier -> Currency -> Purchase Order(s), fully chained the instant
  // Receipt Mode switches to AGAINST_PO. Supplier and Currency lock the
  // moment they're set here (see _modeLocked/_supplierCurrencyLocked) —
  // there's deliberately no half-configured resting state, so cancelling at
  // any step rolls the whole pick back to Direct mode.

  Future<void> _onReceiptModeChanged(String newMode) async {
    if (newMode == 'AGAINST_PO') {
      setState(() => _receiptMode = 'AGAINST_PO');
      await _startAgainstPoWizard();
    } else {
      setState(() => _receiptMode = 'DIRECT');
    }
  }

  Future<void> _startAgainstPoWizard() async {
    final session = ref.read(sessionProvider)!;
    List<Map<String, dynamic>> suppliers;
    try {
      suppliers = await _ds.getSuppliersWithOpenPos(clientId: session.clientId, companyId: session.companyId);
    } catch (e) {
      if (mounted) _showSnack('Could not load suppliers with open purchase orders: $e', color: AppColors.negative);
      if (mounted) setState(() => _receiptMode = 'DIRECT');
      return;
    }
    if (suppliers.isEmpty) {
      if (mounted) _showSnack('No suppliers have approved purchase orders pending receipt.', color: AppColors.secondary);
      if (mounted) setState(() => _receiptMode = 'DIRECT');
      return;
    }

    final picked = await _pickSupplierDialog(suppliers);
    if (picked == null) {
      if (mounted) setState(() => _receiptMode = 'DIRECT');
      return;
    }
    setState(() {
      _supplierId      = picked['id'] as String;
      _supplierDisplay = '[${picked['account_code']}] ${picked['account_name']}';
    });

    final proceeded = await _pickCurrencyThenPos(isInitialWizard: true);
    if (!proceeded && mounted) {
      setState(() {
        _receiptMode     = 'DIRECT';
        _supplierId      = null;
        _supplierDisplay = null;
      });
    }
  }

  Future<Map<String, dynamic>?> _pickSupplierDialog(List<Map<String, dynamic>> suppliers) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        final searchCtrl = TextEditingController();
        return StatefulBuilder(builder: (context, setDialogState) {
          final q = searchCtrl.text.trim().toLowerCase();
          final filtered = q.isEmpty ? suppliers : suppliers.where((s) =>
              (s['account_code'] as String? ?? '').toLowerCase().contains(q) ||
              (s['account_name'] as String? ?? '').toLowerCase().contains(q)).toList();
          return AlertDialog(
            title: const Text('Select Supplier'),
            content: SizedBox(
              width: 420,
              height: 420,
              child: Column(children: [
                TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                      hintText: 'Search supplier…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 10),
                Expanded(child: ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = filtered[i];
                    return ListTile(
                      dense: true,
                      title: Text('[${s['account_code']}] ${s['account_name']}', style: const TextStyle(fontSize: 13)),
                      onTap: () => Navigator.of(dialogContext, rootNavigator: true).pop(s),
                    );
                  },
                )),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(null),
                  child: const Text('Cancel')),
            ],
          );
        });
      },
    );
  }

  /// Resolves (or asks for, if the supplier has more than one) the currency
  /// among this supplier's open POs, then opens the PO picker filtered to
  /// it. Returns false if the chain was abandoned at any step, so the
  /// initial wizard knows to roll everything back.
  Future<bool> _pickCurrencyThenPos({required bool isInitialWizard}) async {
    final session = ref.read(sessionProvider)!;
    List<Map<String, dynamic>> openPos;
    try {
      openPos = await _ds.getOpenPurchaseOrdersForSupplier(
          clientId: session.clientId, companyId: session.companyId, supplierId: _supplierId!);
    } catch (e) {
      if (mounted) _showSnack('Could not load open purchase orders: $e', color: AppColors.negative);
      return false;
    }
    if (!isInitialWizard) {
      openPos = openPos.where((po) => !_consolidatedPoOrderNos.contains(po['order_no'] as String)).toList();
    }
    if (openPos.isEmpty) {
      if (mounted) {
        _showSnack(
            isInitialWizard ? 'This supplier has no open purchase orders pending receipt.'
                             : 'No further open purchase orders for this supplier.',
            color: AppColors.secondary);
      }
      return false;
    }

    var ccyId = _grnCurrencyId;
    if (ccyId == null) {
      final byCurrency = <String, String?>{};
      for (final po in openPos) {
        final id = po['po_currency_id'] as String?;
        if (id == null) continue;
        final currency = po['currency'];
        byCurrency[id] = currency is Map ? currency['currency_id'] as String? : null;
      }
      String? ccyCode;
      if (byCurrency.length <= 1) {
        ccyId   = byCurrency.keys.firstOrNull;
        ccyCode = ccyId != null ? byCurrency[ccyId] : null;
      } else {
        if (!mounted) return false;
        final picked = await showDialog<MapEntry<String, String?>>(
          context: context,
          builder: (dialogContext) => SimpleDialog(
            title: const Text('Select Currency'),
            children: byCurrency.entries.map((e) => SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(e),
              child: Text(e.value ?? e.key, style: const TextStyle(fontSize: 14)),
            )).toList(),
          ),
        );
        if (picked == null) return false;
        ccyId   = picked.key;
        ccyCode = picked.value;
      }
      if (ccyId != null) {
        if (mounted) setState(() { _grnCurrencyId = ccyId; _grnCurrencyCode = ccyCode; });
        // Rate defaults from the PO(s) actually consolidated below, not a
        // fresh market lookup — the PO's rate_to_base/rate_to_local is the
        // rate actually agreed with the supplier for this order; the user
        // can still edit it here if today's rate should apply instead.
      }
    }

    final candidates = openPos.where((po) => po['po_currency_id'] == ccyId).toList();
    if (candidates.isEmpty) return false;

    final selected = await _showPoPickerDialog(candidates);
    if (selected == null || selected.isEmpty) return false;
    await _consolidatePos(selected);
    return true;
  }

  /// "Add from PO" button — adds more purchase orders from the already-locked
  /// supplier+currency. Supplier/currency are never re-asked here.
  Future<void> _addMorePos() async {
    if (_supplierId == null) return;
    await _pickCurrencyThenPos(isInitialWizard: false);
  }

  Future<List<Map<String, dynamic>>?> _showPoPickerDialog(List<Map<String, dynamic>> openPos) {
    return showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (dialogContext) {
        final chosen = <String>{};
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Select Purchase Order(s)'),
            content: SizedBox(
              width: 420,
              child: ListView(
                shrinkWrap: true,
                children: openPos.map((po) {
                  final orderNo = po['order_no'] as String;
                  final currency = po['currency'];
                  final ccy = currency is Map ? currency['currency_id'] as String? : null;
                  return CheckboxListTile(
                    value: chosen.contains(orderNo),
                    title: Text(orderNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text('${po['order_date']} · ${ccy ?? ''}', style: const TextStyle(fontSize: 12)),
                    onChanged: (v) => setDialogState(() {
                      if (v == true) { chosen.add(orderNo); } else { chosen.remove(orderNo); }
                    }),
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(null),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: chosen.isEmpty ? null : () => Navigator.of(dialogContext, rootNavigator: true)
                    .pop(openPos.where((po) => chosen.contains(po['order_no'])).toList()),
                child: const Text('Add Selected'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _consolidatePos(List<Map<String, dynamic>> pos) async {
    // Default the GRN's rate to the FIRST consolidated PO's own agreed
    // rate — only on the very first PO added to this GRN, so a later
    // "Add more POs" call never clobbers a rate the user may have already
    // edited. If multiple POs (rarely, in different rates) are picked at
    // once, the first one wins as the default; the user can still edit it.
    if (_consolidatedPoOrderNos.isEmpty && pos.isNotEmpty) {
      final rateToBase  = (pos.first['rate_to_base']  as num? ?? 1).toDouble();
      final rateToLocal = (pos.first['rate_to_local'] as num? ?? 1).toDouble();
      setState(() {
        _rateToBaseCtrl.text  = rateToBase.toString();
        _rateToLocalCtrl.text = rateToLocal.toString();
      });
    }
    setState(() => _consolidating = true);
    final session = ref.read(sessionProvider)!;
    var addedLines = 0;
    try {
      for (final po in pos) {
        final orderNo   = po['order_no'] as String;
        final orderDate = po['order_date'] as String;

        final pendingLines = await _ds.getPendingPoLines(
            clientId: session.clientId, companyId: session.companyId, orderNo: orderNo, orderDate: orderDate,
            excludeGrnNo: _grnNo);
        if (pendingLines.isEmpty) {
          if (mounted) _showSnack('$orderNo has no pending quantity left to receive.', color: AppColors.secondary);
          continue;
        }

        if (_billToCtrl.text.isEmpty || _shipToCtrl.text.isEmpty) {
          setState(() {
            if (_billToCtrl.text.isEmpty) _billToCtrl.text = po['bill_to'] as String? ?? '';
            if (_shipToCtrl.text.isEmpty) _shipToCtrl.text = po['ship_to'] as String? ?? '';
          });
        }

        for (final pl in pendingLines) {
          final product    = pl['product'] as Map<String, dynamic>?;
          final pending    = pl['pending_qty'] as double;
          final convFactor = (pl['uom_conversion_factor'] as num? ?? 1).toDouble();

          final row = _GrnLineRow()
            ..productId          = pl['product_id'] as String
            ..productDisplay     = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
            ..trackingType       = product?['tracking_type'] as String? ?? 'NONE'
            ..uomId              = pl['uom_id'] as String?
            ..convFactorLocked   = true
            ..taxGroupId         = pl['tax_group_id'] as String?
            ..departmentId       = pl['department_id'] as String?
            ..consumptionAreaId  = pl['consumption_area_id'] as String?
            ..sourcePoOrderNo    = orderNo
            ..sourcePoOrderDate  = orderDate
            ..sourcePoLineSerial = pl['serial_no'] as int?
            ..allowedCostVariance = (product?['allowed_cost_variance'] as num? ?? 0).toDouble();
          row.descCtrl.text       = pl['item_description'] as String? ?? '';
          row.convFactorCtrl.text = convFactor.toString();
          unawaited(_loadLastCostPrice(row, row.productId!));
          row.qtyPackCtrl.text    = convFactor > 0 ? (pending / convFactor).toStringAsFixed(4) : pending.toString();
          row.qtyLooseCtrl.text   = '0';
          row.rateCtrl.text       = (pl['rate'] as num? ?? 0).toString();
          row.discountPctCtrl.text = (pl['discount_percent'] as num? ?? 0).toString();
          _lines.add(row);
          addedLines++;
        }

        final poCharges = await _ds.getPoChargeLinesForOrder(
            clientId: session.clientId, companyId: session.companyId, orderNo: orderNo, orderDate: orderDate);
        for (final pc in poCharges) {
          _charges.add(_GrnChargeRow(
            chargeId:        pc['charge_id'] as String,
            chargeName:      pc['charge_name'] as String,
            isTaxable:       pc['is_taxable'] as bool? ?? false,
            taxId:           pc['tax_id'] as String?,
            nature:          pc['nature'] as String? ?? 'ADD',
            glAccountId:     pc['gl_account_id'] as String?,
            amountOrPercent: pc['amount_or_percent'] as String? ?? 'AMOUNT',
            sourcePoOrderNo:   orderNo,
            sourcePoOrderDate: orderDate,
            initialValue: ((pc['amount_or_percent'] == 'PERCENT' ? pc['percent'] : pc['amount']) ?? 0).toString(),
          ));
        }

        _consolidatedPoOrderNos.add(orderNo);
      }
      if (mounted) {
        setState(() {});
        if (addedLines > 0) _showSnack('Added $addedLines line(s) from the selected order(s).', color: AppColors.positive);
      }
    } catch (e) {
      if (mounted) _showSnack('Could not add from PO: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _consolidating = false);
    }
  }

  void _removeConsolidatedPo(String orderNo) {
    setState(() {
      _lines.where((l) => l.sourcePoOrderNo == orderNo).toList().forEach((l) { l.dispose(); _lines.remove(l); });
      _charges.where((c) => c.sourcePoOrderNo == orderNo).toList().forEach((c) { c.dispose(); _charges.remove(c); });
      _consolidatedPoOrderNos.remove(orderNo);
    });
  }

  // ── Batch / Serial management ────────────────────────────────────────────

  void _addBatchRow(_GrnLineRow line) => setState(() => line.batchRows.add(_GrnBatchRow()));
  void _removeBatchRow(_GrnLineRow line, _GrnBatchRow row) => setState(() { row.dispose(); line.batchRows.remove(row); });
  void _addSerialRow(_GrnLineRow line) => setState(() => line.serialRows.add(_GrnSerialRow()));
  void _removeSerialRow(_GrnLineRow line, _GrnSerialRow row) => setState(() { row.dispose(); line.serialRows.remove(row); });

  /// null = OK to save/approve; otherwise the reason it's blocked.
  String? _batchSerialError(_GrnLineRow row) {
    if (row.trackingType == 'BATCH' || row.trackingType == 'BATCH_WITH_EXPIRY') {
      if (row.batchRows.isEmpty) return null; // allowed to leave un-split at draft stage
      if ((row.batchQtySum - row.baseQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} '
            'but the line quantity is ${row.baseQty.toStringAsFixed(2)}.';
      }
      if (row.trackingType == 'BATCH_WITH_EXPIRY' && row.batchRows.any((b) => b.expiryDate == null)) {
        return 'Every batch on "${row.productDisplay}" needs an expiry date.';
      }
    } else if (row.trackingType == 'SERIAL') {
      if (row.serialRows.isEmpty) return null;
      if (row.serialRows.length != row.baseQty.round() || (row.baseQty - row.baseQty.roundToDouble()).abs() > 0.0001) {
        return 'Serial numbers for "${row.productDisplay}" (${row.serialRows.length}) must match the line quantity '
            '(${row.baseQty.toStringAsFixed(0)}).';
      }
      if (row.serialRows.any((s) => s.serialCtrl.text.trim().isEmpty)) {
        return 'Every serial row on "${row.productDisplay}" needs a serial number.';
      }
    }
    return null;
  }

  // ── Computed totals ───────────────────────────────────────────────────────

  void _recompute() {
    double grnValueBeforeCharges = 0;
    for (final l in _lines) {
      l.baseQty        = l.qtyPack * l.convFactor + l.qtyLoose;
      l.grossAmount    = l.baseQty * l.rate;
      l.discountAmount = l.grossAmount * l.discountPct / 100;
      l.taxableAmount  = l.grossAmount - l.discountAmount;
      final ratePct    = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount       = l.taxableAmount * ratePct / 100;
      l.finalAmount     = l.taxableAmount + l.taxAmount;
      grnValueBeforeCharges += l.taxableAmount;
    }

    for (final c in _charges) {
      c.amount = c.amountOrPercent == 'PERCENT'
          ? grnValueBeforeCharges * c.value / 100
          : c.value;
      final chargeRatePct = c.isTaxable && c.taxId != null ? (_taxRatePct[c.taxId] ?? 0) : 0;
      c.taxAmount        = c.amount * chargeRatePct / 100;
      c.allocationFactor = grnValueBeforeCharges > 0 ? c.amount / grnValueBeforeCharges : 0;
    }

    for (final l in _lines) {
      double share = 0;
      for (final c in _charges) {
        final signed = c.nature == 'DEDUCT' ? -c.allocationFactor : c.allocationFactor;
        share += signed * l.taxableAmount;
      }
      l.chargeAmount  = share;
      l.landedAmount  = l.finalAmount + l.chargeAmount;
    }
  }

  double get _grossTotal     => _lines.fold(0.0, (s, l) => s + l.grossAmount);
  double get _discountTotal  => _lines.fold(0.0, (s, l) => s + l.discountAmount);
  double get _itemTaxTotal   => _lines.fold(0.0, (s, l) => s + l.taxAmount);
  double get _chargesTotal   => _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));
  double get _chargeTaxTotal => _charges.fold(0.0, (s, c) => s + c.taxAmount);
  double get _grandTotal     => _lines.fold(0.0, (s, l) => s + l.finalAmount) + _chargesTotal + _chargeTaxTotal;

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_supplierId == null) { _showSnack('Select a supplier.'); return false; }
    if (_grnCurrencyId == null) { _showSnack('Select a currency.'); return false; }
    if (_locationId == null) { _showSnack('Select a location.'); return false; }
    final activeLines = _lines.where((l) => l.productId != null).toList();
    if (activeLines.isEmpty) { _showSnack('Add at least one line item.'); return false; }
    for (final l in activeLines) {
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':             session.clientId,
        'company_id':            session.companyId,
        'location_id':           _locationId,
        'grn_no':                _grnNo ?? '',
        'grn_date':              _fmtDate(_grnDate),
        'supplier_id':           _supplierId,
        'receipt_mode':          _receiptMode,
        'supplier_delivery_no':  _supplierDeliveryNoCtrl.text,
        'supplier_delivery_date': _supplierDeliveryDate != null ? _fmtDate(_supplierDeliveryDate!) : '',
        'grn_currency_id':       _grnCurrencyId,
        'rate_to_base':          _rateToBase,
        'rate_to_local':         _rateToLocal,
        'gross_amount':          _grossTotal,
        'discount_amount':       _discountTotal,
        'charges_amount':        _chargesTotal,
        'item_tax_amount':       _itemTaxTotal,
        'charge_tax_amount':     _chargeTaxTotal,
        'grand_total':           _grandTotal,
        'bill_to':               _billToCtrl.text,
        'ship_to':               _shipToCtrl.text,
        'remarks':               _remarksCtrl.text,
      };

      var serial = 1;
      final lines = <Map<String, dynamic>>[];
      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (final l in activeLines) {
        final lineSerial = serial++;
        lines.add({
          'serial_no':              lineSerial,
          'product_id':             l.productId,
          'source_po_order_no':     l.sourcePoOrderNo ?? '',
          'source_po_order_date':   l.sourcePoOrderDate ?? '',
          'source_po_line_serial':  l.sourcePoLineSerial,
          'item_description':       l.descCtrl.text,
          'uom_id':                 l.uomId,
          'uom_conversion_factor':  l.convFactor,
          'qty_pack':               l.qtyPack,
          'qty_loose':              l.qtyLoose,
          'base_qty':               l.baseQty,
          'rate':                   l.rate,
          'gross_amount':           l.grossAmount,
          'discount_percent':       l.discountPct,
          'discount_amount':        l.discountAmount,
          'tax_group_id':           l.taxGroupId ?? '',
          'tax_amount':             l.taxAmount,
          'final_amount':           l.finalAmount,
          'base_amount':            l.finalAmount * _rateToBase,
          'local_amount':           l.finalAmount * _rateToLocal,
          'charge_amount':          l.chargeAmount,
          'landed_amount':          l.landedAmount,
          'department_id':          l.departmentId ?? '',
          'consumption_area_id':    l.consumptionAreaId ?? '',
          'barcode':                l.matchedBarcode ?? '',
        });
        for (final b in l.batchRows) {
          batches.add({
            'line_serial': lineSerial,
            'batch_no':    b.batchNoCtrl.text,
            'expiry_date': b.expiryDate != null ? _fmtDate(b.expiryDate!) : '',
            'manufacturing_date': b.manufacturingDate != null ? _fmtDate(b.manufacturingDate!) : '',
            'qty_pack':    b.qtyPack,
            'qty_loose':   b.qtyLoose,
            'base_qty':    b.qtyPack * l.convFactor + b.qtyLoose,
          });
        }
        for (final s in l.serialRows) {
          serials.add({'line_serial': lineSerial, 'serial_no': s.serialCtrl.text.trim()});
        }
      }

      var chargeSerial = 1;
      final charges = _charges.map((c) => {
        'serial_no':           chargeSerial++,
        'charge_id':           c.chargeId,
        'charge_name':         c.chargeName,
        'is_taxable':          c.isTaxable,
        'tax_id':              c.taxId ?? '',
        'nature':              c.nature,
        'gl_account_id':       c.glAccountId ?? '',
        'amount_or_percent':   c.amountOrPercent,
        'percent':             c.amountOrPercent == 'PERCENT' ? c.value : null,
        'amount':              c.amount,
        'tax_amount':          c.taxAmount,
        'allocation_factor':   c.allocationFactor,
        'source_po_order_no':  c.sourcePoOrderNo ?? '',
        'source_po_order_date': c.sourcePoOrderDate ?? '',
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'GRN',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_grn',
          payload:      {'p_header': header, 'p_lines': lines, 'p_batches': batches,
              'p_serials': serials, 'p_charges': charges, 'p_user_id': session.userId},
        );
        await _ds.cacheGrnLocally(
          effectiveGrnNo: localId, header: header, lines: lines, batches: batches, serials: serials, charges: charges);
        if (mounted) {
          setState(() { _grnNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final grnNo = await _ds.save(
            header: header, lines: lines, batches: batches, serials: serials, charges: charges, userId: session.userId);
        unawaited(_ds.cacheGrnLocally(
            effectiveGrnNo: grnNo, header: header, lines: lines, batches: batches, serials: serials, charges: charges));
        if (mounted) {
          setState(() { _grnNo = grnNo; _saving = false; });
          _showSnack('Draft saved — $grnNo', color: AppColors.positive);
          return true;
        }
      }
    } on DioException catch (e) {
      if (mounted) setState(() { _saving = false; _actionError = 'Save failed: ${_serverError(e)}'; });
    } catch (e) {
      if (mounted) setState(() { _saving = false; _actionError = 'Unexpected error: $e'; });
    }
    return false;
  }

  // ── Print ─────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    return {
      'company': company,
      'header': {
        'grn_no':                _grnNo ?? '',
        'grn_date':              _displayDate(_grnDate),
        'status':                _status,
        'receipt_mode':          _receiptMode == 'AGAINST_PO' ? 'Against PO' : 'Direct',
        'supplier_name':         _supplierDisplay ?? '',
        'currency_code':         _grnCurrencyCode ?? '',
        'supplier_delivery_no':  _supplierDeliveryNoCtrl.text,
        'bill_to':               _billToCtrl.text,
        'ship_to':               _shipToCtrl.text,
        'remarks':               _remarksCtrl.text,
      },
      'lines': _lines.where((l) => l.productId != null).map((l) {
        final desc = l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay;
        final uomLabel = _uoms.where((u) => u['id'] == l.uomId).map((u) => u['description'] as String).firstOrNull;
        return {
          'product_name': desc,
          'uom_label':    uomLabel ?? '',
          'base_qty':     l.baseQty,
          'rate':         l.rate,
          'final_amount': l.finalAmount,
        };
      }).toList(),
      'charges': _charges.map((c) => {'charge_name': c.chargeName, 'amount': c.amount}).toList(),
      'totals': {
        'gross_amount':    _grossTotal,
        'discount_amount': _discountTotal,
        'item_tax_amount': _itemTaxTotal,
        'charges_amount':  _chargesTotal,
        'grand_total':     _grandTotal,
      },
    };
  }

  Future<void> _printGrn() async {
    if (_grnNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('GRN').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_grnNo.pdf');
    } catch (e) {
      if (mounted) _showSnack('Print failed: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  // ── Approve ───────────────────────────────────────────────────────────────

  String? _validateForApprove() {
    final activeLines = _lines.where((l) => l.productId != null).toList();
    if (activeLines.isEmpty) return 'Add at least one line item before approving.';
    for (final l in activeLines) {
      if (l.baseQty <= 0) return 'Every line needs a quantity greater than zero.';
      if (l.uomId == null) return 'Every line needs a UOM selected.';
      final err = _batchSerialError(l);
      if (err != null) return err;
    }
    return null;
  }

  Future<void> _approveGrn() async {
    final validationError = _validateForApprove();
    if (validationError != null) {
      _showSnack(validationError, color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Goods Receipt'),
        content: const Text('Once approved, stock and cost will be posted and this GRN can no longer be edited. Continue?'),
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

    if (_grnNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }

    final session = ref.read(sessionProvider)!;
    setState(() { _approving = true; _actionError = null; });
    try {
      await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        grnNo: _grnNo!, grnDate: _fmtDate(_grnDate), approvedBy: session.userId);
      // Re-fetch the header for the posted_voucher_no/date fn_approve_grn just
      // assigned, so the Posted Journal Entries section can appear immediately
      // without a full page reload.
      final refreshed = await _ds.getHeader(
        clientId: session.clientId, companyId: session.companyId, grnNo: _grnNo!, grnDate: _fmtDate(_grnDate));
      if (mounted) {
        setState(() {
          _status = 'APPROVED';
          _approving = false;
          _postedVoucherNo   = refreshed?.postedVoucherNo;
          _postedVoucherDate = refreshed?.postedVoucherDate;
        });
        _showSnack('$_grnNo approved.', color: AppColors.positive);
      }
      if (_postedVoucherNo != null && _postedVoucherDate != null) {
        unawaited(_loadPostedVoucherLines());
      }
    } on DioException catch (e) {
      if (mounted) setState(() { _approving = false; _actionError = 'Approve failed: ${_serverError(e)}'; });
    } catch (e) {
      if (mounted) setState(() { _approving = false; _actionError = 'Unexpected error: $e'; });
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final details = data['details'] as String?;
      final message = data['message'] as String?;
      if (details != null && details.isNotEmpty) return details;
      if (message != null && message.isNotEmpty) return message;
    }
    return e.message ?? e.toString();
  }

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
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);

    if (!_loading) _recompute();

    final canSave      = _status == 'DRAFT' && (_grnNo == null ? canAdd : canEdit);
    final showApprove  = _status == 'DRAFT' && !isOffline && canApprove && _grnNo != null;
    final locked       = _status != 'DRAFT';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildTitleBlock(locked),
                  if (_grnNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_grnNo != null) _buildPrintButton(),
                      if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock(locked)),
                  if (_grnNo != null) _buildPrintButton(),
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
                      _buildAdditionalDetails(locked),
                      const SizedBox(height: 20),
                      if (_receiptMode == 'AGAINST_PO') ...[_buildConsolidationSection(locked), const SizedBox(height: 20)],
                      _buildLinesSection(locked, isMobile),
                      const SizedBox(height: 20),
                      _buildChargesSection(locked, isMobile),
                      const SizedBox(height: 12),
                      _buildTotalsBar(),
                      if (_status == 'APPROVED' && _postedVoucherNo != null) ...[
                        const SizedBox(height: 20),
                        _buildPostedVoucherSection(),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock(bool locked) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_grnNo != null ? 'Goods Receipt · $_grnNo' : 'New Goods Receipt',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    if (locked)
      _statusChip(_status)
    else
      Row(children: [
        Text(_grnNo != null ? 'Draft' : 'Unsaved draft',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (_grnNo != null) ...[
          const SizedBox(width: 8),
          PendingSyncBadge(documentType: 'GRN', documentId: _grnNo!),
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
    // Receipt Mode, Supplier and Currency all lock together the instant a
    // supplier is chosen for an Against-PO GRN — picking a supplier there
    // happens via the dedicated wizard (_startAgainstPoWizard), not by
    // typing into the header, and there's no supported way to change any of
    // the three afterward short of abandoning the draft.
    final modeLocked = locked || _supplierId != null;
    final currencyLocked = locked || (_receiptMode == 'AGAINST_PO' && _supplierId != null);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          // Row 1: Receipt Mode | GRN No | GRN Date
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Receipt Mode *'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: _receiptMode,
              items: const [
                DropdownMenuItem(value: 'DIRECT', child: Text('Direct', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'AGAINST_PO', child: Text('Against PO', style: TextStyle(fontSize: 13))),
              ],
              onChanged: modeLocked ? null : (v) => _onReceiptModeChanged(v!),
            ));
            final f2 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'GRN No'),
              child: Text(_grnNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _grnNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f3 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_grnDate, (d) => setState(() => _grnDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'GRN Date *',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                        color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_grnDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    Row(children: [Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]),
                  ])
                : Row(children: [
                    Expanded(flex: 2, child: f1), const SizedBox(width: 12),
                    Expanded(flex: 3, child: f2), const SizedBox(width: 12),
                    Expanded(flex: 3, child: f3),
                  ]);
          }),
          const SizedBox(height: 12),

          // Row 2: Supplier | Location
          Builder(builder: (_) {
            // Against-PO picks its supplier through the dedicated wizard
            // (_startAgainstPoWizard) — the header field is read-only display
            // for that mode, never a free-text search, and locks immediately.
            final f1 = _receiptMode == 'AGAINST_PO'
                ? field(InputDecorator(
                    decoration: dec.copyWith(labelText: 'Supplier *'),
                    child: Text(_supplierDisplay?.isNotEmpty == true ? _supplierDisplay! : '(select via wizard)',
                        style: TextStyle(fontSize: 13,
                            color: _supplierDisplay?.isNotEmpty == true ? AppColors.textPrimary : AppColors.textDisabled)),
                  ))
                : _searchField<Map<String, dynamic>>(
                    height: fh,
                    options: _suppliers,
                    initialText: _supplierDisplay ?? '',
                    locked: locked,
                    decoration: dec.copyWith(labelText: 'Supplier *'),
                    displayString: (a) => '[${a['account_code']}] ${a['account_name']}',
                    matches: (a, q) => (a['account_code'] as String? ?? '').toLowerCase().contains(q) ||
                        (a['account_name'] as String? ?? '').toLowerCase().contains(q),
                    onSelected: (a) => _onSupplierSelected(a),
                    onCleared: () => setState(() { _supplierId = null; _supplierDisplay = ''; }),
                  );
            final f2 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Location *'),
              initialValue: _locationId,
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              items: _locations.map((l) => DropdownMenuItem(
                  value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() => _locationId = v),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f2),
                  ])
                : Row(children: [Expanded(flex: 3, child: f1), const SizedBox(width: 12), Expanded(flex: 2, child: f2)]);
          }),
          const SizedBox(height: 12),

          // Row 3: Currency | Rate to Base | Rate to Local
          Builder(builder: (_) {
            final currAsync = ref.watch(currenciesProvider);
            return currAsync.when(
              data: (currencies) {
                final f1 = field(DropdownButtonFormField<String>(
                  decoration: dec.copyWith(labelText: 'Currency *'),
                  initialValue: _grnCurrencyId,
                  isExpanded: true,
                  isDense: true,
                  itemHeight: null,
                  items: currencies.map((c) => DropdownMenuItem(
                      value: c['id'] as String,
                      child: Text('${c['currency_id']} — ${c['currency_name']}',
                          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: currencyLocked ? null : (v) {
                    final c = currencies.where((x) => x['id'] == v).firstOrNull;
                    if (c != null) _onCurrencySelected(c);
                  },
                ));
                final f2 = field(TextFormField(
                  controller: _rateToBaseCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: 'Rate → Base ($_baseCurrency)'),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() {}),
                ));
                final f3 = field(TextFormField(
                  controller: _rateToLocalCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: 'Rate → Local ($_localCurrency)'),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() {}),
                ));
                return isMobile
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                        Row(children: [Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]),
                      ])
                    : Row(children: [
                        Expanded(flex: 2, child: f1), const SizedBox(width: 12),
                        Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                        Expanded(flex: 2, child: f3),
                      ]);
              },
              loading: () => const SizedBox(height: fh, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => Text('Could not load currencies: $e'),
            );
          }),
          const SizedBox(height: 12),

          // Row 4: Supplier Delivery No | Supplier Delivery Date
          Row(children: [
            Expanded(child: field(TextFormField(
              controller: _supplierDeliveryNoCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Supplier Delivery No'),
              style: const TextStyle(fontSize: 13),
            ))),
            const SizedBox(width: 12),
            Expanded(child: field(_dateField('Supplier Delivery Date', _supplierDeliveryDate, locked,
                (d) => setState(() => _supplierDeliveryDate = d)))),
          ]),
        ]),
      ),
    );
  }

  Widget _buildAdditionalDetails(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: ExpansionTile(
        title: const Text('Additional Details', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: const Text('Bill To / Ship To / Remarks', style: TextStyle(fontSize: 11)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(children: [
              TextFormField(controller: _billToCtrl, enabled: !locked, maxLines: 2,
                  decoration: dec.copyWith(labelText: 'Bill To')),
              const SizedBox(height: 10),
              TextFormField(controller: _shipToCtrl, enabled: !locked, maxLines: 2,
                  decoration: dec.copyWith(labelText: 'Ship To')),
              const SizedBox(height: 10),
              TextFormField(controller: _remarksCtrl, enabled: !locked, maxLines: 2,
                  decoration: dec.copyWith(labelText: 'Remarks')),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _dateField(String label, DateTime? value, bool locked, ValueChanged<DateTime> onPicked) => InkWell(
    onTap: locked ? null : () => _pickDate(value, onPicked),
    child: InputDecorator(
      decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), labelText: label,
          suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
      child: Text(_displayDate(value),
          style: TextStyle(fontSize: 13, color: value != null ? AppColors.textPrimary : AppColors.textDisabled)),
    ),
  );

  // ── Against-PO consolidation section ─────────────────────────────────────

  Widget _buildConsolidationSection(bool locked) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        const Text('Purchase Orders', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const Spacer(),
        if (!locked)
          TextButton.icon(
            onPressed: _consolidating ? null : _addMorePos,
            icon: _consolidating
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add, size: 16),
            label: const Text('Add from PO'),
          ),
      ]),
      const SizedBox(height: 8),
      if (_consolidatedPoOrderNos.isEmpty)
        const Padding(padding: EdgeInsets.all(16), child: Text('No purchase orders consolidated yet.'))
      else
        Wrap(spacing: 8, runSpacing: 8, children: _consolidatedPoOrderNos.map((orderNo) => Chip(
          label: Text(orderNo, style: const TextStyle(fontSize: 12)),
          onDeleted: locked ? null : () => _removeConsolidatedPo(orderNo),
        )).toList()),
    ],
  );

  // ── Lines section ────────────────────────────────────────────────────────

  Widget _buildLinesSection(bool locked, bool isMobile) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        const Text('Line Items', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const Spacer(),
        if (!locked) TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Item')),
      ]),
      const SizedBox(height: 8),
      if (_lines.isEmpty)
        const Padding(padding: EdgeInsets.all(16), child: Text('No line items yet.')),
      ..._lines.map((row) => _buildLineCard(row, locked, isMobile)),
    ],
  );

  Widget _buildLineCard(_GrnLineRow row, bool locked, bool isMobile) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    final showLooseQty = (ref.read(sessionProvider)?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
    final showBarcode = !row.isFromPo && (ref.read(sessionProvider)?.enableBarcode ?? false);
    final rowLocked = locked; // product/uom stay non-editable for PO-derived lines regardless of status

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (row.isFromPo) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
                child: Text('PO: ${row.sourcePoOrderNo}', style: const TextStyle(fontSize: 11, color: AppColors.primary)),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(row.productDisplay, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
            ] else ...[
              if (showBarcode) ...[
                SizedBox(width: 140, height: 48, child: TextFormField(
                  controller: row.barcodeCtrl, enabled: !locked,
                  decoration: dec.copyWith(labelText: 'Scan/Enter Barcode'),
                  style: const TextStyle(fontSize: 12),
                  onFieldSubmitted: (v) => _onBarcodeSubmitted(row, v),
                )),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: _searchField<Map<String, dynamic>>(
                  height: 48,
                  options: _products,
                  initialText: row.productDisplay,
                  locked: locked,
                  decoration: dec.copyWith(labelText: 'Product *'),
                  displayString: (p) => '[${p['product_code']}] ${p['product_name']}',
                  matches: (p, q) => (p['product_code'] as String? ?? '').toLowerCase().contains(q) ||
                      (p['product_name'] as String? ?? '').toLowerCase().contains(q),
                  onSelected: (p) => _onProductSelected(row, p),
                  onCleared: () => setState(() { row.productId = null; row.productDisplay = ''; row.convFactorLocked = false; }),
                ),
              ),
            ],
            if (!locked) IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
              onPressed: () => _removeLine(row),
            ),
          ]),
          const SizedBox(height: 6),
          if (!row.isFromPo) ...[
            InkWell(
              onTap: () => setState(() => row.descExpanded = !row.descExpanded),
              child: Row(children: [
                Icon(row.descExpanded ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: AppColors.textSecondary),
                Expanded(child: Text(
                  row.descExpanded ? 'Item Description' : (row.descCtrl.text.isEmpty ? 'Item Description' : row.descCtrl.text),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                )),
              ]),
            ),
            if (row.descExpanded) ...[
              const SizedBox(height: 4),
              TextFormField(controller: row.descCtrl, enabled: !locked,
                  decoration: dec.copyWith(labelText: 'Item Description'), style: const TextStyle(fontSize: 13)),
            ],
            const SizedBox(height: 8),
          ],
          Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 140, child: DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'UOM'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.uomId,
              items: _uoms.map((u) => DropdownMenuItem(value: u['id'] as String,
                  child: Text(u['description'] as String, style: const TextStyle(fontSize: 12)))).toList(),
              onChanged: (rowLocked || row.isFromPo || row.convFactorLocked) ? null : (v) => setState(() => row.uomId = v),
            )),
            SizedBox(width: 90, child: TextFormField(controller: row.convFactorCtrl,
                enabled: !locked && !row.convFactorLocked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Conv. Factor',
                    suffixIcon: row.convFactorLocked
                        ? const Icon(Icons.lock_outline, size: 14, color: AppColors.textSecondary)
                        : null),
                style: const TextStyle(fontSize: 12),
                onChanged: (_) => setState(() {}))),
            SizedBox(width: 90, child: TextFormField(controller: row.qtyPackCtrl, enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: showLooseQty ? 'Qty Pack' : 'Quantity'), style: const TextStyle(fontSize: 12),
                onChanged: (_) => setState(() {}))),
            if (showLooseQty)
              SizedBox(width: 90, child: TextFormField(controller: row.qtyLooseCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: 'Qty Loose'), style: const TextStyle(fontSize: 12),
                  onChanged: (_) => setState(() {}))),
            Builder(builder: (_) {
              final variancePct = _costVariancePct(row);
              final breached    = variancePct != null;
              final warningIcon = breached ? Tooltip(
                message: 'Last cost: ${row.lastCostPrice!.toStringAsFixed(4)} $_baseCurrency\n'
                    '${variancePct.toStringAsFixed(1)}% variance (allowed ${row.allowedCostVariance.toStringAsFixed(1)}%)',
                child: const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.negative),
              ) : null;
              return SizedBox(width: 100, child: TextFormField(controller: row.rateCtrl, enabled: !locked && !row.isFromPo,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(
                      labelText: 'Rate',
                      labelStyle: breached ? const TextStyle(color: AppColors.negative) : null,
                      enabledBorder: breached
                          ? const OutlineInputBorder(borderSide: BorderSide(color: AppColors.negative))
                          : null,
                      suffixIcon: breached
                          ? warningIcon
                          : (row.isFromPo ? const Icon(Icons.lock_outline, size: 14, color: AppColors.textSecondary) : null)),
                  style: TextStyle(fontSize: 12, color: breached ? AppColors.negative : null),
                  onChanged: (_) => setState(() {})));
            }),
            SizedBox(width: 90, child: TextFormField(controller: row.discountPctCtrl, enabled: !locked && !row.isFromPo,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Discount %'), style: const TextStyle(fontSize: 12),
                onChanged: (_) => setState(() {}))),
            SizedBox(width: 170, child: DropdownButtonFormField<String?>(
              decoration: dec.copyWith(labelText: 'Tax Group'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.taxGroupId,
              items: [
                const DropdownMenuItem(value: null, child: Text('No Tax', style: TextStyle(fontSize: 12))),
                ..._taxGroups.map((g) => DropdownMenuItem(value: g['id'] as String,
                    child: Text(g['group_name'] as String, style: const TextStyle(fontSize: 12)))),
              ],
              onChanged: (locked || row.isFromPo) ? null : (v) => setState(() => row.taxGroupId = v),
            )),
            SizedBox(width: 170, child: DropdownButtonFormField<String?>(
              decoration: dec.copyWith(labelText: 'Department'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.departmentId,
              items: [
                const DropdownMenuItem(value: null, child: Text('—', style: TextStyle(fontSize: 12))),
                ..._departments.map((d) => DropdownMenuItem(value: d['id'] as String,
                    child: Text(d['description'] as String, style: const TextStyle(fontSize: 12)))),
              ],
              onChanged: locked ? null : (v) => setState(() => row.departmentId = v),
            )),
            SizedBox(width: 170, child: DropdownButtonFormField<String?>(
              decoration: dec.copyWith(labelText: 'Consumption Area'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.consumptionAreaId,
              items: [
                const DropdownMenuItem(value: null, child: Text('—', style: TextStyle(fontSize: 12))),
                ..._consumptionAreas.map((d) => DropdownMenuItem(value: d['id'] as String,
                    child: Text(d['description'] as String, style: const TextStyle(fontSize: 12)))),
              ],
              onChanged: locked ? null : (v) => setState(() => row.consumptionAreaId = v),
            )),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 16, runSpacing: 4, children: [
            _amountTag('Gross', row.grossAmount),
            _amountTag('Discount', row.discountAmount),
            _amountTag('Tax', row.taxAmount),
            _amountTag('Final', row.finalAmount, bold: true),
            _amountTag('+ Charges', row.chargeAmount),
            _amountTag('Landed', row.landedAmount, bold: true, color: AppColors.secondary),
          ]),
          if (row.trackingType != 'NONE') ...[
            const SizedBox(height: 8),
            _buildBatchSerialEditor(row, locked),
          ],
        ]),
      ),
    );
  }

  Widget _buildBatchSerialEditor(_GrnLineRow row, bool locked) {
    final isBatch = row.trackingType == 'BATCH' || row.trackingType == 'BATCH_WITH_EXPIRY';
    final withExpiry = row.trackingType == 'BATCH_WITH_EXPIRY';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(isBatch ? 'Batches' : 'Serial Numbers',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(width: 10),
          Text(isBatch
              ? '${row.batchQtySum.toStringAsFixed(2)} / ${row.baseQty.toStringAsFixed(2)}'
              : '${row.serialRows.length} / ${row.baseQty.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11,
                  color: (isBatch ? (row.batchQtySum - row.baseQty).abs() < 0.0001 : row.serialRows.length == row.baseQty.round())
                      ? AppColors.positive : AppColors.negative)),
          const Spacer(),
          if (!locked) TextButton.icon(
            onPressed: () => isBatch ? _addBatchRow(row) : _addSerialRow(row),
            icon: const Icon(Icons.add, size: 14),
            label: Text(isBatch ? 'Add Batch' : 'Add Serial', style: const TextStyle(fontSize: 12)),
          ),
        ]),
        if (isBatch)
          ...row.batchRows.map((b) => _buildBatchRow(row, b, withExpiry, locked))
        else
          ...row.serialRows.map((s) => _buildSerialRow(row, s, locked)),
      ]),
    );
  }

  Widget _buildBatchRow(_GrnLineRow line, _GrnBatchRow b, bool withExpiry, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(width: 140, child: TextFormField(controller: b.batchNoCtrl, enabled: !locked,
            decoration: dec.copyWith(labelText: 'Batch No'), style: const TextStyle(fontSize: 12))),
        if (withExpiry) SizedBox(width: 150, child: InkWell(
          onTap: locked ? null : () => _pickDate(b.expiryDate, (d) => setState(() => b.expiryDate = d)),
          child: InputDecorator(
            decoration: dec.copyWith(labelText: 'Expiry Date'),
            child: Text(_displayDate(b.expiryDate), style: const TextStyle(fontSize: 12)),
          ),
        )),
        SizedBox(width: 150, child: InkWell(
          onTap: locked ? null : () => _pickDate(b.manufacturingDate, (d) => setState(() => b.manufacturingDate = d)),
          child: InputDecorator(
            decoration: dec.copyWith(labelText: 'Manufacturing Date'),
            child: Text(_displayDate(b.manufacturingDate), style: const TextStyle(fontSize: 12)),
          ),
        )),
        SizedBox(width: 90, child: TextFormField(controller: b.qtyPackCtrl, enabled: !locked,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: dec.copyWith(labelText: 'Qty Pack'), style: const TextStyle(fontSize: 12),
            onChanged: (_) => setState(() {}))),
        SizedBox(width: 90, child: TextFormField(controller: b.qtyLooseCtrl, enabled: !locked,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: dec.copyWith(labelText: 'Qty Loose'), style: const TextStyle(fontSize: 12),
            onChanged: (_) => setState(() {}))),
        if (!locked) IconButton(
          icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative),
          onPressed: () => _removeBatchRow(line, b),
        ),
      ]),
    );
  }

  Widget _buildSerialRow(_GrnLineRow line, _GrnSerialRow s, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        SizedBox(width: 200, child: TextFormField(controller: s.serialCtrl, enabled: !locked,
            decoration: dec.copyWith(labelText: 'Serial No'), style: const TextStyle(fontSize: 12))),
        if (!locked) IconButton(
          icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative),
          onPressed: () => _removeSerialRow(line, s),
        ),
      ]),
    );
  }

  Widget _amountTag(String label, double value, {bool bold = false, Color? color}) => Text(
    '$label: ${value.toStringAsFixed(2)}',
    style: TextStyle(fontSize: 11, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color ?? AppColors.textSecondary),
  );

  // ── Charges section ──────────────────────────────────────────────────────

  Widget _buildChargesSection(bool locked, bool isMobile) {
    const btnW = 32.0;
    Widget colHeader(String label, {TextAlign align = TextAlign.left}) => Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Text(label, textAlign: align,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Additional Charges', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const Spacer(),
          if (!locked && _additionalCharges.isNotEmpty)
            TextButton.icon(onPressed: _addCharge, icon: const Icon(Icons.add, size: 16), label: const Text('Add Charge')),
        ]),
        const SizedBox(height: 8),
        if (_charges.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No additional charges (freight, loading, handling…).'))
        else if (isMobile)
          ..._charges.map((row) => _buildChargeCardMobile(row, locked))
        else ...[
          Row(children: [
            Expanded(flex: 3, child: colHeader('Charge Type')),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: colHeader('Amount / %', align: TextAlign.right)),
            const SizedBox(width: 12),
            const SizedBox(width: 72),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: colHeader('Amount', align: TextAlign.right)),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: colHeader('Tax', align: TextAlign.right)),
            if (!locked) const SizedBox(width: btnW + 8),
          ]),
          ..._charges.map((row) => _buildChargeCard(row, locked)),
        ],
      ],
    );
  }

  Widget _buildChargeCard(_GrnChargeRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget rightText(String text, {Color? color, bool bold = false}) => Text(text,
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 13, color: color ?? AppColors.textPrimary,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(flex: 3, child: SizedBox(height: 44, child: row.sourcePoOrderNo != null
            ? InputDecorator(
                decoration: dec,
                child: Text('${row.chargeName}  (PO: ${row.sourcePoOrderNo})',
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              )
            : DropdownButtonFormField<String>(
                decoration: dec,
                isExpanded: true,
                isDense: true,
                itemHeight: null,
                initialValue: row.chargeId,
                items: _additionalCharges.map((c) => DropdownMenuItem(value: c['id'] as String,
                    child: Text(c['charge_name'] as String, style: const TextStyle(fontSize: 13)))).toList(),
                onChanged: locked ? null : (v) {
                  final c = _additionalCharges.where((x) => x['id'] == v).firstOrNull;
                  if (c == null) return;
                  setState(() {
                    row.chargeId        = c['id'] as String;
                    row.chargeName      = c['charge_name'] as String;
                    row.isTaxable       = c['is_taxable'] as bool? ?? false;
                    row.taxId           = c['tax_id'] as String?;
                    row.nature          = c['nature'] as String? ?? 'ADD';
                    row.glAccountId     = c['default_gl_account_id'] as String?;
                    row.amountOrPercent = c['amount_or_percent'] as String? ?? 'AMOUNT';
                  });
                },
              ))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: SizedBox(height: 44, child: TextFormField(
          controller: row.valueCtrl, enabled: !locked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: dec.copyWith(hintText: row.amountOrPercent == 'PERCENT' ? '%' : 'Amount'),
          style: const TextStyle(fontSize: 13), onChanged: (_) => setState(() {}),
        ))),
        const SizedBox(width: 12),
        SizedBox(width: 72, child: Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: (row.nature == 'DEDUCT' ? AppColors.negative : AppColors.positive).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(row.nature == 'DEDUCT' ? 'Deduct' : 'Add',
              style: TextStyle(fontSize: 11, color: row.nature == 'DEDUCT' ? AppColors.negative : AppColors.positive)),
        ))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: rightText(row.amount.toStringAsFixed(2))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: rightText(row.isTaxable ? row.taxAmount.toStringAsFixed(2) : '—',
            color: row.isTaxable ? null : AppColors.textDisabled)),
        if (!locked) IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
          onPressed: () => _removeCharge(row),
        ),
      ]),
    );
  }

  Widget _buildChargeCardMobile(_GrnChargeRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (row.sourcePoOrderNo != null)
            SizedBox(width: 200, child: Text('${row.chargeName} (PO: ${row.sourcePoOrderNo})',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)))
          else
            SizedBox(width: 200, child: DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Charge Type'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.chargeId,
              items: _additionalCharges.map((c) => DropdownMenuItem(value: c['id'] as String,
                  child: Text(c['charge_name'] as String, style: const TextStyle(fontSize: 12)))).toList(),
              onChanged: locked ? null : (v) {
                final c = _additionalCharges.where((x) => x['id'] == v).firstOrNull;
                if (c == null) return;
                setState(() {
                  row.chargeId        = c['id'] as String;
                  row.chargeName      = c['charge_name'] as String;
                  row.isTaxable       = c['is_taxable'] as bool? ?? false;
                  row.taxId           = c['tax_id'] as String?;
                  row.nature          = c['nature'] as String? ?? 'ADD';
                  row.glAccountId     = c['default_gl_account_id'] as String?;
                  row.amountOrPercent = c['amount_or_percent'] as String? ?? 'AMOUNT';
                });
              },
            )),
          SizedBox(width: 130, child: TextFormField(controller: row.valueCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: row.amountOrPercent == 'PERCENT' ? 'Percent %' : 'Amount'),
              style: const TextStyle(fontSize: 12), onChanged: (_) => setState(() {}))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (row.nature == 'DEDUCT' ? AppColors.negative : AppColors.positive).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(row.nature == 'DEDUCT' ? 'Deduct' : 'Add',
                style: TextStyle(fontSize: 11, color: row.nature == 'DEDUCT' ? AppColors.negative : AppColors.positive)),
          ),
          _amountTag('Amount', row.amount),
          if (row.isTaxable) _amountTag('Tax', row.taxAmount),
          const Spacer(),
          if (!locked) IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
            onPressed: () => _removeCharge(row),
          ),
        ]),
      ),
    );
  }

  // ── Totals bar ────────────────────────────────────────────────────────────

  Widget _buildTotalsBar() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.primary.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
    ),
    child: Wrap(spacing: 20, runSpacing: 8, children: [
      _totalTag('Gross', _grossTotal),
      _totalTag('Discount', _discountTotal),
      _totalTag('Item Tax', _itemTaxTotal),
      _totalTag('Charges', _chargesTotal),
      _totalTag('Charge Tax', _chargeTaxTotal),
      _totalTag('Grand Total', _grandTotal, bold: true, color: AppColors.primary),
    ]),
  );

  Widget _totalTag(String label, double value, {bool bold = false, Color? color}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      Text('${_grnCurrencyCode ?? ''} ${value.toStringAsFixed(2)}',
          style: TextStyle(fontSize: bold ? 16 : 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: color ?? AppColors.textPrimary)),
    ],
  );

  // ── Posted journal entries (read-only, APPROVED GRNs only) ──────────────

  Widget _buildPostedVoucherSection() {
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

    double totalDebit = 0, totalCredit = 0;
    for (final l in _voucherLines) {
      final amount = (l['trans_amount'] as num? ?? 0).toDouble();
      if (l['trans_nature'] == 'DR') { totalDebit += amount; } else { totalCredit += amount; }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Posted Journal Entries',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
            child: Text(_postedVoucherNo ?? '', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
          ),
        ]),
        const SizedBox(height: 8),
        if (_loadingVoucherLines)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_voucherLines.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No journal entry lines found for this voucher.'))
        else
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Container(
                color: AppColors.primary,
                child: Row(children: [
                  Expanded(flex: 3, child: colHeader('Voucher No')),
                  Expanded(flex: 2, child: colHeader('Serial No')),
                  Expanded(flex: 4, child: colHeader('Ledger Name')),
                  Expanded(flex: 2, child: colHeader('Debit', align: TextAlign.right)),
                  Expanded(flex: 2, child: colHeader('Credit', align: TextAlign.right)),
                ]),
              ),
              for (var i = 0; i < _voucherLines.length; i++) Builder(builder: (_) {
                final l = _voucherLines[i];
                final account = l['account'] as Map<String, dynamic>?;
                final ledgerName = account != null ? '[${account['account_code']}] ${account['account_name']}' : '—';
                final amount = (l['trans_amount'] as num? ?? 0).toDouble();
                final isDr = l['trans_nature'] == 'DR';
                return Container(
                  color: i.isEven ? Colors.white : AppColors.background,
                  child: Row(children: [
                    Expanded(flex: 3, child: cell(l['trans_no'] as String? ?? '')),
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
                  const Expanded(flex: 9, child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  )),
                  Expanded(flex: 2, child: cell(totalDebit.toStringAsFixed(2), align: TextAlign.right, bold: true)),
                  Expanded(flex: 2, child: cell(totalCredit.toStringAsFixed(2), align: TextAlign.right, bold: true)),
                ]),
              ),
            ]),
          ),
      ],
    );
  }

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildPrintButton() => Tooltip(
    message: _printing ? 'Preparing PDF…' : 'Print / Save as PDF',
    child: IconButton(
      icon: _printing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.print_outlined),
      color: AppColors.primary,
      onPressed: _printing ? null : _printGrn,
    ),
  );

  Widget _buildActionButtons({required bool canSave, required bool canApprove}) => Row(children: [
    if (canSave) FilledButton(
      onPressed: _saving ? null : () => _saveDraft(),
      child: _saving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Text('Save Draft'),
    ),
    if (canSave && canApprove) const SizedBox(width: 12),
    if (canApprove) FilledButton(
      onPressed: _approving ? null : _approveGrn,
      style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
      child: _approving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Text('Approve'),
    ),
  ]);

  // ── Generic search field (Autocomplete wrapper) ──────────────────────────

  Widget _searchField<T extends Object>({
    required double height,
    required List<T> options,
    required String initialText,
    required bool locked,
    required InputDecoration decoration,
    required String Function(T) displayString,
    required bool Function(T, String) matches,
    required void Function(T) onSelected,
    required VoidCallback onCleared,
  }) {
    return SizedBox(
      height: height,
      child: Autocomplete<T>(
        key: ValueKey(initialText),
        initialValue: TextEditingValue(text: initialText),
        optionsBuilder: (v) {
          final q = v.text.toLowerCase().trim();
          final filtered = q.isEmpty ? options : options.where((o) => matches(o, q));
          return filtered.take(50);
        },
        displayStringForOption: displayString,
        fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
          controller: textCtrl,
          focusNode: focusNode,
          enabled: !locked,
          onChanged: (v) { if (v.isEmpty) onCleared(); },
          decoration: decoration,
          style: const TextStyle(fontSize: 13),
        ),
        onSelected: (o) { if (!locked) onSelected(o); },
        optionsViewBuilder: (context, onSel, opts) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: opts.length,
                itemBuilder: (context, idx) {
                  final o = opts.elementAt(idx);
                  return InkWell(
                    onTap: () => onSel(o),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(displayString(o), style: const TextStyle(fontSize: 13)),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

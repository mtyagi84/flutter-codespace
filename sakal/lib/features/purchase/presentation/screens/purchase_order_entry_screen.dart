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
import '../../domain/repositories/purchase_order_repository.dart';
import '../providers/purchase_order_providers.dart';

// ── UI-state row classes (live editing — not DB models) ──────────────────────

class _POLineRow {
  String? productId;
  String  productDisplay = '';
  final TextEditingController barcodeCtrl  = TextEditingController();
  String? matchedBarcode; // the exact barcode string that resolved this line's product/UOM
  bool    descExpanded  = false;
  final TextEditingController descCtrl      = TextEditingController();
  String? uomId;
  // True once a barcode scan/search has matched this line to a specific
  // rim_product_uom row — the barcode encodes product+UOM+pack size
  // together, so the conversion factor it implies must not then be
  // hand-edited away from what the barcode actually means.
  bool    convFactorLocked = false;
  final TextEditingController convFactorCtrl = TextEditingController(text: '1');
  final TextEditingController qtyPackCtrl    = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl   = TextEditingController(text: '0');
  final TextEditingController rateCtrl       = TextEditingController(text: '0');
  final TextEditingController discountPctCtrl = TextEditingController(text: '0');
  String? taxGroupId;
  String? departmentId;
  String? consumptionAreaId;
  double  qtyOnHandAtOrder    = 0;
  double  reorderLevelAtOrder = 0;
  double  qtyReceived         = 0;

  // Computed by _recompute()
  double baseQty        = 0;
  double grossAmount    = 0;
  double discountAmount = 0;
  double taxableAmount  = 0;
  double taxAmount      = 0;
  double finalAmount    = 0;
  double chargeAmount   = 0;
  double landedAmount   = 0;

  double get qtyPack        => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose       => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get convFactor     => double.tryParse(convFactorCtrl.text) ?? 1;
  double get rate           => double.tryParse(rateCtrl.text) ?? 0;
  double get discountPct    => double.tryParse(discountPctCtrl.text) ?? 0;

  void dispose() {
    barcodeCtrl.dispose(); descCtrl.dispose(); convFactorCtrl.dispose(); qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose(); rateCtrl.dispose(); discountPctCtrl.dispose();
  }
}

class _PaymentTermRow {
  String? termId;
  String  termName = '';
  final TextEditingController descCtrl = TextEditingController();

  void dispose() => descCtrl.dispose();
}

class _ChargeRow {
  String  chargeId;
  String  chargeName;
  bool    isTaxable;
  String? taxId;
  String  nature;           // ADD / DEDUCT
  String? glAccountId;
  String  amountOrPercent;  // AMOUNT / PERCENT — locked from master
  final TextEditingController valueCtrl;

  double amount           = 0;
  double taxAmount        = 0;
  double allocationFactor = 0;

  _ChargeRow({
    required this.chargeId,
    required this.chargeName,
    required this.isTaxable,
    this.taxId,
    required this.nature,
    this.glAccountId,
    required this.amountOrPercent,
    String initialValue = '0',
  }) : valueCtrl = TextEditingController(text: initialValue);

  double get value => double.tryParse(valueCtrl.text) ?? 0;

  void dispose() => valueCtrl.dispose();
}

// ── Screen ────────────────────────────────────────────────────────────────────

class PurchaseOrderEntryScreen extends ConsumerStatefulWidget {
  final String? editOrderNo;
  final String? editOrderDate;
  const PurchaseOrderEntryScreen({super.key, this.editOrderNo, this.editOrderDate});

  @override
  ConsumerState<PurchaseOrderEntryScreen> createState() => _PurchaseOrderEntryScreenState();
}

class _PurchaseOrderEntryScreenState extends ConsumerState<PurchaseOrderEntryScreen>
    with ScreenPermissionMixin<PurchaseOrderEntryScreen> {
  // Same key as the list screen — the entry screen is not itself a menu
  // item, per the shared ERP navigation pattern (Menu -> List -> Entry).
  @override String get screenName => RouteNames.purchaseOrders;

  PurchaseOrderRepository get _ds => ref.read(purchaseOrderRepositoryProvider);

  // ── Header state ─────────────────────────────────────────────────────────
  String?  _orderNo;
  DateTime _orderDate = DateTime.now();
  String   _poType    = 'LOCAL';
  String   _status    = 'DRAFT';
  String?  _locationId;
  String?  _supplierId;
  String?  _supplierDisplay;
  final _supplierRefNoCtrl = TextEditingController();
  DateTime? _supplierRefDate;
  final _indentNoCtrl     = TextEditingController();
  DateTime? _indentDate;
  final _rfqNoCtrl        = TextEditingController();
  DateTime? _rfqDate;
  final _quotationNoCtrl  = TextEditingController();
  DateTime? _quotationDate;
  String?  _poCurrencyId;
  String?  _poCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  double   get _rateToBase  => double.tryParse(_rateToBaseCtrl.text) ?? 1;
  double   get _rateToLocal => double.tryParse(_rateToLocalCtrl.text) ?? 1;
  String?  _buyerId;
  final _orderSubjectCtrl = TextEditingController();
  final _billToCtrl       = TextEditingController();
  final _shipToCtrl       = TextEditingController();
  final _remarksCtrl      = TextEditingController();

  // ── Lines / Charges / Payment Terms ───────────────────────────────────────
  final List<_POLineRow>       _lines        = [];
  final List<_ChargeRow>       _charges      = [];
  final List<_PaymentTermRow>  _paymentTerms = [];

  // ── Reference data ───────────────────────────────────────────────────────
  List<Map<String, dynamic>> _suppliers    = [];
  List<Map<String, dynamic>> _products     = [];
  List<Map<String, dynamic>> _uoms         = [];
  List<Map<String, dynamic>> _taxGroups    = [];
  List<Map<String, dynamic>> _additionalCharges = [];
  List<Map<String, dynamic>> _departments  = [];
  List<Map<String, dynamic>> _consumptionAreas = [];
  List<Map<String, dynamic>> _paymentTermMasters = [];
  List<Map<String, dynamic>> _locations    = [];
  List<Map<String, dynamic>> _users        = [];
  Map<String, double> _taxGroupRatePct = {};
  Map<String, double> _taxRatePct      = {};
  String _baseCurrency  = '';
  String _localCurrency = '';

  bool    _loading = true;
  String? _error;
  bool    _saving  = false;
  bool    _approving = false;
  bool    _printing = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _supplierRefNoCtrl.dispose(); _indentNoCtrl.dispose(); _rfqNoCtrl.dispose();
    _quotationNoCtrl.dispose(); _rateToBaseCtrl.dispose(); _rateToLocalCtrl.dispose();
    _orderSubjectCtrl.dispose(); _billToCtrl.dispose(); _shipToCtrl.dispose(); _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    for (final c in _charges) { c.dispose(); }
    for (final t in _paymentTerms) { t.dispose(); }
    super.dispose();
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    _locationId = session.locationId;
    _buyerId    = session.userId;
    try {
      final results = await Future.wait<dynamic>([
        ref.read(accountsProvider.future),
        _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.unit),
        _ds.getTaxGroups(clientId: session.clientId, companyId: session.companyId),
        _ds.getAdditionalCharges(clientId: session.clientId, companyId: session.companyId),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.department),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.consumptionArea),
        _ds.getCommonMastersByType(clientId: session.clientId, companyId: session.companyId, typeKey: MasterTypeKey.paymentTerms),
        ref.read(locationsProvider.future),
        _ds.getUsers(clientId: session.clientId, companyId: session.companyId),
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
      _paymentTermMasters  = results[7] as List<Map<String, dynamic>>;
      _locations           = results[8] as List<Map<String, dynamic>>;
      _users               = results[9] as List<Map<String, dynamic>>;
      _baseCurrency        = results[10] as String;
      _localCurrency       = results[11] as String;

      await _loadTaxRates();

      if (widget.editOrderNo != null) {
        await _loadExisting(widget.editOrderNo!, widget.editOrderDate);
      } else {
        _poCurrencyId = null;
        if (mounted) setState(() { _loading = false; _addLine(); });
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

  Future<void> _loadExisting(String orderNo, [String? orderDate]) async {
    final session = ref.read(sessionProvider)!;
    try {
      final header = await _ds.getHeader(clientId: session.clientId, companyId: session.companyId,
          orderNo: orderNo, orderDate: orderDate);
      if (header == null || !mounted) { setState(() => _loading = false); return; }
      final lines   = await _ds.getLines(clientId: session.clientId, companyId: session.companyId,
          orderNo: orderNo, orderDate: header.orderDate);
      final charges = await _ds.getCharges(clientId: session.clientId, companyId: session.companyId,
          orderNo: orderNo, orderDate: header.orderDate);
      final terms   = await _ds.getPaymentTerms(clientId: session.clientId, companyId: session.companyId,
          orderNo: orderNo, orderDate: header.orderDate);

      for (final l in _lines) { l.dispose(); }
      for (final c in _charges) { c.dispose(); }
      for (final t in _paymentTerms) { t.dispose(); }
      _lines.clear();
      _charges.clear();
      _paymentTerms.clear();

      for (final l in lines) {
        final row = _POLineRow()
          ..productId       = l.productId
          ..productDisplay  = l.productCode != null ? '[${l.productCode}] ${l.productName}' : ''
          ..uomId           = l.uomId
          ..taxGroupId      = l.taxGroupId
          ..departmentId    = l.departmentId
          ..consumptionAreaId = l.consumptionAreaId
          ..qtyOnHandAtOrder    = l.qtyOnHandAtOrder ?? 0
          ..reorderLevelAtOrder = l.reorderLevelAtOrder ?? 0
          ..qtyReceived         = l.qtyReceived;
        row.descCtrl.text        = l.itemDescription ?? '';
        row.convFactorCtrl.text  = l.uomConversionFactor.toString();
        row.qtyPackCtrl.text     = l.qtyPack.toString();
        row.qtyLooseCtrl.text    = l.qtyLoose.toString();
        row.rateCtrl.text        = l.rate.toString();
        row.discountPctCtrl.text = l.discountPercent.toString();
        _lines.add(row);
      }

      for (final c in charges) {
        _charges.add(_ChargeRow(
          chargeId:        c.chargeId,
          chargeName:      c.chargeName,
          isTaxable:       c.isTaxable,
          taxId:           c.taxId,
          nature:          c.nature,
          glAccountId:     c.glAccountId,
          amountOrPercent: c.amountOrPercent,
          initialValue:    (c.amountOrPercent == 'PERCENT' ? c.percent : c.amount)?.toString() ?? '0',
        ));
      }

      for (final t in terms) {
        final row = _PaymentTermRow()
          ..termId   = t.termId
          ..termName = t.termName;
        row.descCtrl.text = t.description ?? '';
        _paymentTerms.add(row);
      }

      if (mounted) {
        setState(() {
          _orderNo          = header.orderNo;
          _orderDate        = DateTime.tryParse(header.orderDate) ?? DateTime.now();
          _poType           = header.poType;
          _status           = header.status;
          _locationId       = header.locationId;
          _supplierId       = header.supplierId;
          _supplierDisplay  = header.supplierName != null ? '[${header.supplierCode}] ${header.supplierName}' : '';
          _supplierRefNoCtrl.text = header.supplierRefNo ?? '';
          _supplierRefDate  = header.supplierRefDate != null ? DateTime.tryParse(header.supplierRefDate!) : null;
          _indentNoCtrl.text = header.indentNo ?? '';
          _indentDate       = header.indentDate != null ? DateTime.tryParse(header.indentDate!) : null;
          _rfqNoCtrl.text    = header.rfqNo ?? '';
          _rfqDate          = header.rfqDate != null ? DateTime.tryParse(header.rfqDate!) : null;
          _quotationNoCtrl.text = header.quotationNo ?? '';
          _quotationDate    = header.quotationDate != null ? DateTime.tryParse(header.quotationDate!) : null;
          _poCurrencyId     = header.poCurrencyId;
          _poCurrencyCode   = header.poCurrencyCode;
          _rateToBaseCtrl.text  = header.rateToBase.toString();
          _rateToLocalCtrl.text = header.rateToLocal.toString();
          _buyerId          = header.buyerId;
          _orderSubjectCtrl.text = header.orderSubject ?? '';
          _billToCtrl.text  = header.billTo ?? '';
          _shipToCtrl.text  = header.shipTo ?? '';
          _remarksCtrl.text = header.remarks ?? '';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load purchase order: $e'; });
    }
  }

  // ── Lines / Charges management ───────────────────────────────────────────

  void _addLine() => setState(() => _lines.add(_POLineRow()));

  void _removeLine(_POLineRow row) => setState(() { row.dispose(); _lines.remove(row); });

  void _addCharge() {
    if (_additionalCharges.isEmpty) return;
    final first = _additionalCharges.first;
    setState(() => _charges.add(_ChargeRow(
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

  void _removeCharge(_ChargeRow row) => setState(() { row.dispose(); _charges.remove(row); });

  void _addPaymentTerm() {
    if (_paymentTermMasters.isEmpty) return;
    final first = _paymentTermMasters.first;
    setState(() => _paymentTerms.add(_PaymentTermRow()
      ..termId   = first['id'] as String
      ..termName = first['description'] as String));
  }

  void _removePaymentTerm(_PaymentTermRow row) => setState(() { row.dispose(); _paymentTerms.remove(row); });

  bool _isDuplicateProduct(String productId, {required _POLineRow excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  Future<void> _onProductSelected(_POLineRow row, Map<String, dynamic> product, {bool fromBarcode = false}) async {
    final productId = product['id'] as String;
    if (_isDuplicateProduct(productId, excluding: row)) {
      _showSnack('This product is already on another line — edit that line\'s quantity instead.', color: AppColors.negative);
      return;
    }
    setState(() {
      row.productId      = productId;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.descCtrl.text  = product['product_name'] as String? ?? '';
      if (!fromBarcode) {
        // A plain code/name pick doesn't imply a pack size — leave UOM/factor
        // as the product's default and freely editable. A barcode match sets
        // these separately, right after this call, and locks the factor.
        row.uomId            = product['base_uom_id'] as String?;
        row.convFactorLocked = false;
      }
      row.taxGroupId     = product['purchase_tax_group_id'] as String?;
      final cost = (product['last_purchase_cost'] as num?) ?? (product['standard_cost'] as num?) ?? 0;
      row.rateCtrl.text  = cost.toString();
    });
    if (_locationId != null) {
      final snap = await _ds.getProductStockSnapshot(productId: row.productId!, locationId: _locationId!);
      if (mounted) {
        setState(() {
          row.qtyOnHandAtOrder    = snap['current_stock'] ?? 0;
          row.reorderLevelAtOrder = snap['reorder_level'] ?? 0;
        });
      }
    }
  }

  Future<void> _onBarcodeSubmitted(_POLineRow row, String rawBarcode) async {
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
    final matchedProduct = match; // re-bind: null-promotion doesn't survive into the setState closure below
    await _onProductSelected(row, matchedProduct, fromBarcode: true);
    // If _onProductSelected rejected the match as a duplicate, row.productId
    // still points at whatever it was before — don't override UOM/factor.
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
    // Always re-sync currency (and rates) to whichever supplier is selected —
    // switching suppliers mid-entry should re-derive the currency from the
    // new supplier, not keep whatever the previous supplier implied.
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
      _poCurrencyId   = currency['id'] as String;
      _poCurrencyCode = currency['currency_id'] as String;
      _rateToBaseCtrl.text  = '1';
      _rateToLocalCtrl.text = '1';
    });
    await _fetchRates();
  }

  Future<void> _fetchRates() async {
    if (_poCurrencyCode == null) return;
    final session = ref.read(sessionProvider)!;
    if (_locationId == null) return;
    if (_poCurrencyCode != _baseCurrency && _baseCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _poCurrencyCode!, toCurrency: _baseCurrency, rateDate: _fmtDate(_orderDate));
      if (mounted && r != null) setState(() => _rateToBaseCtrl.text = r.toString());
    } else if (mounted) {
      setState(() => _rateToBaseCtrl.text = '1');
    }
    if (_localCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _poCurrencyCode!, toCurrency: _localCurrency, rateDate: _fmtDate(_orderDate));
      if (mounted && r != null) setState(() => _rateToLocalCtrl.text = r.toString());
    }
  }

  // ── Computed totals ───────────────────────────────────────────────────────
  // Recomputed on every build from live controller text — same pattern as
  // FinanceVoucherEntryScreen's getters. Called once at the top of build().

  void _recompute() {
    double poValueBeforeCharges = 0;
    for (final l in _lines) {
      l.baseQty        = l.qtyPack * l.convFactor + l.qtyLoose;
      l.grossAmount    = l.baseQty * l.rate;
      l.discountAmount = l.grossAmount * l.discountPct / 100;
      l.taxableAmount  = l.grossAmount - l.discountAmount;
      final ratePct    = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount       = l.taxableAmount * ratePct / 100;
      l.finalAmount     = l.taxableAmount + l.taxAmount;
      poValueBeforeCharges += l.taxableAmount;
    }

    for (final c in _charges) {
      c.amount = c.amountOrPercent == 'PERCENT'
          ? poValueBeforeCharges * c.value / 100
          : c.value;
      final chargeRatePct = c.isTaxable && c.taxId != null ? (_taxRatePct[c.taxId] ?? 0) : 0;
      c.taxAmount        = c.amount * chargeRatePct / 100;
      c.allocationFactor = poValueBeforeCharges > 0 ? c.amount / poValueBeforeCharges : 0;
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

  double get _grossTotal    => _lines.fold(0.0, (s, l) => s + l.grossAmount);
  double get _discountTotal => _lines.fold(0.0, (s, l) => s + l.discountAmount);
  double get _itemTaxTotal  => _lines.fold(0.0, (s, l) => s + l.taxAmount);
  double get _chargesTotal  => _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));
  double get _chargeTaxTotal => _charges.fold(0.0, (s, c) => s + c.taxAmount);
  double get _grandTotal    => _lines.fold(0.0, (s, l) => s + l.finalAmount) + _chargesTotal + _chargeTaxTotal;

  // ── Save / Approve ────────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_supplierId == null) { _showSnack('Select a supplier.'); return false; }
    if (_poCurrencyId == null) { _showSnack('Select a currency.'); return false; }
    if (_locationId == null) { _showSnack('Select a location.'); return false; }
    if (_lines.where((l) => l.productId != null).isEmpty) {
      _showSnack('Add at least one line item.');
      return false;
    }
    // Real bug found live (Sales Order/Quotation) applies here too: a
    // charge's Amount field accepted a negative number with no check.
    for (final c in _charges) {
      if (c.value < 0) { _showSnack('${c.chargeName}: amount cannot be negative.', color: AppColors.negative); return false; }
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':          session.clientId,
        'company_id':         session.companyId,
        'location_id':        _locationId,
        'order_no':           _orderNo ?? '',
        'order_date':         _fmtDate(_orderDate),
        'po_type':            _poType,
        'supplier_id':        _supplierId,
        'supplier_ref_no':    _supplierRefNoCtrl.text,
        'supplier_ref_date':  _supplierRefDate != null ? _fmtDate(_supplierRefDate!) : '',
        'indent_no':          _indentNoCtrl.text,
        'indent_date':        _indentDate != null ? _fmtDate(_indentDate!) : '',
        'rfq_no':             _rfqNoCtrl.text,
        'rfq_date':           _rfqDate != null ? _fmtDate(_rfqDate!) : '',
        'quotation_no':       _quotationNoCtrl.text,
        'quotation_date':     _quotationDate != null ? _fmtDate(_quotationDate!) : '',
        'po_currency_id':     _poCurrencyId,
        'rate_to_base':       _rateToBase,
        'rate_to_local':      _rateToLocal,
        'gross_amount':       _grossTotal,
        'discount_amount':    _discountTotal,
        'charges_amount':     _chargesTotal,
        'item_tax_amount':    _itemTaxTotal,
        'charge_tax_amount':  _chargeTaxTotal,
        'grand_total':        _grandTotal,
        'buyer_id':           _buyerId ?? '',
        'order_subject':      _orderSubjectCtrl.text,
        'bill_to':            _billToCtrl.text,
        'ship_to':            _shipToCtrl.text,
        'remarks':            _remarksCtrl.text,
      };

      var serial = 1;
      final lines = _lines.where((l) => l.productId != null).map((l) => {
        'serial_no':              serial++,
        'product_id':             l.productId,
        'item_description':       l.descCtrl.text,
        'barcode':                l.matchedBarcode ?? '',
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
        'qty_on_hand_at_order':   l.qtyOnHandAtOrder,
        'reorder_level_at_order': l.reorderLevelAtOrder,
      }).toList();

      var chargeSerial = 1;
      final charges = _charges.map((c) => {
        'serial_no':          chargeSerial++,
        'charge_id':          c.chargeId,
        'charge_name':        c.chargeName,
        'is_taxable':         c.isTaxable,
        'tax_id':             c.taxId ?? '',
        'nature':             c.nature,
        'gl_account_id':      c.glAccountId ?? '',
        'amount_or_percent':  c.amountOrPercent,
        'percent':            c.amountOrPercent == 'PERCENT' ? c.value : null,
        'amount':             c.amount,
        'tax_amount':         c.taxAmount,
        'allocation_factor':  c.allocationFactor,
      }).toList();

      var termSerial = 1;
      final paymentTerms = _paymentTerms.where((t) => t.termId != null).map((t) => {
        'serial_no':   termSerial++,
        'term_id':     t.termId,
        'term_name':   t.termName,
        'description': t.descCtrl.text,
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'PURCHASE_ORDER',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_purchase_order',
          payload:      {'p_header': header, 'p_lines': lines, 'p_charges': charges,
              'p_payment_terms': paymentTerms, 'p_user_id': session.userId},
        );
        // Cache locally so the PO is readable in the entry screen while still offline.
        await _ds.cacheOrderLocally(
          effectiveOrderNo: localId,
          header: header,
          lines:  lines,
          charges: charges,
          paymentTerms: paymentTerms,
        );
        if (mounted) {
          setState(() { _orderNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final orderNo = await _ds.save(
            header: header, lines: lines, charges: charges, paymentTerms: paymentTerms, userId: session.userId);
        // Cache for offline access in subsequent sessions.
        unawaited(_ds.cacheOrderLocally(
            effectiveOrderNo: orderNo, header: header, lines: lines, charges: charges, paymentTerms: paymentTerms));
        if (mounted) {
          setState(() { _orderNo = orderNo; _saving = false; });
          _showSnack('Draft saved — $orderNo', color: AppColors.positive);
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

  // ── Copy PO ───────────────────────────────────────────────────────────────
  // Any saved PO can be copied — but if the source was raised against an
  // Indent/RFQ/Quotation, those references belong to that ONE original
  // procurement trail and must NOT carry over. The copy always becomes a
  // fresh Direct order with no reference, never a duplicate of someone
  // else's indent/quotation.
  bool get _canCopy => _orderNo != null && canCopy;

  Future<void> _applyCopy() async {
    setState(() {
      _orderNo   = null;           // becomes a new unsaved draft
      _orderDate = DateTime.now(); // default to today
      _status    = 'DRAFT';
      _supplierRefNoCtrl.clear();  // the supplier's ref for the ORIGINAL order only
      _supplierRefDate = null;
      _indentNoCtrl.clear();       // copy always becomes a Direct order — no
      _indentDate = null;          // reference to the source's Indent/RFQ/
      _rfqNoCtrl.clear();          // Quotation trail carries over
      _rfqDate = null;
      _quotationNoCtrl.clear();
      _quotationDate = null;
      for (final l in _lines) { l.qtyReceived = 0; } // nothing received against the new order yet
      // Supplier, currency, rates, buyer, lines, charges, payment terms,
      // subject/addresses/remarks: kept as-is.
    });
    // Refresh each line's stock-at-order snapshot against today rather than
    // carrying over the original order date's stale figures.
    if (_locationId != null) {
      for (final l in _lines) {
        if (l.productId == null) continue;
        final snap = await _ds.getProductStockSnapshot(productId: l.productId!, locationId: _locationId!);
        if (!mounted) return;
        setState(() {
          l.qtyOnHandAtOrder    = snap['current_stock'] ?? 0;
          l.reorderLevelAtOrder = snap['reorder_level'] ?? 0;
        });
      }
    }
    if (mounted) _showSnack('Copied — edit as needed and save as a new draft.', color: AppColors.secondary);
  }

  // ── Print ─────────────────────────────────────────────────────────────────
  // Available on any saved PO regardless of status — the shared print engine
  // (lib/core/printing/) draws a DRAFT watermark automatically when
  // header.status != APPROVED. See default_templates/purchase_order_default_template.dart
  // for the field bindings this document map must satisfy.

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    final buyerName = _users.where((u) => u['id'] == _buyerId).map((u) => u['full_name'] as String).firstOrNull;
    return {
      'company': company,
      'header': {
        'order_no':      _orderNo ?? '',
        'order_date':    _displayDate(_orderDate),
        'status':        _status,
        'supplier_name': _supplierDisplay ?? '',
        'buyer_name':    buyerName ?? '',
        'currency_code': _poCurrencyCode ?? '',
        'po_type':       _poType,
        'bill_to':       _billToCtrl.text,
        'ship_to':       _shipToCtrl.text,
        'remarks':       _remarksCtrl.text,
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
      'paymentTerms': _paymentTerms.where((t) => t.termId != null).map((t) => {
        'term_name': t.termName, 'description': t.descCtrl.text,
      }).toList(),
      'totals': {
        'gross_amount':    _grossTotal,
        'discount_amount': _discountTotal,
        'item_tax_amount': _itemTaxTotal,
        'charges_amount':  _chargesTotal,
        'grand_total':     _grandTotal,
      },
    };
  }

  Future<void> _printPO() async {
    if (_orderNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('PURCHASE_ORDER').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_orderNo.pdf');
    } catch (e) {
      if (mounted) _showSnack('Print failed: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  // Immediate client-side feedback so a user can't even reach the confirm
  // dialog with an incomplete line — fn_approve_purchase_order (migration
  // 040) enforces the same rule authoritatively on the server.
  String? _validateForApprove() {
    final activeLines = _lines.where((l) => l.productId != null).toList();
    if (activeLines.isEmpty) return 'Add at least one line item before approving.';
    for (final l in activeLines) {
      if (l.baseQty <= 0) return 'Every line needs a quantity greater than zero.';
      if (l.rate <= 0) return 'Every line needs a rate greater than zero.';
      if (l.uomId == null) return 'Every line needs a UOM selected.';
    }
    return null;
  }

  Future<void> _approveOrder() async {
    final validationError = _validateForApprove();
    if (validationError != null) {
      _showSnack(validationError, color: AppColors.negative);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Purchase Order'),
        content: const Text('Once approved this order is locked — changes can only be made at GRN. Continue?'),
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

    if (_orderNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }

    final session = ref.read(sessionProvider)!;
    setState(() { _approving = true; _actionError = null; });
    try {
      await _ds.approve(
        clientId: session.clientId, companyId: session.companyId,
        orderNo: _orderNo!, orderDate: _fmtDate(_orderDate), approvedBy: session.userId);
      if (mounted) {
        setState(() { _status = 'APPROVED'; _approving = false; });
        _showSnack('$_orderNo approved.', color: AppColors.positive);
      }
    } on DioException catch (e) {
      if (mounted) setState(() { _approving = false; _actionError = 'Approve failed: ${_serverError(e)}'; });
    } catch (e) {
      if (mounted) setState(() { _approving = false; _actionError = 'Unexpected error: $e'; });
    }
  }

  // PostgREST error bodies are {code, details, hint, message} — `message` is
  // the short RAISE EXCEPTION code (e.g. 'FUTURE_DATE_NOT_ALLOWED'), `details`
  // is the human-readable text from `USING DETAIL`. Prefer details, fall back
  // to message, then to the raw exception — never show the user a bare
  // DioException dump.
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

    final canSave      = _status == 'DRAFT' && (_orderNo == null ? canAdd : canEdit);
    final showApprove  = _status == 'DRAFT' && !isOffline && canApprove && _orderNo != null;
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
                  if (_canCopy || _orderNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_canCopy) _buildCopyButton(),
                      if (_orderNo != null) _buildPrintButton(),
                      if (canSave || showApprove) _buildActionButtons(canSave: canSave, canApprove: showApprove),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock(locked)),
                  if (_canCopy) _buildCopyButton(),
                  if (_orderNo != null) _buildPrintButton(),
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
                      _buildLinesSection(locked, isMobile),
                      const SizedBox(height: 20),
                      _buildChargesSection(locked, isMobile),
                      const SizedBox(height: 20),
                      _buildPaymentTermsSection(locked, isMobile),
                      const SizedBox(height: 12),
                      _buildTotalsBar(),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock(bool locked) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_orderNo != null ? 'Purchase Order · $_orderNo' : 'New Purchase Order',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    if (locked)
      _statusChip(_status)
    else
      Row(children: [
        Text(_orderNo != null ? 'Draft' : 'Unsaved draft',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (_orderNo != null) ...[
          const SizedBox(width: 8),
          PendingSyncBadge(documentType: 'PURCHASE_ORDER', documentId: _orderNo!),
        ],
      ]),
  ]);

  Widget _statusChip(String status) {
    final color = status == 'APPROVED' ? AppColors.positive
        : status == 'CANCELLED' ? AppColors.negative : AppColors.secondary;
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

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          // Row 1: PO Type | Order No | Order Date
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'PO Type *'),
              initialValue: _poType,
              isDense: true,
              itemHeight: null,
              items: const [
                DropdownMenuItem(value: 'LOCAL',  child: Text('Local',  style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'IMPORT', child: Text('Import', style: TextStyle(fontSize: 13))),
              ],
              onChanged: locked ? null : (v) => setState(() => _poType = v!),
            ));
            final f2 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Order No'),
              child: Text(_orderNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _orderNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f3 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_orderDate, (d) => setState(() => _orderDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'Order Date *',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15,
                        color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_orderDate), style: const TextStyle(fontSize: 13)),
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
            final f1 = _searchField<Map<String, dynamic>>(
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
                  initialValue: _poCurrencyId,
                  isExpanded: true,
                  isDense: true,
                  itemHeight: null,
                  items: currencies.map((c) => DropdownMenuItem(
                      value: c['id'] as String,
                      child: Text('${c['currency_id']} — ${c['currency_name']}',
                          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: locked ? null : (v) {
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

          // Row 4: Buyer — Payment Terms now has its own multi-select section below.
          Builder(builder: (_) {
            final f2 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Buyer'),
              initialValue: _buyerId,
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              items: _users.map((u) => DropdownMenuItem(
                  value: u['id'] as String,
                  child: Text(u['full_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() => _buyerId = v),
            ));
            return isMobile
                ? SizedBox(width: double.infinity, child: f2)
                : Row(children: [Expanded(flex: 2, child: f2), const Spacer(flex: 3)]);
          }),
        ]),
      ),
    );
  }

  // ── Additional details (Indent/RFQ/Quotation + Bill To/Ship To) ────────────

  Widget _buildAdditionalDetails(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: ExpansionTile(
        title: const Text('Additional Details', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: const Text('Indent / RFQ / Quotation references, subject, addresses, remarks',
            style: TextStyle(fontSize: 11)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(children: [
              Row(children: [
                Expanded(child: TextFormField(controller: _indentNoCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'Indent No'))),
                const SizedBox(width: 12),
                Expanded(child: _dateField('Indent Date', _indentDate, locked,
                    (d) => setState(() => _indentDate = d))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextFormField(controller: _rfqNoCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'RFQ No'))),
                const SizedBox(width: 12),
                Expanded(child: _dateField('RFQ Date', _rfqDate, locked, (d) => setState(() => _rfqDate = d))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextFormField(controller: _quotationNoCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'Quotation No'))),
                const SizedBox(width: 12),
                Expanded(child: _dateField('Quotation Date', _quotationDate, locked,
                    (d) => setState(() => _quotationDate = d))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextFormField(controller: _supplierRefNoCtrl, enabled: !locked,
                    decoration: dec.copyWith(labelText: 'Supplier Ref No'))),
                const SizedBox(width: 12),
                Expanded(child: _dateField('Supplier Ref Date', _supplierRefDate, locked,
                    (d) => setState(() => _supplierRefDate = d))),
              ]),
              const SizedBox(height: 10),
              TextFormField(controller: _orderSubjectCtrl, enabled: !locked,
                  decoration: dec.copyWith(labelText: 'Order Subject')),
              const SizedBox(height: 10),
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

  // ── Payment Terms section ────────────────────────────────────────────────
  // Multi-select, common-master-driven: a PO can carry several terms, each
  // with its own free-text description (e.g. "50% Advance" -> "Due before
  // dispatch", "Balance NET 30" -> "From GRN date"). Saved to
  // rid_po_payment_terms — see backend/migrations/040_po_payment_terms_and_line_validation.sql.

  static const _termColWidth = 220.0;

  Widget _buildPaymentTermsSection(bool locked, bool isMobile) {
    const btnW = 32.0;
    Widget colHeader(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Payment Terms', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const Spacer(),
          if (!locked && _paymentTermMasters.isNotEmpty)
            TextButton.icon(onPressed: _addPaymentTerm, icon: const Icon(Icons.add, size: 16), label: const Text('Add Term')),
        ]),
        const SizedBox(height: 8),
        if (_paymentTerms.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No payment terms added.'))
        else if (isMobile)
          ..._paymentTerms.map((row) => _buildPaymentTermCardMobile(row, locked))
        else ...[
          // Column headers shown once above the data rows — same pattern as
          // Finance Voucher Entry's On Account section, instead of repeating
          // a floating labelText on every row. Term stays a fixed width (its
          // options are short labels); Description expands to claim whatever
          // space is left, however wide the screen.
          Row(children: [
            SizedBox(width: _termColWidth, child: colHeader('Term')),
            const SizedBox(width: 12),
            Expanded(child: colHeader('Description')),
            if (!locked) const SizedBox(width: btnW + 8),
          ]),
          ..._paymentTerms.map((row) => _buildPaymentTermCard(row, locked)),
        ],
      ],
    );
  }

  Widget _buildPaymentTermCard(_PaymentTermRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: _termColWidth, height: 44, child: DropdownButtonFormField<String>(
          decoration: dec,
          isExpanded: true,
          isDense: true,
          itemHeight: null,
          initialValue: row.termId,
          items: _paymentTermMasters.map((t) => DropdownMenuItem(value: t['id'] as String,
              child: Text(t['description'] as String, style: const TextStyle(fontSize: 13)))).toList(),
          onChanged: locked ? null : (v) {
            final t = _paymentTermMasters.where((x) => x['id'] == v).firstOrNull;
            if (t == null) return;
            setState(() { row.termId = t['id'] as String; row.termName = t['description'] as String; });
          },
        )),
        const SizedBox(width: 12),
        Expanded(child: SizedBox(height: 44, child: TextFormField(
          controller: row.descCtrl, enabled: !locked,
          decoration: dec.copyWith(hintText: 'e.g. 50% advance, balance NET 30'),
          style: const TextStyle(fontSize: 13),
        ))),
        if (!locked) IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
          onPressed: () => _removePaymentTerm(row),
        ),
      ]),
    );
  }

  Widget _buildPaymentTermCardMobile(_PaymentTermRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Term'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.termId,
              items: _paymentTermMasters.map((t) => DropdownMenuItem(value: t['id'] as String,
                  child: Text(t['description'] as String, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) {
                final t = _paymentTermMasters.where((x) => x['id'] == v).firstOrNull;
                if (t == null) return;
                setState(() { row.termId = t['id'] as String; row.termName = t['description'] as String; });
              },
            )),
            if (!locked) IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
              onPressed: () => _removePaymentTerm(row),
            ),
          ]),
          const SizedBox(height: 8),
          TextFormField(controller: row.descCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Description'), style: const TextStyle(fontSize: 13)),
        ]),
      ),
    );
  }

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

  Widget _buildLineCard(_POLineRow row, bool locked, bool isMobile) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    // Field stays hidden but not force-cleared — an existing line loaded with a
    // loose qty (entered before the company switched to Pack Only) must keep
    // contributing to baseQty, not silently lose data.
    final showLooseQty = (ref.read(sessionProvider)?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
    // Barcode search is a company-level setup decision (ric_companies.enable_barcode,
    // migration 027) — same gate the Product Master screen already uses, not a
    // PO-specific toggle. Hidden entirely (not just disabled) when off, since a
    // company that never enabled barcode coding has no rim_product_uom.barcode
    // data for the lookup to match against anyway.
    final showBarcode = ref.read(sessionProvider)?.enableBarcode ?? false;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
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
            if (!locked) IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
              onPressed: () => _removeLine(row),
            ),
          ]),
          const SizedBox(height: 6),
          InkWell(
            onTap: () => setState(() => row.descExpanded = !row.descExpanded),
            child: Row(children: [
              Icon(row.descExpanded ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: AppColors.textSecondary),
              Expanded(child: Text(
                row.descExpanded
                    ? 'Item Description'
                    : (row.descCtrl.text.isEmpty ? 'Item Description' : row.descCtrl.text),
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
          Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 140, child: DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'UOM'),
              isExpanded: true,
              isDense: true,
              itemHeight: null,
              initialValue: row.uomId,
              items: _uoms.map((u) => DropdownMenuItem(value: u['id'] as String,
                  child: Text(u['description'] as String, style: const TextStyle(fontSize: 12)))).toList(),
              onChanged: (locked || row.convFactorLocked) ? null : (v) => setState(() => row.uomId = v),
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
            SizedBox(width: 100, child: TextFormField(controller: row.rateCtrl, enabled: !locked,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: dec.copyWith(labelText: 'Rate'), style: const TextStyle(fontSize: 12),
                onChanged: (_) => setState(() {}))),
            SizedBox(width: 90, child: TextFormField(controller: row.discountPctCtrl, enabled: !locked,
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
              onChanged: locked ? null : (v) => setState(() => row.taxGroupId = v),
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
            if (row.qtyReceived > 0) _amountTag('Received', row.qtyReceived),
            if (row.qtyOnHandAtOrder > 0) Text('Stock at order: ${row.qtyOnHandAtOrder.toStringAsFixed(0)} (reorder ${row.reorderLevelAtOrder.toStringAsFixed(0)})',
                style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
          ]),
        ]),
      ),
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
          // Same fixed-column pattern as Payment Terms — every row lines up
          // under the same headers instead of a Wrap that reflows narrower
          // or wider per row depending on which optional widgets (e.g. the
          // Tax figure) happen to render for that charge.
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

  Widget _buildChargeCard(_ChargeRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    Widget rightText(String text, {Color? color, bool bold = false}) => Text(text,
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 13, color: color ?? AppColors.textPrimary,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(flex: 3, child: SizedBox(height: 44, child: DropdownButtonFormField<String>(
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

  Widget _buildChargeCardMobile(_ChargeRow row, bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
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
      Text('${_poCurrencyCode ?? ''} ${value.toStringAsFixed(2)}',
          style: TextStyle(fontSize: bold ? 16 : 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: color ?? AppColors.textPrimary)),
    ],
  );

  // ── Action buttons ────────────────────────────────────────────────────────

  Widget _buildCopyButton() => Tooltip(
    message: 'Copy to new Purchase Order',
    child: IconButton(
      icon: const Icon(Icons.copy_outlined),
      color: AppColors.primary,
      onPressed: _applyCopy,
    ),
  );

  Widget _buildPrintButton() => Tooltip(
    message: _printing ? 'Preparing PDF…' : 'Print / Save as PDF',
    child: IconButton(
      icon: _printing
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.print_outlined),
      color: AppColors.primary,
      onPressed: _printing ? null : _printPO,
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
      onPressed: _approving ? null : _approveOrder,
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

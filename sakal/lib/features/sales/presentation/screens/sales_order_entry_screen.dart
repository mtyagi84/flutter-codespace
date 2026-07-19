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
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../domain/repositories/sales_order_repository.dart';
import '../providers/sales_order_providers.dart';
import '../widgets/prospect_conversion_dialog.dart';

class _OrderLineRow {
  String? productId;
  String  productDisplay = '';
  String? costCurrencyId;
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController barcodeCtrl = TextEditingController();
  String? matchedBarcode;
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  // Direct mode: pack/loose split, gated by showLooseQty. Against-
  // Quotation mode: qtyPackCtrl is repurposed as a single "Qty to
  // Convert" BASE-quantity field (qtyLoose stays 0, unused) — pack/loose
  // splitting a partial-conversion amount has no clear meaning once the
  // original line's own split was already fixed at quotation time.
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  final TextEditingController rateCtrl     = TextEditingController(text: '0');
  final TextEditingController discountPctCtrl = TextEditingController(text: '0');
  String? taxGroupId;
  final TextEditingController remarksCtrl = TextEditingController();
  double  deliveredQty = 0;

  // Direct-mode price governance (Part A: ric_user_sales_controls)
  String  priceSource = 'PRICE_MASTER'; // PRICE_MASTER | MANUAL_OVERRIDE | QUOTATION
  bool    priceLoading = false;
  bool    priceResolved = false; // whether fn_get_active_price found something
  bool    overrideEnabled = false; // user explicitly opened Rate for editing
  final TextEditingController overrideReasonCtrl = TextEditingController();
  double  costPrice = 0;
  double  availableStock = 0;
  bool    costLoading = false;

  // Against-Quotation mode
  int?    sourceQuotationLineSerial;
  double  sourceRemainingQty = 0; // base_qty - converted_qty on the source line

  // Recomputed every build by _recompute()
  double baseQty        = 0;
  double grossAmount    = 0;
  double discountAmount = 0;
  double taxableAmount  = 0;
  double taxAmount      = 0;
  double finalAmount    = 0;
  double chargeAmount   = 0;
  double landedAmount   = 0;

  double get qtyPack     => double.tryParse(qtyPackCtrl.text) ?? 0;
  double get qtyLoose    => double.tryParse(qtyLooseCtrl.text) ?? 0;
  double get rate        => double.tryParse(rateCtrl.text) ?? 0;
  double get discountPct => double.tryParse(discountPctCtrl.text) ?? 0;

  void dispose() {
    descCtrl.dispose();
    barcodeCtrl.dispose();
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    rateCtrl.dispose();
    discountPctCtrl.dispose();
    remarksCtrl.dispose();
    overrideReasonCtrl.dispose();
  }
}

class _OrderChargeRow {
  String? chargeId;
  String  chargeName = '';
  bool    isTaxable = false;
  String? taxId;
  String  nature = 'ADD';
  String? glAccountId;
  String  amountOrPercent = 'AMOUNT';
  final TextEditingController valueCtrl = TextEditingController(text: '0');

  double amount           = 0;
  double taxAmount        = 0;
  double allocationFactor = 0;

  double get value => double.tryParse(valueCtrl.text) ?? 0;

  void dispose() => valueCtrl.dispose();
}

class SalesOrderEntryScreen extends ConsumerStatefulWidget {
  final String? editOrderNo;
  final String? editOrderDate;
  final String? newOrderMode; // 'DIRECT' | 'AGAINST_QUOTATION', only used when editOrderNo == null
  final String? sourceQuotationNo;
  final String? sourceQuotationDate;
  const SalesOrderEntryScreen({
    super.key,
    this.editOrderNo,
    this.editOrderDate,
    this.newOrderMode,
    this.sourceQuotationNo,
    this.sourceQuotationDate,
  });

  @override
  ConsumerState<SalesOrderEntryScreen> createState() => _SalesOrderEntryScreenState();
}

class _SalesOrderEntryScreenState extends ConsumerState<SalesOrderEntryScreen>
    with ScreenPermissionMixin<SalesOrderEntryScreen> {
  @override String get screenName => RouteNames.salesOrders;

  SalesOrderRepository get _ds => ref.read(salesOrderRepositoryProvider);

  String?  _orderNo;
  DateTime _orderDate = DateTime.now();
  String   _status = 'DRAFT';
  String   _orderMode = 'DIRECT';
  String?  _sourceQuotationNo;
  String?  _sourceQuotationDate;
  String?  _locationId;
  String?  _customerId;
  String   _customerDisplay = '';
  Map<String, dynamic>? _customerInfo;
  final _customerPoRefCtrl = TextEditingController();
  String?  _salesPersonId;
  String   _salesPersonDisplay = '';
  // Resolved in _loadExisting (against _users, already loaded before it) —
  // print's "Prepared By"/"Authorised Signatory" data supply.
  String?  _preparedByName;
  String?  _authorisedByName;
  String?  _orderCurrencyId;
  String?  _orderCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  String? _paymentTermId;
  String  _paymentTermDisplay = '';
  String? _incotermId;
  String  _incotermDisplay = '';
  final _shipToCtrl = TextEditingController();
  final _billToCtrl = TextEditingController();
  DateTime? _expectedDeliveryDate;
  final _deliveryInstructionsCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _taxGroups = [];
  List<Map<String, dynamic>> _additionalCharges = [];
  List<Map<String, dynamic>> _currencies = [];
  List<Map<String, dynamic>> _paymentTerms = [];
  List<Map<String, dynamic>> _incoterms = [];
  String _baseCurrency = '';
  String _localCurrency = '';
  Map<String, double> _taxRatePct = {};
  Map<String, double> _taxGroupRatePct = {};

  // Part A: resolved once at init. A missing row = all false/0, mirroring
  // fn_save_sales_order's own coalesce-based default — never assumed
  // permissive.
  bool    _canOverridePrice   = false;
  bool    _canGiveDiscount    = false;
  double? _maxDiscountPercent;
  bool    _canViewCostPrice   = false;

  final List<_OrderLineRow> _lines = [];
  final List<_OrderChargeRow> _charges = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _cancelling = false;
  bool    _printing = false;

  bool get _isNew => _orderNo == null;
  bool get _isAgainstQuotation => _orderMode == 'AGAINST_QUOTATION';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _customerPoRefCtrl.dispose();
    _rateToBaseCtrl.dispose();
    _rateToLocalCtrl.dispose();
    _shipToCtrl.dispose();
    _billToCtrl.dispose();
    _deliveryInstructionsCtrl.dispose();
    _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    for (final c in _charges) { c.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    _locationId = session.locationId;
    try {
      final results = await Future.wait<dynamic>([
        _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId),
        _ds.getTaxGroups(clientId: session.clientId, companyId: session.companyId),
        _ds.getAdditionalCharges(clientId: session.clientId, companyId: session.companyId),
        _ds.getUsersForAutocomplete(clientId: session.clientId, companyId: session.companyId),
        ref.read(locationsProvider.future),
        ref.read(currenciesProvider.future),
        ref.read(baseCurrencyProvider.future),
        ref.read(localCurrencyProvider.future),
        _ds.getUserSalesControls(clientId: session.clientId, companyId: session.companyId, userId: session.userId),
        _ds.getPaymentTerms(clientId: session.clientId, companyId: session.companyId),
        _ds.getIncoterms(clientId: session.clientId, companyId: session.companyId),
      ]);

      _products          = results[0] as List<Map<String, dynamic>>;
      _taxGroups         = results[1] as List<Map<String, dynamic>>;
      _additionalCharges = results[2] as List<Map<String, dynamic>>;
      _users             = results[3] as List<Map<String, dynamic>>;
      _locations         = results[4] as List<Map<String, dynamic>>;
      _currencies        = results[5] as List<Map<String, dynamic>>;
      _baseCurrency      = results[6] as String;
      _localCurrency     = results[7] as String;
      final controls = results[8] as Map<String, dynamic>?;
      _paymentTerms      = results[9] as List<Map<String, dynamic>>;
      _incoterms         = results[10] as List<Map<String, dynamic>>;
      _canOverridePrice   = controls?['can_override_price'] as bool? ?? false;
      _canGiveDiscount    = controls?['can_give_discount'] as bool? ?? false;
      _maxDiscountPercent = (controls?['max_discount_percent'] as num?)?.toDouble();
      _canViewCostPrice   = controls?['can_view_cost_price'] as bool? ?? false;

      await _loadTaxRates();

      if (widget.editOrderNo != null) {
        await _loadExisting(widget.editOrderNo!, widget.editOrderDate);
      } else if (widget.newOrderMode == 'AGAINST_QUOTATION') {
        _orderMode = 'AGAINST_QUOTATION';
        await _loadFromQuotation(widget.sourceQuotationNo!, widget.sourceQuotationDate!);
      } else {
        _orderMode = 'DIRECT';
        if (mounted) setState(() => _loading = false);
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
    final header = await _ds.getHeader(
      clientId: session.clientId, companyId: session.companyId,
      orderNo: orderNo, orderDate: orderDate,
    );
    if (header == null || !mounted) { setState(() => _loading = false); return; }

    final customer    = header['customer'] as Map<String, dynamic>?;
    final salesPerson = header['sales_person'] as Map<String, dynamic>?;
    final currency    = header['currency'] as Map<String, dynamic>?;
    final paymentTerm = header['payment_term'] as Map<String, dynamic>?;
    final incoterm    = header['incoterm'] as Map<String, dynamic>?;

    _orderNo             = header['order_no'] as String;
    _orderDate           = DateTime.parse(header['order_date'] as String);
    _status              = header['status'] as String;
    _preparedByName      = _resolveUserName(header['created_by'] as String?);
    _authorisedByName    = _resolveUserName(header['approved_by'] as String?);
    _orderMode           = header['order_mode'] as String? ?? 'DIRECT';
    _sourceQuotationNo   = header['source_quotation_no'] as String?;
    _sourceQuotationDate = header['source_quotation_date'] as String?;
    _locationId          = header['location_id'] as String?;
    _customerId          = header['customer_id'] as String?;
    _customerDisplay     = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
    _customerPoRefCtrl.text = header['customer_po_ref'] as String? ?? '';
    _shipToCtrl.text        = header['ship_to'] as String? ?? '';
    _billToCtrl.text        = header['bill_to'] as String? ?? '';
    _expectedDeliveryDate   = header['expected_delivery_date'] != null
        ? DateTime.tryParse(header['expected_delivery_date'] as String)
        : null;
    _salesPersonId        = header['sales_person_id'] as String?;
    _salesPersonDisplay    = salesPerson?['full_name'] as String? ?? '';
    _orderCurrencyId        = header['order_currency_id'] as String?;
    _orderCurrencyCode       = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text  = (header['rate_to_base']  as num? ?? 1).toString();
    _rateToLocalCtrl.text = (header['rate_to_local'] as num? ?? 1).toString();
    _paymentTermId          = header['payment_term_id'] as String?;
    _paymentTermDisplay     = paymentTerm?['term_name'] as String? ?? '';
    _incotermId             = header['incoterm_id'] as String?;
    _incotermDisplay        = incoterm?['description'] as String? ?? '';
    _deliveryInstructionsCtrl.text = header['delivery_instructions'] as String? ?? '';
    _remarksCtrl.text       = header['remarks'] as String? ?? '';

    if (_customerId != null) unawaited(_loadCustomerInfo(_customerId!));

    final savedLines = await _ds.getLines(
      clientId: session.clientId, companyId: session.companyId,
      orderNo: _orderNo!, orderDate: _fmtDate(_orderDate),
    );
    for (final l in _lines) { l.dispose(); }
    _lines.clear();
    for (final sl in savedLines) {
      final product = sl['product'] as Map<String, dynamic>?;
      final uom     = sl['uom'] as Map<String, dynamic>?;
      final row = _OrderLineRow()
        ..productId = sl['product_id'] as String?
        ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
        ..uomId = sl['uom_id'] as String?
        ..uomLabel = uom?['description'] as String?
        ..uomConversionFactor = (sl['uom_conversion_factor'] as num? ?? 1).toDouble()
        ..taxGroupId = sl['tax_group_id'] as String?
        ..deliveredQty = (sl['delivered_qty'] as num? ?? 0).toDouble()
        ..priceSource = sl['price_source'] as String? ?? 'PRICE_MASTER'
        ..priceResolved = true
        ..sourceQuotationLineSerial = (sl['source_quotation_line_serial'] as num?)?.toInt()
        ..matchedBarcode = sl['barcode'] as String?;
      row.descCtrl.text = sl['item_description'] as String? ?? '';
      row.qtyPackCtrl.text = (sl['qty_pack'] as num? ?? 0).toString();
      row.qtyLooseCtrl.text = (sl['qty_loose'] as num? ?? 0).toString();
      row.rateCtrl.text = (sl['rate'] as num? ?? 0).toString();
      row.discountPctCtrl.text = (sl['discount_percent'] as num? ?? 0).toString();
      row.overrideReasonCtrl.text = sl['price_override_reason'] as String? ?? '';
      row.remarksCtrl.text = sl['remarks'] as String? ?? '';
      _lines.add(row);
    }
    if (!_isAgainstQuotation) {
      for (final row in _lines) {
        if (row.productId != null) unawaited(_refreshLineStockInfo(row));
      }
    }

    final savedCharges = await _ds.getCharges(
      clientId: session.clientId, companyId: session.companyId,
      orderNo: _orderNo!, orderDate: _fmtDate(_orderDate),
    );
    for (final c in _charges) { c.dispose(); }
    _charges.clear();
    for (final sc in savedCharges) {
      final row = _OrderChargeRow()
        ..chargeId = sc['charge_id'] as String?
        ..chargeName = sc['charge_name'] as String? ?? ''
        ..isTaxable = sc['is_taxable'] as bool? ?? false
        ..taxId = sc['tax_id'] as String?
        ..nature = sc['nature'] as String? ?? 'ADD'
        ..glAccountId = sc['gl_account_id'] as String?
        ..amountOrPercent = sc['amount_or_percent'] as String? ?? 'AMOUNT';
      final raw = sc['amount_or_percent'] == 'PERCENT' ? sc['percent'] : sc['amount'];
      row.valueCtrl.text = (raw as num? ?? 0).toString();
      _charges.add(row);
    }

    if (mounted) setState(() => _loading = false);
  }

  /// Against-Quotation entry point. If the source quotation is still
  /// linked to a PROSPECT, the conversion wizard runs first — the Order
  /// is only built once a real customer_id exists.
  Future<void> _loadFromQuotation(String quotationNo, String quotationDate) async {
    final session = ref.read(sessionProvider)!;
    var quote = await _ds.getQuotationHeader(
      clientId: session.clientId, companyId: session.companyId,
      quotationNo: quotationNo, quotationDate: quotationDate,
    );
    if (quote == null || !mounted) {
      setState(() { _loading = false; _error = 'Quotation not found.'; });
      return;
    }

    if (quote['customer_type'] == 'PROSPECT') {
      final ok = await showProspectConversionDialog(
        context,
        ref: ref,
        quotationNo: quotationNo, quotationDate: quotationDate,
        prefillName:    quote['party_name'] as String? ?? '',
        prefillPhone:   quote['party_phone'] as String? ?? '',
        prefillEmail:   quote['party_email'] as String? ?? '',
        prefillAddress: quote['party_address'] as String? ?? '',
      );
      if (ok != true) {
        // Cannot proceed without a real customer — back out to the list.
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      if (!mounted) return;
      quote = await _ds.getQuotationHeader(
        clientId: session.clientId, companyId: session.companyId,
        quotationNo: quotationNo, quotationDate: quotationDate,
      );
      if (quote == null || !mounted) { setState(() => _loading = false); return; }
    }

    final customer = quote['customer'] as Map<String, dynamic>?;
    final currency = quote['currency'] as Map<String, dynamic>?;
    _sourceQuotationNo   = quotationNo;
    _sourceQuotationDate = quotationDate;
    _customerId      = quote['customer_id'] as String?;
    _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
    _locationId          = quote['location_id'] as String? ?? _locationId;
    _salesPersonId        = quote['sales_person_id'] as String?;
    _orderCurrencyId       = quote['quotation_currency_id'] as String?;
    _orderCurrencyCode      = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text  = (quote['rate_to_base']  as num? ?? 1).toString();
    _rateToLocalCtrl.text = (quote['rate_to_local'] as num? ?? 1).toString();

    if (_customerId != null) unawaited(_loadCustomerInfo(_customerId!));

    final qLines = await _ds.getQuotationLines(
      clientId: session.clientId, companyId: session.companyId,
      quotationNo: quotationNo, quotationDate: quotationDate,
    );
    for (final l in _lines) { l.dispose(); }
    _lines.clear();
    for (final ql in qLines) {
      final remaining = (ql['base_qty'] as num? ?? 0).toDouble() - (ql['converted_qty'] as num? ?? 0).toDouble();
      if (remaining <= 0) continue; // fully converted already
      final product  = ql['product'] as Map<String, dynamic>?;
      final uom      = ql['uom'] as Map<String, dynamic>?;
      final row = _OrderLineRow()
        ..productId = ql['product_id'] as String?
        ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
        ..uomId = ql['uom_id'] as String?
        ..uomLabel = uom?['description'] as String?
        ..uomConversionFactor = (ql['uom_conversion_factor'] as num? ?? 1).toDouble()
        ..taxGroupId = ql['tax_group_id'] as String?
        ..priceSource = 'QUOTATION'
        ..priceResolved = true
        ..sourceQuotationLineSerial = ql['serial_no'] as int?
        ..sourceRemainingQty = remaining
        ..matchedBarcode = ql['barcode'] as String?;
      row.descCtrl.text = ql['item_description'] as String? ?? '';
      row.qtyPackCtrl.text = remaining.toString(); // "Qty to Convert" — defaults to full remaining
      row.rateCtrl.text = (ql['rate'] as num? ?? 0).toString();
      row.discountPctCtrl.text = (ql['discount_percent'] as num? ?? 0).toString();
      _lines.add(row);
    }

    // Real gap found live: charges never carried forward from the
    // quotation to the order -- carried verbatim here, same as every
    // other AGAINST_QUOTATION field, since there's nothing left for the
    // client to legitimately choose about a charge that already applied.
    final qCharges = await _ds.getQuotationCharges(
      clientId: session.clientId, companyId: session.companyId,
      quotationNo: quotationNo, quotationDate: quotationDate,
    );
    for (final c in _charges) { c.dispose(); }
    _charges.clear();
    for (final qc in qCharges) {
      final row = _OrderChargeRow()
        ..chargeId = qc['charge_id'] as String?
        ..chargeName = qc['charge_name'] as String? ?? ''
        ..isTaxable = qc['is_taxable'] as bool? ?? false
        ..taxId = qc['tax_id'] as String?
        ..nature = qc['nature'] as String? ?? 'ADD'
        ..glAccountId = qc['gl_account_id'] as String?
        ..amountOrPercent = qc['amount_or_percent'] as String? ?? 'AMOUNT';
      final raw = qc['amount_or_percent'] == 'PERCENT' ? qc['percent'] : qc['amount'];
      row.valueCtrl.text = (raw as num? ?? 0).toString();
      _charges.add(row);
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadCustomerInfo(String customerId) async {
    try {
      final info = await _ds.getCustomerDetails(customerId: customerId);
      if (mounted) setState(() => _customerInfo = info);
    } catch (_) {
      // Display-only convenience — never blocks the screen.
    }
  }

  Future<void> _onCustomerSelected(Map<String, dynamic> account) async {
    final customerId = account['id'] as String;
    setState(() { _customerId = customerId; _customerDisplay = '[${account['account_code']}] ${account['account_name']}'; _customerInfo = null; });
    await _loadCustomerInfo(customerId);
    if (!mounted) return;
    final currRel = _customerInfo?['rim_currencies'];
    final customerCurrency = currRel is Map ? currRel['currency_id'] as String? : null;
    if (customerCurrency != null) {
      final match = _currencies.where((c) => c['currency_id'] == customerCurrency).toList();
      if (match.isNotEmpty) await _onCurrencySelected(match.first);
    }
    // Price is customer-specific — re-resolve every existing line.
    for (final row in _lines) {
      if (row.productId != null) unawaited(_resolvePrice(row));
    }
  }

  Future<void> _onCurrencySelected(Map<String, dynamic> currency) async {
    setState(() {
      _orderCurrencyId   = currency['id'] as String;
      _orderCurrencyCode = currency['currency_id'] as String;
      _rateToBaseCtrl.text  = '1';
      _rateToLocalCtrl.text = '1';
    });
    await _fetchRates();
    if (!_isAgainstQuotation) {
      for (final row in _lines) {
        if (row.productId != null && row.priceSource == 'PRICE_MASTER') unawaited(_resolvePrice(row));
      }
    }
  }

  Future<void> _fetchRates() async {
    if (_orderCurrencyCode == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    if (_orderCurrencyCode != _baseCurrency && _baseCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _orderCurrencyCode!, toCurrency: _baseCurrency, rateDate: _fmtDate(_orderDate));
      if (mounted && r != null) setState(() => _rateToBaseCtrl.text = r.toString());
    } else if (mounted) {
      setState(() => _rateToBaseCtrl.text = '1');
    }
    if (_localCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _orderCurrencyCode!, toCurrency: _localCurrency, rateDate: _fmtDate(_orderDate));
      if (mounted && r != null) setState(() => _rateToLocalCtrl.text = r.toString());
    }
  }

  void _addLine() {
    if (_customerId == null) { _showSnack('Select a Customer first.', color: AppColors.negative); return; }
    setState(() => _lines.add(_OrderLineRow()));
  }
  void _removeLine(_OrderLineRow row) => setState(() { _lines.remove(row); row.dispose(); });
  void _addCharge() => setState(() => _charges.add(_OrderChargeRow()));
  void _removeCharge(_OrderChargeRow row) => setState(() { _charges.remove(row); row.dispose(); });

  bool _isDuplicateProduct(String productId, {_OrderLineRow? excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  Future<void> _onProductSelected(_OrderLineRow row, Map<String, dynamic> product) async {
    final productId = product['id'] as String;
    if (_isDuplicateProduct(productId, excluding: row)) {
      _showSnack('This product is already on another line.', color: AppColors.negative);
      return;
    }
    setState(() {
      row.productId = productId;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.uomId = product['base_uom_id'] as String?;
      final uom = product['uom'] as Map<String, dynamic>?;
      row.uomLabel = uom?['description'] as String?;
      row.taxGroupId ??= product['sales_tax_group_id'] as String?;
      row.costCurrencyId = product['cost_currency_id'] as String?;
    });
    await _resolvePrice(row);
    unawaited(_refreshLineStockInfo(row));
  }

  /// Direct mode only. Resolves fn_get_active_price; a missing price
  /// leaves the line unresolved (hard-blocked at Save unless
  /// can_override_price), never silently defaults to zero-and-editable.
  /// (086) fn_get_active_price converts internally to the order's own
  /// currency — never assume the Price Master batch already matches it.
  Future<void> _resolvePrice(_OrderLineRow row) async {
    if (row.productId == null || row.uomId == null || _customerId == null || _locationId == null || _orderCurrencyCode == null) return;
    setState(() => row.priceLoading = true);
    final session = ref.read(sessionProvider)!;
    try {
      final price = await _ds.getActivePrice(
        clientId: session.clientId, companyId: session.companyId,
        locationId: _locationId!, productId: row.productId!, uomId: row.uomId!,
        customerId: _customerId!, asOfDate: _fmtDate(_orderDate),
        currencyCode: _orderCurrencyCode!,
      );
      if (!mounted) return;
      setState(() {
        row.priceLoading = false;
        if (price != null) {
          row.rateCtrl.text = (price['selling_price'] as num).toString();
          row.priceSource = 'PRICE_MASTER';
          row.priceResolved = true;
          row.overrideEnabled = false;
        } else {
          row.rateCtrl.text = '0';
          row.priceResolved = false;
          row.priceSource = 'MANUAL_OVERRIDE';
          row.overrideEnabled = _canOverridePrice;
        }
      });
    } catch (e) {
      if (mounted) setState(() => row.priceLoading = false);
    }
  }

  void _onToggleOverride(_OrderLineRow row) {
    setState(() { row.overrideEnabled = true; row.priceSource = 'MANUAL_OVERRIDE'; });
  }

  /// Fetches current stock (always, informational hint — never gated) and
  /// cost price (display gated by _canViewCostPrice, but harmless to fetch
  /// alongside since it rides the same row).
  Future<void> _refreshLineStockInfo(_OrderLineRow row) async {
    if (row.productId == null || _locationId == null) return;
    setState(() => row.costLoading = true);
    final session = ref.read(sessionProvider)!;
    try {
      final pl = await _ds.getProductLocationCost(
        clientId: session.clientId, companyId: session.companyId,
        locationId: _locationId!, productId: row.productId!,
      );
      if (!mounted) return;
      setState(() {
        row.availableStock = (pl?['current_stock'] as num? ?? 0).toDouble();
        row.costPrice = (pl?['cost_price'] as num? ?? 0).toDouble();
        row.costLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => row.costLoading = false);
    }
  }

  Future<void> _onBarcodeSubmitted(_OrderLineRow row, String rawBarcode) async {
    final code = rawBarcode.trim();
    if (code.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    Map<String, dynamic>? match;
    try {
      match = await _ds.getProductByCode(
        clientId: session.clientId, companyId: session.companyId,
        code: code, tryPartNumber: session.enablePartNumber,
      );
    } catch (e) {
      if (mounted) _showSnack('Lookup failed: $e', color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    if (match == null) { _showSnack('No product found for "$code".', color: AppColors.negative); return; }
    final matchedProduct = match;
    await _onProductSelected(row, matchedProduct);
    if (mounted && row.productId == matchedProduct['id']) {
      setState(() {
        row.uomId = matchedProduct['matched_uom_id'] as String? ?? row.uomId;
        row.uomConversionFactor = (matchedProduct['matched_uom_conversion_factor'] as num? ?? 1).toDouble();
        row.matchedBarcode = code;
        row.barcodeCtrl.clear();
      });
      await _resolvePrice(row);
    }
  }

  void _onChargeSelected(_OrderChargeRow row, Map<String, dynamic> charge) {
    setState(() {
      row.chargeId = charge['id'] as String;
      row.chargeName = charge['charge_name'] as String;
      row.isTaxable = charge['is_taxable'] as bool? ?? false;
      row.taxId = charge['tax_id'] as String?;
      row.nature = charge['nature'] as String? ?? 'ADD';
      row.glAccountId = charge['default_gl_account_id'] as String?;
      row.amountOrPercent = charge['amount_or_percent'] as String? ?? 'AMOUNT';
      final defaultVal = row.amountOrPercent == 'PERCENT' ? charge['default_percent'] : charge['default_amount'];
      row.valueCtrl.text = (defaultVal as num? ?? 0).toString();
    });
  }

  // ── Computed totals ───────────────────────────────────────────────────────

  void _recompute() {
    double subtotalBeforeCharges = 0;
    for (final l in _lines) {
      // Against-Quotation: qtyPackCtrl is the single "Qty to Convert"
      // base-quantity field — see _OrderLineRow's own comment.
      l.baseQty = _isAgainstQuotation ? l.qtyPack : (l.qtyPack * l.uomConversionFactor + l.qtyLoose);
      l.grossAmount    = l.baseQty * l.rate;
      l.discountAmount = l.grossAmount * l.discountPct / 100;
      l.taxableAmount  = l.grossAmount - l.discountAmount;
      final ratePct    = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount      = l.taxableAmount * ratePct / 100;
      l.finalAmount    = l.taxableAmount + l.taxAmount;
      subtotalBeforeCharges += l.taxableAmount;
    }
    for (final c in _charges) {
      c.amount = c.amountOrPercent == 'PERCENT' ? subtotalBeforeCharges * c.value / 100 : c.value;
      final chargeRatePct = c.isTaxable && c.taxId != null ? (_taxRatePct[c.taxId] ?? 0) : 0;
      c.taxAmount = c.amount * chargeRatePct / 100;
      c.allocationFactor = subtotalBeforeCharges > 0 ? c.amount / subtotalBeforeCharges : 0;
    }
    for (final l in _lines) {
      double share = 0;
      for (final c in _charges) {
        final signed = c.nature == 'DEDUCT' ? -c.allocationFactor : c.allocationFactor;
        share += signed * l.taxableAmount;
      }
      l.chargeAmount = share;
      l.landedAmount = l.finalAmount + l.chargeAmount;
    }
  }

  double get _grossTotal     => _lines.fold(0.0, (s, l) => s + l.grossAmount);
  double get _discountTotal  => _lines.fold(0.0, (s, l) => s + l.discountAmount);
  double get _itemTaxTotal   => _lines.fold(0.0, (s, l) => s + l.taxAmount);
  double get _chargesTotal   => _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));
  double get _chargeTaxTotal => _charges.fold(0.0, (s, c) => s + c.taxAmount);
  double get _grandTotal     => _lines.fold(0.0, (s, l) => s + l.finalAmount) + _chargesTotal + _chargeTaxTotal;

  // ── Save / Approve / Cancel ──────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_customerId == null) { _showSnack('Select a customer.', color: AppColors.negative); return false; }
    if (_orderCurrencyId == null) { _showSnack('Select a currency.', color: AppColors.negative); return false; }
    if (_locationId == null) { _showSnack('Select a location.', color: AppColors.negative); return false; }
    final validLines = _lines.where((l) => l.productId != null && l.baseQty > 0).toList();
    if (validLines.isEmpty) { _showSnack('Add at least one line with a product and quantity.', color: AppColors.negative); return false; }

    if (!_isAgainstQuotation) {
      for (final l in validLines) {
        if (!l.priceResolved && !_canOverridePrice) {
          _showSnack('${l.productDisplay}: no active price configured, and you are not authorized to override it.', color: AppColors.negative);
          return false;
        }
        // Real bug found live: a line could be saved with rate=0 (e.g. an
        // override left blank) with no pushback at all -- an order with
        // real quantity but zero price/value.
        if (l.rate <= 0) {
          _showSnack('${l.productDisplay}: rate must be greater than zero.', color: AppColors.negative);
          return false;
        }
        if (l.priceSource == 'MANUAL_OVERRIDE' && l.overrideReasonCtrl.text.trim().isEmpty) {
          _showSnack('${l.productDisplay}: enter a reason for the price override.', color: AppColors.negative);
          return false;
        }
        if (l.discountPct > 0) {
          if (!_canGiveDiscount) {
            _showSnack('${l.productDisplay}: you are not authorized to give a discount.', color: AppColors.negative);
            return false;
          }
          // Absolute ceiling, independent of whether this user has a
          // configured per-user limit at all -- real bug found live: a
          // user with no ric_user_sales_controls row (max_discount_percent
          // = null) could enter e.g. 150% since the limit check below was
          // only ever skipped, never replaced with a hard ceiling.
          if (l.discountPct > 100) {
            _showSnack('${l.productDisplay}: discount cannot exceed 100%.', color: AppColors.negative);
            return false;
          }
          if (_maxDiscountPercent != null && l.discountPct > _maxDiscountPercent!) {
            _showSnack('${l.productDisplay}: discount ${l.discountPct}% exceeds your authorized maximum of $_maxDiscountPercent%.', color: AppColors.negative);
            return false;
          }
        }
      }
    } else {
      for (final l in validLines) {
        if (l.baseQty > l.sourceRemainingQty) {
          _showSnack('${l.productDisplay}: cannot convert more than the remaining ${l.sourceRemainingQty} on the quotation.', color: AppColors.negative);
          return false;
        }
      }
    }

    // Real bug found live: a charge's Amount field accepted a negative
    // number with no validation at all.
    for (final c in _charges.where((c) => c.chargeId != null)) {
      if (c.value < 0) {
        _showSnack('${c.chargeName}: amount cannot be negative.', color: AppColors.negative);
        return false;
      }
    }

    _recompute();
    // Grand total must never go negative -- a legitimate DEDUCT charge or
    // discount could otherwise push the order below zero with no warning.
    if (_grandTotal < 0) {
      _showSnack('Order total cannot be negative -- check discounts and charges.', color: AppColors.negative);
      return false;
    }
    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':             session.clientId,
        'company_id':            session.companyId,
        'location_id':           _locationId,
        'order_no':              _orderNo,
        'order_date':            _fmtDate(_orderDate),
        'order_mode':            _orderMode,
        'source_quotation_no':   _sourceQuotationNo,
        'source_quotation_date': _sourceQuotationDate,
        'customer_id':           _customerId,
        'customer_po_ref':       _customerPoRefCtrl.text.trim(),
        'ship_to':               _shipToCtrl.text.trim(),
        'bill_to':               _billToCtrl.text.trim(),
        'expected_delivery_date': _expectedDeliveryDate != null ? _fmtDate(_expectedDeliveryDate!) : null,
        'sales_person_id':       _salesPersonId,
        'order_currency_id':     _orderCurrencyId,
        'rate_to_base':          double.tryParse(_rateToBaseCtrl.text) ?? 1,
        'rate_to_local':         double.tryParse(_rateToLocalCtrl.text) ?? 1,
        'payment_term_id':       _paymentTermId,
        'incoterm_id':           _incotermId,
        'delivery_instructions': _deliveryInstructionsCtrl.text.trim(),
        'gross_amount':          _grossTotal,
        'discount_amount':       _discountTotal,
        'charges_amount':        _chargesTotal,
        'tax_amount':            _itemTaxTotal + _chargeTaxTotal,
        'grand_total':           _grandTotal,
        'remarks':               _remarksCtrl.text.trim(),
      };
      final lines = validLines.asMap().entries.map((e) => {
        'serial_no':                    e.key + 1,
        'product_id':                   e.value.productId,
        'item_description':             e.value.descCtrl.text.trim(),
        'barcode':                      e.value.matchedBarcode ?? '',
        'uom_id':                       e.value.uomId,
        'uom_conversion_factor':        e.value.uomConversionFactor,
        // AGAINST_QUOTATION: qtyPackCtrl holds the "Qty to Convert" value
        // (see _loadFromQuotation/_recompute's own comments) -- it must
        // still be sent, not zeroed. fn_save_sales_order does NOT copy
        // quantity verbatim from the source line for this mode (unlike
        // rate/discount_percent, which it does) -- partial-quantity
        // conversion needs the client's own qty_pack/base_qty. Sending 0
        // here silently saved every against-quotation order line with
        // zero qty and zero value (real bug, found live). qty_loose has
        // no meaning in this mode (base_qty = qtyPack directly, see
        // _recompute), so 0 there is correct.
        'qty_pack':                     e.value.qtyPack,
        'qty_loose':                    _isAgainstQuotation ? 0 : e.value.qtyLoose,
        'base_qty':                     e.value.baseQty,
        'rate':                         e.value.rate,
        'price_override_reason':       e.value.overrideReasonCtrl.text.trim(),
        'gross_amount':                 e.value.grossAmount,
        'discount_percent':             e.value.discountPct,
        'discount_amount':              e.value.discountAmount,
        'tax_group_id':                 e.value.taxGroupId,
        'tax_amount':                   e.value.taxAmount,
        'final_amount':                 e.value.finalAmount,
        'base_amount':                  e.value.finalAmount * (double.tryParse(_rateToBaseCtrl.text) ?? 1),
        'local_amount':                 e.value.finalAmount * (double.tryParse(_rateToLocalCtrl.text) ?? 1),
        'charge_amount':                e.value.chargeAmount,
        'landed_amount':                e.value.landedAmount,
        'source_quotation_line_serial': e.value.sourceQuotationLineSerial,
        'remarks':                      e.value.remarksCtrl.text.trim(),
      }).toList();
      final charges = _charges.where((c) => c.chargeId != null).toList().asMap().entries.map((e) => {
        'serial_no':          e.key + 1,
        'charge_id':          e.value.chargeId,
        'charge_name':        e.value.chargeName,
        'is_taxable':         e.value.isTaxable,
        'tax_id':             e.value.taxId,
        'nature':             e.value.nature,
        'gl_account_id':      e.value.glAccountId,
        'amount_or_percent':  e.value.amountOrPercent,
        'percent':            e.value.amountOrPercent == 'PERCENT' ? e.value.value : null,
        'amount':             e.value.amount,
        'tax_amount':         e.value.taxAmount,
        'allocation_factor':  e.value.allocationFactor,
      }).toList();

      if (session.offlineMode) {
        if (_isAgainstQuotation) {
          throw StateError('Against-Quotation orders require an online connection.');
        }
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'SALES_ORDER',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_sales_order',
          payload:      {'p_header': header, 'p_lines': lines, 'p_charges': charges, 'p_user_id': session.userId},
        );
        await _ds.cacheOrderLocally(effectiveOrderNo: localId, header: header, lines: lines, charges: charges);
        if (mounted) {
          setState(() { _orderNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final orderNo = await _ds.save(header: header, lines: lines, charges: charges, userId: session.userId);
        unawaited(_ds.cacheOrderLocally(effectiveOrderNo: orderNo, header: header, lines: lines, charges: charges));
        if (mounted) {
          setState(() { _orderNo = orderNo; _saving = false; });
          _showSnack('Sales Order $orderNo saved.', color: AppColors.positive);
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

  Future<void> _approve() async {
    if (_orderNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Sales Order'),
        content: const Text('Once approved, this order can no longer be edited. Continue?'),
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
        orderNo: _orderNo!, orderDate: _fmtDate(_orderDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Order $_orderNo approved.', color: AppColors.positive);
        await _loadExisting(_orderNo!, _fmtDate(_orderDate));
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  Future<void> _cancel() async {
    if (_orderNo == null) return;
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel Sales Order'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This marks the order as cancelled. Continue?'),
          const SizedBox(height: 12),
          TextFormField(
            controller: reasonCtrl,
            autofocus: true,
            decoration: InputDecoration(border: const OutlineInputBorder(), label: _req('Reason')),
            maxLines: 2,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(), child: const Text('No')),
          FilledButton(
            onPressed: () {
              if (reasonCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Enter a reason for cancelling this order.'), backgroundColor: Colors.orange),
                );
                return;
              }
              Navigator.of(dialogContext, rootNavigator: true).pop(reasonCtrl.text.trim());
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            child: const Text('Cancel Order'),
          ),
        ],
      ),
    );
    reasonCtrl.dispose();
    if (reason == null || reason.isEmpty) return;

    final session = ref.read(sessionProvider)!;
    setState(() { _cancelling = true; _actionError = null; });
    try {
      await _ds.cancel(
        clientId: session.clientId, companyId: session.companyId,
        orderNo: _orderNo!, orderDate: _fmtDate(_orderDate), reason: reason, userId: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Order $_orderNo cancelled.', color: AppColors.positive);
        await _loadExisting(_orderNo!, _fmtDate(_orderDate));
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    return e.message ?? e.toString();
  }

  // ── Print ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    _recompute();
    return {
      'company': company,
      'header': {
        'order_no':          _orderNo ?? '',
        'order_date':        _displayDate(_orderDate),
        'order_mode':        _isAgainstQuotation ? 'Against Quotation' : 'Direct',
        'source_quotation':  _sourceQuotationNo ?? '',
        'status':            _status,
        'customer_name':     _customerDisplay.contains('] ') ? _customerDisplay.split('] ').last : _customerDisplay,
        'customer_po_ref':   _customerPoRefCtrl.text,
        'ship_to':           _shipToCtrl.text,
        'bill_to':           _billToCtrl.text,
        'expected_delivery_date': _expectedDeliveryDate != null ? _displayDate(_expectedDeliveryDate) : '',
        'sales_person_name': _salesPersonDisplay,
        'currency_code':     _orderCurrencyCode ?? '',
        'payment_term_name': _paymentTermDisplay,
        'incoterm_label':    _incotermDisplay,
        'delivery_instructions': _deliveryInstructionsCtrl.text,
        'remarks':           _remarksCtrl.text,
      },
      'lines': _lines.where((l) => l.productId != null && l.baseQty > 0).map((l) => {
        'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
        'uom_label':    l.uomLabel ?? '',
        'base_qty':     l.baseQty,
        'rate':         l.rate,
        'final_amount': l.landedAmount,
      }).toList(),
      'charges': _charges.where((c) => c.chargeId != null).map((c) => {
        'charge_name': c.chargeName,
        'amount':      c.amount,
      }).toList(),
      'totals': {
        'gross_amount':    _grossTotal,
        'discount_amount': _discountTotal,
        'tax_amount':      _itemTaxTotal + _chargeTaxTotal,
        'charges_amount':  _chargesTotal,
        'grand_total':     _grandTotal,
      },
      'signatures': {
        'prepared_by': _preparedByName ?? '',
        'authorised_by': _authorisedByName ?? '',
      },
    };
  }

  Future<void> _printOrder() async {
    if (_orderNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('SALES_ORDER').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_orderNo.pdf');
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
      onPressed: _printing ? null : _printOrder,
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

  // _users is loaded once in _init() (getUsersForAutocomplete, id+full_name)
  // — reused here for print's Prepared By/Authorised Signatory names.
  String? _resolveUserName(String? userId) {
    if (userId == null) return null;
    final match = _users.firstWhere((u) => u['id'] == userId, orElse: () => const {});
    return match['full_name'] as String?;
  }

  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> onPicked) async {
    final d = await showDatePicker(context: context, initialDate: current ?? DateTime.now(),
        firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d != null) onPicked(d);
  }

  static Widget _req(String text) => RichText(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
      children: const [TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    _recompute();
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final showLooseQty = !_isAgainstQuotation && (session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
    final showBarcode  = !_isAgainstQuotation && (session?.enableBarcode ?? false);

    final canSave     = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final showApprove = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;
    final showCancel  = !isOffline && (_status == 'DRAFT' || _status == 'APPROVED') && canApprove && !_isNew;
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
                  const SizedBox(height: 10),
                  Row(children: [
                    if (_orderNo != null) _buildPrintButton(),
                    Expanded(child: _buildActionButtons(canSave: canSave, showApprove: showApprove, showCancel: showCancel)),
                  ]),
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_orderNo != null) _buildPrintButton(),
                  _buildActionButtons(canSave: canSave, showApprove: showApprove, showCancel: showCancel),
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
                    _buildLinesCard(locked, showLooseQty, showBarcode),
                    const SizedBox(height: 16),
                    _buildChargesCard(locked),
                    const SizedBox(height: 16),
                    _buildTotalsCard(),
                  ]),
                ),
        ),
      ],
    );
  }

  // Back button duplicated here (in addition to TopBar's own, app-wide one)
  // per explicit user feedback: on an entry screen the user's focus and
  // mouse/eye are on the document header itself (right next to the Print
  // button), not the far top-left corner of the chrome -- same reasoning
  // as why Print/Save/Approve already live here rather than at the bottom.
  // TopBar's back arrow stays too (it's the only affordance on screens with
  // no in-content title block, e.g. list screens), this is additive.
  Widget _buildTitleBlock() => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (context.canPop())
        IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_orderNo != null ? 'Sales Order · $_orderNo' : 'New Sales Order',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        Row(children: [
          _orderNo != null ? _statusChip(_status) : const Text('Unsaved draft', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (_isAgainstQuotation) ...[
            const SizedBox(width: 8),
            Text('From $_sourceQuotationNo', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ],
          if (_orderNo != null) ...[
            const SizedBox(width: 8),
            PendingSyncBadge(documentType: 'SALES_ORDER', documentId: _orderNo!),
          ],
        ]),
      ]),
    ],
  );

  Widget _statusChip(String status) {
    final color = switch (status) {
      'DRAFT'                => AppColors.badgeDraft,
      'APPROVED'              => AppColors.positive,
      'PARTIALLY_DELIVERED'    => AppColors.secondary,
      'DELIVERED'               => AppColors.textSecondary,
      'CANCELLED'                => AppColors.negative,
      _                            => AppColors.positive,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status.replaceAll('_', ' '), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool showApprove, required bool showCancel}) =>
      Wrap(spacing: 12, runSpacing: 8, children: [
        if (canSave) FilledButton(
          onPressed: _saving ? null : _saveDraft,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save Draft'),
        ),
        if (showApprove) FilledButton(
          onPressed: _approving ? null : _approve,
          style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
          child: _approving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Approve'),
        ),
        if (showCancel) OutlinedButton(
          onPressed: _cancelling ? null : _cancel,
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.negative, side: const BorderSide(color: AppColors.negative)),
          child: _cancelling
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Cancel Order'),
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
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    const fh = 56.0;
    Widget field(Widget child) => SizedBox(height: fh, child: child);
    final showRate = _orderCurrencyCode != null && _orderCurrencyCode != _baseCurrency;
    final customerLocked = locked || _isAgainstQuotation;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Order No/Date moved to the top row — real user feedback: date
          // should be picked first, before Customer/Location/PO Ref, not
          // buried in a "weird" middle row.
          Builder(builder: (_) {
            final f1 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Order No'),
              child: Text(_orderNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _orderNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f2 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_orderDate, (d) { setState(() => _orderDate = d); unawaited(_fetchRates()); }),
              child: InputDecorator(
                decoration: dec.copyWith(label: _req('Order Date'),
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_orderDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            final f3 = field(Autocomplete<Map<String, dynamic>>(
              initialValue: TextEditingValue(text: _salesPersonDisplay),
              displayStringForOption: (u) => u['full_name'] as String,
              optionsBuilder: (v) {
                if (locked) return const [];
                final q = v.text.toLowerCase().trim();
                if (q.isEmpty) return _users;
                return _users.where((u) => (u['full_name'] as String).toLowerCase().contains(q));
              },
              onSelected: (u) => setState(() { _salesPersonId = u['id'] as String; _salesPersonDisplay = u['full_name'] as String; }),
              fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                controller: textCtrl, focusNode: focusNode, enabled: !locked,
                decoration: dec.copyWith(labelText: 'Sales Person'),
                style: const TextStyle(fontSize: 13),
              ),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f3),
                  ])
                : Row(children: [
                    Expanded(flex: 2, child: f1), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f3),
                  ]);
          }),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(customerLocked
                ? InputDecorator(
                    decoration: dec.copyWith(labelText: 'Customer'),
                    child: Text(_customerDisplay.isEmpty ? '—' : _customerDisplay, style: const TextStyle(fontSize: 13)),
                  )
                : Autocomplete<Map<String, dynamic>>(
                    initialValue: TextEditingValue(text: _customerDisplay),
                    displayStringForOption: (a) => '[${a['account_code']}] ${a['account_name']}',
                    optionsBuilder: (v) async {
                      final accounts = await ref.read(accountsProvider.future);
                      // posting_allowed=false rows are the Customer group/parent
                      // node itself (Chart of Accounts hierarchy), not a real
                      // customer to bill against -- real bug found live: the
                      // group node was showing up as a selectable "customer".
                      final customers = accounts.where((a) => a['account_nature'] == 'Customer' && a['posting_allowed'] == true);
                      final q = v.text.toLowerCase().trim();
                      if (q.isEmpty) return customers;
                      return customers.where((a) =>
                          (a['account_code'] as String).toLowerCase().contains(q) ||
                          (a['account_name'] as String).toLowerCase().contains(q));
                    },
                    onSelected: _onCustomerSelected,
                    fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                      controller: textCtrl, focusNode: focusNode,
                      decoration: dec.copyWith(label: _req('Customer')),
                      style: const TextStyle(fontSize: 13),
                    ),
                    optionsViewBuilder: (context, onSel, opts) => Align(
                      alignment: Alignment.topLeft,
                      child: Material(elevation: 4, borderRadius: BorderRadius.circular(4),
                        child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 260, minWidth: 280),
                          child: ListView.builder(padding: EdgeInsets.zero, shrinkWrap: true, itemCount: opts.length,
                            itemBuilder: (context, idx) {
                              final a = opts.elementAt(idx);
                              return InkWell(onTap: () => onSel(a),
                                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Text('[${a['account_code']}] ${a['account_name']}', style: const TextStyle(fontSize: 13))));
                            }),
                        ),
                      ),
                    ),
                  ));
            final f2 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(label: _req('Location')),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _locationId,
              items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) { setState(() => _locationId = v); unawaited(_fetchRates()); },
            ));
            final f3 = field(TextFormField(
              controller: _customerPoRefCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Customer PO Ref'),
              style: const TextStyle(fontSize: 13),
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
          if (_customerInfo != null) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Credit Limit: ${(_customerInfo!['credit_limit'] as num?)?.toStringAsFixed(2) ?? '—'}'
              '   ·   Credit Days: ${_customerInfo!['credit_days'] ?? '—'}'
              '${_customerInfo!['is_credit_blocked'] == true ? '   ·   ⚠ CREDIT BLOCKED (info only)' : ''}',
              style: TextStyle(fontSize: 11,
                  color: _customerInfo!['is_credit_blocked'] == true ? AppColors.negative : AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(label: _req('Currency')),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _orderCurrencyId,
              items: _currencies.map((c) => DropdownMenuItem(value: c['id'] as String,
                  child: Text(c['currency_id'] as String, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (locked || _isAgainstQuotation) ? null : (v) {
                final c = _currencies.firstWhere((e) => e['id'] == v);
                unawaited(_onCurrencySelected(c));
              },
            ));
            final f2 = field(TextFormField(
              controller: _rateToBaseCtrl, enabled: !locked && !_isAgainstQuotation && showRate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'Rate to Base ($_baseCurrency)'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ));
            final f3 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Payment Term'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _paymentTermId,
              items: _paymentTerms.map((t) => DropdownMenuItem(value: t['id'] as String,
                  child: Text(t['term_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() {
                _paymentTermId = v;
                _paymentTermDisplay = v == null ? '' : (_paymentTerms.firstWhere((t) => t['id'] == v)['term_name'] as String);
              }),
            ));
            final f4 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Incoterm'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _incotermId,
              items: _incoterms.map((t) => DropdownMenuItem(value: t['id'] as String,
                  child: Text(t['description'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() {
                _incotermId = v;
                _incotermDisplay = v == null ? '' : (_incoterms.firstWhere((t) => t['id'] == v)['description'] as String);
              }),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]), const SizedBox(height: 8),
                    Row(children: [Expanded(child: f3), const SizedBox(width: 12), Expanded(child: f4)]),
                  ])
                : Row(children: [
                    Expanded(child: f1), const SizedBox(width: 12),
                    Expanded(child: f2), const SizedBox(width: 12),
                    Expanded(child: f3), const SizedBox(width: 12),
                    Expanded(child: f4),
                  ]);
          }),
          if (_paymentTermId != null) Builder(builder: (_) {
            final desc = _paymentTerms.firstWhere((t) => t['id'] == _paymentTermId, orElse: () => const {})['description'] as String?;
            if (desc == null || desc.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(desc, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            );
          }),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(TextFormField(
              controller: _shipToCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Ship To'),
              style: const TextStyle(fontSize: 13),
            ));
            final f2 = field(TextFormField(
              controller: _billToCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Bill To'),
              style: const TextStyle(fontSize: 13),
            ));
            final f3 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_expectedDeliveryDate, (d) => setState(() => _expectedDeliveryDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(labelText: 'Expected Delivery',
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_expectedDeliveryDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            final f4 = field(TextFormField(
              controller: _deliveryInstructionsCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Delivery Instructions'),
              style: const TextStyle(fontSize: 13),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]), const SizedBox(height: 8),
                    Row(children: [Expanded(child: f3), const SizedBox(width: 12), Expanded(child: f4)]),
                  ])
                : Row(children: [
                    Expanded(child: f1), const SizedBox(width: 12),
                    Expanded(child: f2), const SizedBox(width: 12),
                    Expanded(child: f3), const SizedBox(width: 12),
                    Expanded(child: f4),
                  ]);
          }),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: field(TextFormField(
            controller: _remarksCtrl, enabled: !locked,
            decoration: dec.copyWith(labelText: 'Remarks'),
            style: const TextStyle(fontSize: 13),
          ))),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked, bool showLooseQty, bool showBarcode) {
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
            if (!locked && !_isAgainstQuotation) TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
          ]),
          const SizedBox(height: 8),
          if (_lines.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else if (_isAgainstQuotation)
            ..._lines.map((row) => _buildQuotationLineRow(row, locked, dec))
          else
            ..._lines.map((row) => _buildDirectLineRow(row, locked, showLooseQty, showBarcode, dec)),
        ]),
      ),
    );
  }

  Widget _buildDirectLineRow(_OrderLineRow row, bool locked, bool showLooseQty, bool showBarcode, InputDecoration dec) {
    final rateEditable = !locked && (row.overrideEnabled || !row.priceResolved);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 220,
              child: Autocomplete<Map<String, dynamic>>(
                key: ValueKey('${row.hashCode}-${row.productDisplay}'),
                initialValue: TextEditingValue(text: row.productDisplay),
                displayStringForOption: (p) => '[${p['product_code']}] ${p['product_name']}',
                optionsBuilder: (v) {
                  if (locked) return const [];
                  final q = v.text.toLowerCase().trim();
                  if (q.isEmpty) return _products;
                  return _products.where((p) =>
                      (p['product_code'] as String).toLowerCase().contains(q) ||
                      (p['product_name'] as String).toLowerCase().contains(q));
                },
                onSelected: (p) => _onProductSelected(row, p),
                fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                  controller: textCtrl, focusNode: focusNode, enabled: !locked,
                  decoration: dec.copyWith(labelText: 'Product'),
                  style: const TextStyle(fontSize: 13),
                ),
                optionsViewBuilder: (context, onSel, opts) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(elevation: 4, borderRadius: BorderRadius.circular(4),
                    child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 260, minWidth: 260),
                      child: ListView.builder(padding: EdgeInsets.zero, shrinkWrap: true, itemCount: opts.length,
                        itemBuilder: (context, idx) {
                          final p = opts.elementAt(idx);
                          return InkWell(onTap: () => onSel(p),
                              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Text('[${p['product_code']}] ${p['product_name']}', style: const TextStyle(fontSize: 13))));
                        }),
                    ),
                  ),
                ),
              ),
            ),
            if (showBarcode) SizedBox(width: 110, child: TextFormField(
              controller: row.barcodeCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Barcode'),
              style: const TextStyle(fontSize: 13),
              onFieldSubmitted: (v) => _onBarcodeSubmitted(row, v),
            )),
            SizedBox(width: 90, child: TextFormField(
              controller: row.qtyPackCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: showLooseQty ? 'Qty Pack' : 'Quantity', suffixText: row.uomLabel),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            )),
            if (showLooseQty) SizedBox(width: 90, child: TextFormField(
              controller: row.qtyLooseCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'Qty Loose', suffixText: row.uomLabel),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            )),
            SizedBox(width: 100, child: row.priceLoading
                ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : TextFormField(
                    controller: row.rateCtrl, enabled: rateEditable,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Rate',
                        suffixIcon: (!locked && _canOverridePrice && row.priceResolved && !row.overrideEnabled)
                            ? IconButton(icon: const Icon(Icons.edit, size: 14), tooltip: 'Override price', onPressed: () => _onToggleOverride(row))
                            : null),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                  )),
            if (_canGiveDiscount) SizedBox(width: 80, child: TextFormField(
              controller: row.discountPctCtrl, enabled: !locked,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'Disc %'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            )),
            SizedBox(width: 170, child: DropdownButtonFormField<String>(
              decoration: dec.copyWith(labelText: 'Tax Group'),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: row.taxGroupId,
              items: _taxGroups.map((g) => DropdownMenuItem(value: g['id'] as String,
                  child: Text(g['group_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) => setState(() => row.taxGroupId = v),
            )),
            SizedBox(width: 90, child: Text('Amt: ${row.finalAmount.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
            SizedBox(width: 110, child: Text('Landed: ${row.landedAmount.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary))),
            if (row.productId != null) SizedBox(width: 90, child: row.costLoading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Stock: ${row.availableStock.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
            if (_canViewCostPrice) SizedBox(width: 90, child: row.costLoading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Cost: ${row.costPrice.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
            if (!locked) IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
              onPressed: () => _removeLine(row),
            ),
          ]),
          if (row.priceSource == 'MANUAL_OVERRIDE') Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(width: 320, child: TextFormField(
              controller: row.overrideReasonCtrl, enabled: !locked,
              decoration: dec.copyWith(label: _req('Override Reason')),
              style: const TextStyle(fontSize: 13),
            )),
          ),
        ]),
      ),
    );
  }

  Widget _buildQuotationLineRow(_OrderLineRow row, bool locked, InputDecoration dec) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 220, child: InputDecorator(
            decoration: dec.copyWith(labelText: 'Product'),
            child: Text(row.productDisplay, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          )),
          SizedBox(width: 110, child: TextFormField(
            controller: row.qtyPackCtrl, enabled: !locked,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: dec.copyWith(labelText: 'Qty to Convert', suffixText: row.uomLabel),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) => setState(() {}),
          )),
          SizedBox(width: 90, child: Text('of ${row.sourceRemainingQty.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
          SizedBox(width: 90, child: InputDecorator(
            decoration: dec.copyWith(labelText: 'Rate (frozen)'),
            child: Text(row.rate.toStringAsFixed(2), style: const TextStyle(fontSize: 13)),
          )),
          if (row.discountPct > 0) SizedBox(width: 80, child: InputDecorator(
            decoration: dec.copyWith(labelText: 'Disc % (frozen)'),
            child: Text(row.discountPct.toStringAsFixed(2), style: const TextStyle(fontSize: 13)),
          )),
          SizedBox(width: 90, child: Text('Amt: ${row.finalAmount.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          SizedBox(width: 110, child: Text('Landed: ${row.landedAmount.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary))),
        ]),
      ),
    );
  }

  Widget _buildChargesCard(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Charges (optional — always editable)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (!locked) TextButton.icon(onPressed: _addCharge, icon: const Icon(Icons.add, size: 16), label: const Text('Add Charge')),
          ]),
          const SizedBox(height: 8),
          if (_charges.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('No charges added.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._charges.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(width: 200, child: DropdownButtonFormField<String>(
                  decoration: dec.copyWith(labelText: 'Charge'),
                  isExpanded: true, isDense: true, itemHeight: null,
                  initialValue: row.chargeId,
                  items: _additionalCharges.map((c) => DropdownMenuItem(value: c['id'] as String,
                      child: Text(c['charge_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: locked ? null : (v) {
                    final c = _additionalCharges.firstWhere((e) => e['id'] == v);
                    _onChargeSelected(row, c);
                  },
                )),
                SizedBox(width: 100, child: TextFormField(
                  controller: row.valueCtrl, enabled: !locked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: row.amountOrPercent == 'PERCENT' ? 'Percent' : 'Amount'),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() {}),
                )),
                SizedBox(width: 90, child: Text('${row.nature} · ${row.amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                if (row.isTaxable) SizedBox(width: 90, child: Text('Tax: ${row.taxAmount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                if (!locked) IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                  onPressed: () => _removeCharge(row),
                ),
              ]),
            )),
        ]),
      ),
    );
  }

  Widget _buildTotalsCard() {
    Widget row(String label, double value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Text(label, style: TextStyle(fontSize: bold ? 14 : 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: bold ? AppColors.primary : AppColors.textSecondary)),
        const SizedBox(width: 16),
        SizedBox(width: 110, child: Text(value.toStringAsFixed(2), textAlign: TextAlign.right,
            style: TextStyle(fontSize: bold ? 15 : 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: bold ? AppColors.primary : AppColors.textPrimary))),
      ]),
    );
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          row('Subtotal', _grossTotal),
          row('Discount', -_discountTotal),
          row('Tax', _itemTaxTotal + _chargeTaxTotal),
          row('Charges', _chargesTotal),
          const Divider(),
          row('Grand Total', _grandTotal, bold: true),
        ]),
      ),
    );
  }
}

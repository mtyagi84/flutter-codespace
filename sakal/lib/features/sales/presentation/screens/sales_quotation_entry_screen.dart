import 'dart:async';

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
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../domain/repositories/sales_quotation_repository.dart';
import '../providers/sales_quotation_providers.dart';

class _QuotationLineRow {
  String? productId;
  String  productDisplay = '';
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController barcodeCtrl = TextEditingController();
  String? matchedBarcode; // exact barcode string that resolved this line's product/UOM
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  final TextEditingController rateCtrl     = TextEditingController(text: '0');
  final TextEditingController discountPctCtrl = TextEditingController(text: '0');
  String? taxGroupId;
  final TextEditingController remarksCtrl = TextEditingController();
  double  convertedQty = 0; // rollup, only set when reloading an existing line
  bool    priceLoading = false;

  // Recomputed every build by _recompute()
  double baseQty        = 0;
  double grossAmount    = 0;
  double discountAmount = 0;
  double taxableAmount  = 0;
  double taxAmount      = 0;
  double finalAmount    = 0;
  double chargeAmount   = 0; // this line's apportioned share of _charges
  double landedAmount   = 0; // finalAmount + chargeAmount — all-inclusive price shown to customer

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
  }
}

class _QuotationChargeRow {
  String? chargeId;
  String  chargeName = '';
  bool    isTaxable = false;
  String? taxId;
  String  nature = 'ADD';
  String? glAccountId;
  String  amountOrPercent = 'AMOUNT';
  final TextEditingController valueCtrl = TextEditingController(text: '0');

  double amount           = 0; // recomputed
  double taxAmount        = 0; // recomputed
  double allocationFactor = 0; // recomputed — amount / quotation value before charges

  double get value => double.tryParse(valueCtrl.text) ?? 0;

  void dispose() => valueCtrl.dispose();
}

class SalesQuotationEntryScreen extends ConsumerStatefulWidget {
  final String? editQuotationNo;
  final String? editQuotationDate;
  const SalesQuotationEntryScreen({super.key, this.editQuotationNo, this.editQuotationDate});

  @override
  ConsumerState<SalesQuotationEntryScreen> createState() => _SalesQuotationEntryScreenState();
}

class _SalesQuotationEntryScreenState extends ConsumerState<SalesQuotationEntryScreen>
    with ScreenPermissionMixin<SalesQuotationEntryScreen> {
  @override String get screenName => RouteNames.salesQuotations;

  SalesQuotationRepository get _ds => ref.read(salesQuotationRepositoryProvider);

  String?  _quotationNo;
  DateTime _quotationDate  = DateTime.now();
  DateTime _validUntilDate = DateTime.now().add(const Duration(days: 15));
  String   _status = 'DRAFT';
  String?  _locationId;
  String   _customerType = 'CUSTOMER'; // CUSTOMER | PROSPECT
  String?  _customerId;
  String   _customerDisplay = '';
  Map<String, dynamic>? _customerInfo; // credit_limit/credit_days/is_credit_blocked, fetched on selection
  // Party snapshot — ALWAYS populated regardless of customerType: auto-filled
  // (but editable) from the account when CUSTOMER, typed directly when
  // PROSPECT. Printing and save always read these, never _customerDisplay.
  final _partyNameCtrl    = TextEditingController();
  final _partyPhoneCtrl   = TextEditingController();
  final _partyEmailCtrl   = TextEditingController();
  final _partyAddressCtrl = TextEditingController();
  String?  _salesPersonId;
  String   _salesPersonDisplay = '';
  String?  _preparedByName;
  String?  _authorisedByName;
  String?  _quotationCurrencyId;
  String?  _quotationCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  final _paymentTermsCtrl  = TextEditingController();
  final _deliveryTermsCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _taxGroups = [];
  List<Map<String, dynamic>> _additionalCharges = [];
  List<Map<String, dynamic>> _currencies = [];
  String _baseCurrency = '';
  String _localCurrency = '';
  Map<String, double> _taxRatePct = {};
  Map<String, double> _taxGroupRatePct = {};

  final List<_QuotationLineRow> _lines = [];
  final List<_QuotationChargeRow> _charges = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _statusUpdating = false;
  bool    _printing = false;

  bool get _isNew => _quotationNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _partyNameCtrl.dispose();
    _partyPhoneCtrl.dispose();
    _partyEmailCtrl.dispose();
    _partyAddressCtrl.dispose();
    _rateToBaseCtrl.dispose();
    _rateToLocalCtrl.dispose();
    _paymentTermsCtrl.dispose();
    _deliveryTermsCtrl.dispose();
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
      ]);

      _products          = results[0] as List<Map<String, dynamic>>;
      _taxGroups         = results[1] as List<Map<String, dynamic>>;
      _additionalCharges = results[2] as List<Map<String, dynamic>>;
      _users             = results[3] as List<Map<String, dynamic>>;
      _locations         = results[4] as List<Map<String, dynamic>>;
      _currencies        = results[5] as List<Map<String, dynamic>>;
      _baseCurrency      = results[6] as String;
      _localCurrency     = results[7] as String;

      await _loadTaxRates();

      if (widget.editQuotationNo != null) {
        await _loadExisting(widget.editQuotationNo!, widget.editQuotationDate);
      } else {
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

  Future<void> _loadExisting(String quotationNo, [String? quotationDate]) async {
    final session = ref.read(sessionProvider)!;
    final header = await _ds.getHeader(
      clientId: session.clientId, companyId: session.companyId,
      quotationNo: quotationNo, quotationDate: quotationDate,
    );
    if (header == null || !mounted) { setState(() => _loading = false); return; }

    final customer     = header['customer'] as Map<String, dynamic>?;
    final salesPerson  = header['sales_person'] as Map<String, dynamic>?;
    final currency     = header['currency'] as Map<String, dynamic>?;

    _quotationNo         = header['quotation_no'] as String;
    _quotationDate        = DateTime.parse(header['quotation_date'] as String);
    _validUntilDate        = DateTime.tryParse(header['valid_until_date'] as String? ?? '') ?? _validUntilDate;
    _status                 = header['status'] as String;
    _preparedByName          = _resolveUserName(header['created_by'] as String?);
    _authorisedByName        = _resolveUserName(header['approved_by'] as String?);
    _locationId              = header['location_id'] as String?;
    _customerType             = header['customer_type'] as String? ?? 'CUSTOMER';
    _customerId               = header['customer_id'] as String?;
    _customerDisplay           = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
    _partyNameCtrl.text     = header['party_name'] as String? ?? '';
    _partyPhoneCtrl.text    = header['party_phone'] as String? ?? '';
    _partyEmailCtrl.text    = header['party_email'] as String? ?? '';
    _partyAddressCtrl.text  = header['party_address'] as String? ?? '';
    _salesPersonId              = header['sales_person_id'] as String?;
    _salesPersonDisplay          = salesPerson?['full_name'] as String? ?? '';
    _quotationCurrencyId          = header['quotation_currency_id'] as String?;
    _quotationCurrencyCode         = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text  = (header['rate_to_base']  as num? ?? 1).toString();
    _rateToLocalCtrl.text = (header['rate_to_local'] as num? ?? 1).toString();
    _paymentTermsCtrl.text  = header['payment_terms'] as String? ?? '';
    _deliveryTermsCtrl.text = header['delivery_terms'] as String? ?? '';
    _remarksCtrl.text       = header['remarks'] as String? ?? '';

    if (_customerId != null) unawaited(_loadCustomerInfo(_customerId!));

    final savedLines = await _ds.getLines(
      clientId: session.clientId, companyId: session.companyId,
      quotationNo: _quotationNo!, quotationDate: _fmtDate(_quotationDate),
    );
    for (final l in _lines) { l.dispose(); }
    _lines.clear();
    for (final sl in savedLines) {
      final product = sl['product'] as Map<String, dynamic>?;
      final uom     = sl['uom'] as Map<String, dynamic>?;
      final row = _QuotationLineRow()
        ..productId = sl['product_id'] as String?
        ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
        ..uomId = sl['uom_id'] as String?
        ..uomLabel = uom?['description'] as String?
        ..uomConversionFactor = (sl['uom_conversion_factor'] as num? ?? 1).toDouble()
        ..taxGroupId = sl['tax_group_id'] as String?
        ..convertedQty = (sl['converted_qty'] as num? ?? 0).toDouble()
        ..matchedBarcode = sl['barcode'] as String?;
      row.descCtrl.text = sl['item_description'] as String? ?? '';
      row.qtyPackCtrl.text = (sl['qty_pack'] as num? ?? 0).toString();
      row.qtyLooseCtrl.text = (sl['qty_loose'] as num? ?? 0).toString();
      row.rateCtrl.text = (sl['rate'] as num? ?? 0).toString();
      row.discountPctCtrl.text = (sl['discount_percent'] as num? ?? 0).toString();
      row.remarksCtrl.text = sl['remarks'] as String? ?? '';
      _lines.add(row);
    }

    final savedCharges = await _ds.getCharges(
      clientId: session.clientId, companyId: session.companyId,
      quotationNo: _quotationNo!, quotationDate: _fmtDate(_quotationDate),
    );
    for (final c in _charges) { c.dispose(); }
    _charges.clear();
    for (final sc in savedCharges) {
      final row = _QuotationChargeRow()
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

  Future<void> _loadCustomerInfo(String customerId) async {
    try {
      final info = await _ds.getCustomerDetails(customerId: customerId);
      if (mounted) setState(() => _customerInfo = info);
    } catch (_) {
      // Credit info is a display-only convenience — a failed lookup should
      // never block the screen.
    }
  }

  Future<void> _onCustomerSelected(Map<String, dynamic> account) async {
    final customerId = account['id'] as String;
    setState(() {
      _customerId = customerId;
      _customerDisplay = '[${account['account_code']}] ${account['account_name']}';
      _partyNameCtrl.text = account['account_name'] as String? ?? '';
      _customerInfo = null;
    });
    await _loadCustomerInfo(customerId);
    if (!mounted || _customerInfo == null) return;
    setState(() {
      // Auto-fill from the account, but stays editable per-quotation from here —
      // same "default from master, editable per-document" convention as PO's ship_to.
      _partyPhoneCtrl.text = _customerInfo!['phone'] as String? ?? '';
      _partyEmailCtrl.text = _customerInfo!['email'] as String? ?? '';
      final addr1 = _customerInfo!['address_line1'] as String? ?? '';
      final addr2 = _customerInfo!['address_line2'] as String? ?? '';
      _partyAddressCtrl.text = [addr1, addr2].where((s) => s.isNotEmpty).join(', ');
    });
    final currRel = _customerInfo!['rim_currencies'];
    final customerCurrency = currRel is Map ? currRel['currency_id'] as String? : null;
    if (customerCurrency != null) {
      final match = _currencies.where((c) => c['currency_id'] == customerCurrency).toList();
      if (match.isNotEmpty && mounted) await _onCurrencySelected(match.first);
    }
    // Price can be customer-specific -- re-resolve every existing line even
    // when the currency itself didn't change (_onCurrencySelected's own
    // resolve loop only fires on an actual currency switch).
    for (final row in _lines) {
      if (row.productId != null) unawaited(_resolvePrice(row));
    }
  }

  void _onCustomerTypeChanged(String type) {
    setState(() {
      _customerType = type;
      if (type == 'PROSPECT') {
        _customerId = null;
        _customerDisplay = '';
        _customerInfo = null;
        // Party fields are left as-is (user may have already started typing);
        // switching back to CUSTOMER and picking an account overwrites them again.
      }
    });
  }

  Future<void> _onCurrencySelected(Map<String, dynamic> currency) async {
    setState(() {
      _quotationCurrencyId   = currency['id'] as String;
      _quotationCurrencyCode = currency['currency_id'] as String;
      _rateToBaseCtrl.text  = '1';
      _rateToLocalCtrl.text = '1';
    });
    await _fetchRates();
    for (final row in _lines) {
      if (row.productId != null) unawaited(_resolvePrice(row));
    }
  }

  Future<void> _fetchRates() async {
    if (_quotationCurrencyCode == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    if (_quotationCurrencyCode != _baseCurrency && _baseCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _quotationCurrencyCode!, toCurrency: _baseCurrency, rateDate: _fmtDate(_quotationDate));
      if (mounted && r != null) setState(() => _rateToBaseCtrl.text = r.toString());
    } else if (mounted) {
      setState(() => _rateToBaseCtrl.text = '1');
    }
    if (_localCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _quotationCurrencyCode!, toCurrency: _localCurrency, rateDate: _fmtDate(_quotationDate));
      if (mounted && r != null) setState(() => _rateToLocalCtrl.text = r.toString());
    }
  }

  void _addLine() => setState(() => _lines.add(_QuotationLineRow()));
  void _removeLine(_QuotationLineRow row) => setState(() { _lines.remove(row); row.dispose(); });
  void _addCharge() => setState(() => _charges.add(_QuotationChargeRow()));
  void _removeCharge(_QuotationChargeRow row) => setState(() { _charges.remove(row); row.dispose(); });

  bool _isDuplicateProduct(String productId, {_QuotationLineRow? excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId);

  Future<void> _onProductSelected(_QuotationLineRow row, Map<String, dynamic> product) async {
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
      row.taxGroupId ??= product['sales_tax_group_id'] as String?;
    });
    unawaited(_resolvePrice(row));
  }

  /// Real gap found live: Sales Quotation predates Price Master (081 vs
  /// 083) and never fetched a price at all -- rate had to be typed
  /// manually every time. Unlike Sales Order, this screen has no
  /// ric_user_sales_controls governance (no override-reason requirement,
  /// no hard block on save) -- a Quotation is a pre-commitment offer, not
  /// a final transaction, so this is deliberately just a prefill: found
  /// price fills the Rate field, not found leaves it for manual entry,
  /// always freely editable either way.
  Future<void> _resolvePrice(_QuotationLineRow row) async {
    if (row.productId == null || row.uomId == null || _locationId == null || _quotationCurrencyCode == null) return;
    setState(() => row.priceLoading = true);
    final session = ref.read(sessionProvider)!;
    try {
      final price = await _ds.getActivePrice(
        clientId: session.clientId, companyId: session.companyId,
        locationId: _locationId!, productId: row.productId!, uomId: row.uomId!,
        customerId: _customerType == 'CUSTOMER' ? _customerId : null,
        asOfDate: _fmtDate(_quotationDate),
        currencyCode: _quotationCurrencyCode!,
      );
      if (!mounted) return;
      setState(() {
        row.priceLoading = false;
        if (price != null) row.rateCtrl.text = (price['selling_price'] as num).toString();
      });
    } catch (e) {
      if (mounted) setState(() => row.priceLoading = false);
    }
  }

  Future<void> _onBarcodeSubmitted(_QuotationLineRow row, String rawBarcode) async {
    final barcode = rawBarcode.trim();
    if (barcode.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    Map<String, dynamic>? match;
    try {
      match = await _ds.getProductByBarcode(clientId: session.clientId, companyId: session.companyId, barcode: barcode);
    } catch (e) {
      if (mounted) _showSnack('Barcode lookup failed: $e', color: AppColors.negative);
      return;
    }
    if (!mounted) return;
    if (match == null) { _showSnack('No product found for barcode "$barcode".', color: AppColors.negative); return; }
    final matchedProduct = match;
    await _onProductSelected(row, matchedProduct);
    if (mounted && row.productId == matchedProduct['id']) {
      setState(() {
        row.uomId = matchedProduct['matched_uom_id'] as String? ?? row.uomId;
        row.uomConversionFactor = (matchedProduct['matched_uom_conversion_factor'] as num? ?? 1).toDouble();
        row.matchedBarcode = barcode;
        row.barcodeCtrl.clear();
      });
    }
  }

  void _onChargeSelected(_QuotationChargeRow row, Map<String, dynamic> charge) {
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
  // Recomputed on every build from live controller text.

  void _recompute() {
    double subtotalBeforeCharges = 0;
    for (final l in _lines) {
      l.baseQty        = l.qtyPack * l.uomConversionFactor + l.qtyLoose;
      l.grossAmount     = l.baseQty * l.rate;
      l.discountAmount   = l.grossAmount * l.discountPct / 100;
      l.taxableAmount     = l.grossAmount - l.discountAmount;
      final ratePct         = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount            = l.taxableAmount * ratePct / 100;
      l.finalAmount            = l.taxableAmount + l.taxAmount;
      subtotalBeforeCharges += l.taxableAmount;
    }
    for (final c in _charges) {
      c.amount = c.amountOrPercent == 'PERCENT' ? subtotalBeforeCharges * c.value / 100 : c.value;
      final chargeRatePct = c.isTaxable && c.taxId != null ? (_taxRatePct[c.taxId] ?? 0) : 0;
      c.taxAmount = c.amount * chargeRatePct / 100;
      c.allocationFactor = subtotalBeforeCharges > 0 ? c.amount / subtotalBeforeCharges : 0;
    }

    // Apportion each charge back onto every line by value, same formula PO
    // uses for landed cost — here purely to show an all-inclusive per-item
    // price to the customer, no costing/inventory purpose.
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

  // ── Save / Approve / status transitions ─────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_customerType == 'CUSTOMER' && _customerId == null) {
      _showSnack('Select a customer, or switch to Prospect and enter their details.', color: AppColors.negative);
      return false;
    }
    if (_customerType == 'PROSPECT' && _partyNameCtrl.text.trim().isEmpty) {
      _showSnack('Enter the prospect\'s name.', color: AppColors.negative);
      return false;
    }
    if (_quotationCurrencyId == null) { _showSnack('Select a currency.', color: AppColors.negative); return false; }
    if (_locationId == null) { _showSnack('Select a location.', color: AppColors.negative); return false; }
    final emailInput = _partyEmailCtrl.text.trim();
    if (emailInput.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(emailInput)) {
      _showSnack('Enter a valid email address.', color: AppColors.negative);
      return false;
    }
    if (_validUntilDate.isBefore(_quotationDate)) {
      _showSnack('Valid Until date cannot be before the Quotation date.', color: AppColors.negative);
      return false;
    }
    final validLines = _lines.where((l) => l.productId != null && l.baseQty > 0).toList();
    if (validLines.isEmpty) { _showSnack('Add at least one line with a product and quantity.', color: AppColors.negative); return false; }
    for (final l in validLines) {
      if (l.rate <= 0) {
        _showSnack('${l.productDisplay}: rate must be greater than zero.', color: AppColors.negative);
        return false;
      }
      if (l.discountPct > 100) {
        _showSnack('${l.productDisplay}: discount cannot exceed 100%.', color: AppColors.negative);
        return false;
      }
    }
    // Real bug found live: a charge's Amount field accepted a negative
    // number with no validation at all (same fix as Sales Order).
    for (final c in _charges.where((c) => c.chargeId != null)) {
      if (c.value < 0) {
        _showSnack('${c.chargeName}: amount cannot be negative.', color: AppColors.negative);
        return false;
      }
    }

    _recompute();
    if (_grandTotal < 0) {
      _showSnack('Quotation total cannot be negative -- check discounts and charges.', color: AppColors.negative);
      return false;
    }
    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':              session.clientId,
        'company_id':             session.companyId,
        'location_id':            _locationId,
        'quotation_no':           _quotationNo,
        'quotation_date':         _fmtDate(_quotationDate),
        'valid_until_date':       _fmtDate(_validUntilDate),
        'customer_type':          _customerType,
        'customer_id':            _customerId,
        'party_name':             _partyNameCtrl.text.trim(),
        'party_phone':            _partyPhoneCtrl.text.trim(),
        'party_email':            _partyEmailCtrl.text.trim(),
        'party_address':          _partyAddressCtrl.text.trim(),
        'sales_person_id':        _salesPersonId,
        'quotation_currency_id':  _quotationCurrencyId,
        'rate_to_base':           double.tryParse(_rateToBaseCtrl.text) ?? 1,
        'rate_to_local':          double.tryParse(_rateToLocalCtrl.text) ?? 1,
        'payment_terms':          _paymentTermsCtrl.text.trim(),
        'delivery_terms':         _deliveryTermsCtrl.text.trim(),
        'gross_amount':           _grossTotal,
        'discount_amount':        _discountTotal,
        'charges_amount':         _chargesTotal,
        'tax_amount':             _itemTaxTotal + _chargeTaxTotal,
        'grand_total':            _grandTotal,
        'remarks':                _remarksCtrl.text.trim(),
      };
      final lines = validLines.asMap().entries.map((e) => {
        'serial_no':              e.key + 1,
        'product_id':             e.value.productId,
        'item_description':       e.value.descCtrl.text.trim(),
        'barcode':                e.value.matchedBarcode ?? '',
        'uom_id':                 e.value.uomId,
        'uom_conversion_factor':  e.value.uomConversionFactor,
        'qty_pack':               e.value.qtyPack,
        'qty_loose':              e.value.qtyLoose,
        'base_qty':               e.value.baseQty,
        'rate':                   e.value.rate,
        'gross_amount':           e.value.grossAmount,
        'discount_percent':       e.value.discountPct,
        'discount_amount':        e.value.discountAmount,
        'tax_group_id':           e.value.taxGroupId,
        'tax_amount':             e.value.taxAmount,
        'final_amount':           e.value.finalAmount,
        'base_amount':            e.value.finalAmount * (double.tryParse(_rateToBaseCtrl.text) ?? 1),
        'local_amount':           e.value.finalAmount * (double.tryParse(_rateToLocalCtrl.text) ?? 1),
        'charge_amount':          e.value.chargeAmount,
        'landed_amount':          e.value.landedAmount,
        'remarks':                e.value.remarksCtrl.text.trim(),
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
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'SALES_QUOTATION',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_sales_quotation',
          payload:      {'p_header': header, 'p_lines': lines, 'p_charges': charges, 'p_user_id': session.userId},
        );
        await _ds.cacheQuotationLocally(effectiveQuotationNo: localId, header: header, lines: lines, charges: charges);
        if (mounted) {
          setState(() { _quotationNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final quotationNo = await _ds.save(header: header, lines: lines, charges: charges, userId: session.userId);
        unawaited(_ds.cacheQuotationLocally(effectiveQuotationNo: quotationNo, header: header, lines: lines, charges: charges));
        if (mounted) {
          setState(() { _quotationNo = quotationNo; _saving = false; });
          _showSnack('Sales Quotation $quotationNo saved.', color: AppColors.positive);
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
    if (_quotationNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Sales Quotation'),
        content: const Text('Once approved, this quotation can be sent to the customer and can no longer be edited. Continue?'),
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
        quotationNo: _quotationNo!, quotationDate: _fmtDate(_quotationDate),
        approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Quotation $_quotationNo approved.', color: AppColors.positive);
        await _loadExisting(_quotationNo!, _fmtDate(_quotationDate));
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  Future<void> _updateStatus(String newStatus) async {
    if (_quotationNo == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _statusUpdating = true; _actionError = null; });
    try {
      await _ds.updateStatus(
        clientId: session.clientId, companyId: session.companyId,
        quotationNo: _quotationNo!, quotationDate: _fmtDate(_quotationDate),
        newStatus: newStatus, userId: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Quotation $_quotationNo marked $newStatus.', color: AppColors.positive);
        await _loadExisting(_quotationNo!, _fmtDate(_quotationDate));
      }
    } on DioException catch (e) {
      setState(() { _actionError = e.response?.data?['message'] ?? _serverError(e); });
    } catch (e) {
      setState(() { _actionError = 'Unexpected error: $e'; });
    } finally {
      if (mounted) setState(() => _statusUpdating = false);
    }
  }

  String _serverError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    return e.message ?? e.toString();
  }

  bool get _isExpired =>
      (_status == 'SENT' || _status == 'ACCEPTED') && _validUntilDate.isBefore(DateTime.now());

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    _recompute();
    return {
      'company': company,
      'header': {
        'quotation_no':     _quotationNo ?? '',
        'quotation_date':   _displayDate(_quotationDate),
        'valid_until_date': _displayDate(_validUntilDate),
        'status':           _isExpired ? 'EXPIRED' : _status,
        'customer_name':    _partyNameCtrl.text,
        'sales_person_name': _salesPersonDisplay,
        'currency_code':    _quotationCurrencyCode ?? '',
        'payment_terms':    _paymentTermsCtrl.text,
        'delivery_terms':   _deliveryTermsCtrl.text,
        'remarks':          _remarksCtrl.text,
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
      // Real bug found live: never supplied, so the default template's
      // Prepared By/Authorised By lines printed with no name under them
      // (registry+template already bind these correctly app-wide —
      // this screen just never resolved/sent the values).
      'signatures': {
        'prepared_by':   _preparedByName ?? '',
        'authorised_by': _authorisedByName ?? '',
      },
    };
  }

  String? _resolveUserName(String? userId) {
    if (userId == null) return null;
    final match = _users.firstWhere((u) => u['id'] == userId, orElse: () => const {});
    return match['full_name'] as String?;
  }

  Future<void> _printQuotation() async {
    if (_quotationNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('SALES_QUOTATION').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_quotationNo.pdf');
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
      onPressed: _printing ? null : _printQuotation,
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
    final showLooseQty = (session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
    final showBarcode  = session?.enableBarcode ?? false;

    final canSave      = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final showApprove  = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;
    final showSend     = !isOffline && _status == 'APPROVED' && canEdit;
    final showAcceptReject = !isOffline && _status == 'SENT' && canEdit;
    final locked       = _status != 'DRAFT';

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
                    if (_quotationNo != null) _buildPrintButton(),
                    _buildActionButtons(canSave: canSave, showApprove: showApprove, showSend: showSend, showAcceptReject: showAcceptReject),
                  ]),
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_quotationNo != null) _buildPrintButton(),
                  _buildActionButtons(canSave: canSave, showApprove: showApprove, showSend: showSend, showAcceptReject: showAcceptReject),
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

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_quotationNo != null ? 'Sales Quotation · $_quotationNo' : 'New Sales Quotation',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    Row(children: [
      _status != 'DRAFT' || _quotationNo != null
          ? _statusChip(_isExpired ? 'EXPIRED' : _status)
          : const Text('Unsaved draft', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      if (_quotationNo != null) ...[
        const SizedBox(width: 8),
        PendingSyncBadge(documentType: 'SALES_QUOTATION', documentId: _quotationNo!),
      ],
    ]),
  ]);

  Widget _statusChip(String status) {
    final color = switch (status) {
      'DRAFT'     => AppColors.badgeDraft,
      'APPROVED'  => AppColors.positive,
      'SENT'      => AppColors.secondary,
      'ACCEPTED'  => AppColors.positive,
      'REJECTED'  => AppColors.negative,
      'EXPIRED'   => AppColors.textSecondary,
      _           => AppColors.positive,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status.replaceAll('_', ' '), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildActionButtons({
    required bool canSave, required bool showApprove, required bool showSend, required bool showAcceptReject,
  }) => Wrap(spacing: 12, runSpacing: 8, children: [
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
    if (showSend) FilledButton(
      onPressed: _statusUpdating ? null : () => _updateStatus('SENT'),
      child: const Text('Send to Customer'),
    ),
    if (showAcceptReject) ...[
      FilledButton(
        onPressed: _statusUpdating ? null : () => _updateStatus('ACCEPTED'),
        style: FilledButton.styleFrom(backgroundColor: AppColors.positive),
        child: const Text('Mark Accepted'),
      ),
      OutlinedButton(
        onPressed: _statusUpdating ? null : () => _updateStatus('REJECTED'),
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.negative, side: const BorderSide(color: AppColors.negative)),
        child: const Text('Mark Rejected'),
      ),
    ],
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
    final showRate = _quotationCurrencyCode != null && _quotationCurrencyCode != _baseCurrency;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Quotation No/Date moved to the very top row — real user
          // feedback: date should be picked first, before anything else,
          // rather than after the customer-type toggle further down.
          Builder(builder: (_) {
            final f1 = field(InputDecorator(
              decoration: dec.copyWith(labelText: 'Quotation No'),
              child: Text(_quotationNo ?? '(auto on save)',
                  style: TextStyle(fontSize: 13, color: _quotationNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
            ));
            final f2 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_quotationDate, (d) {
                setState(() => _quotationDate = d);
                unawaited(_fetchRates());
              }),
              child: InputDecorator(
                decoration: dec.copyWith(label: _req('Quotation Date'),
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_quotationDate), style: const TextStyle(fontSize: 13)),
              ),
            ));
            final f3 = field(InkWell(
              onTap: locked ? null : () => _pickDate(_validUntilDate, (d) => setState(() => _validUntilDate = d)),
              child: InputDecorator(
                decoration: dec.copyWith(label: _req('Valid Until'),
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
                child: Text(_displayDate(_validUntilDate), style: const TextStyle(fontSize: 13)),
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
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'CUSTOMER', label: Text('Existing Customer'), icon: Icon(Icons.person_outline, size: 16)),
              ButtonSegment(value: 'PROSPECT', label: Text('Prospect'), icon: Icon(Icons.person_add_alt_outlined, size: 16)),
            ],
            selected: {_customerType},
            onSelectionChanged: locked ? null : (s) => _onCustomerTypeChanged(s.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(_customerType == 'CUSTOMER'
                ? Autocomplete<Map<String, dynamic>>(
                    initialValue: TextEditingValue(text: _customerDisplay),
                    displayStringForOption: (a) => '[${a['account_code']}] ${a['account_name']}',
                    optionsBuilder: (v) async {
                      if (locked) return const [];
                      final accounts = await ref.read(accountsProvider.future);
                      // posting_allowed=false rows are the Customer group/parent
                      // node itself (Chart of Accounts hierarchy), not a real
                      // customer to quote against -- same fix as Sales Order.
                      final customers = accounts.where((a) => a['account_nature'] == 'Customer' && a['posting_allowed'] == true);
                      final q = v.text.toLowerCase().trim();
                      if (q.isEmpty) return customers;
                      return customers.where((a) =>
                          (a['account_code'] as String).toLowerCase().contains(q) ||
                          (a['account_name'] as String).toLowerCase().contains(q));
                    },
                    onSelected: _onCustomerSelected,
                    fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                      controller: textCtrl, focusNode: focusNode, enabled: !locked,
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
                  )
                : TextFormField(
                    controller: _partyNameCtrl, enabled: !locked,
                    decoration: dec.copyWith(label: _req('Prospect Name')),
                    style: const TextStyle(fontSize: 13),
                  ));
            final f2 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(label: _req('Location')),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _locationId,
              items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
                  child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) { setState(() => _locationId = v); unawaited(_fetchRates()); },
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
                    SizedBox(width: double.infinity, child: f1), const SizedBox(height: 8),
                    Row(children: [Expanded(child: f2), const SizedBox(width: 12), Expanded(child: f3)]),
                  ])
                : Row(children: [
                    Expanded(flex: 3, child: f1), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f2), const SizedBox(width: 12),
                    Expanded(flex: 2, child: f3),
                  ]);
          }),
          if (_customerType == 'CUSTOMER' && _customerInfo != null) Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Credit Limit: ${(_customerInfo!['credit_limit'] as num?)?.toStringAsFixed(2) ?? '—'}'
              '   ·   Credit Days: ${_customerInfo!['credit_days'] ?? '—'}'
              '${_customerInfo!['is_credit_blocked'] == true ? '   ·   ⚠ CREDIT BLOCKED (info only, does not block a quotation)' : ''}',
              style: TextStyle(fontSize: 11,
                  color: _customerInfo!['is_credit_blocked'] == true ? AppColors.negative : AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          // Party contact snapshot — auto-filled when an existing customer is
          // selected (still editable per-quotation), typed directly for a
          // Prospect. Printing always reads these, never the account live.
          Builder(builder: (_) {
            final f1 = field(TextFormField(
              controller: _partyPhoneCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Phone'),
              style: const TextStyle(fontSize: 13),
            ));
            final f2 = field(TextFormField(
              controller: _partyEmailCtrl, enabled: !locked,
              keyboardType: TextInputType.emailAddress,
              decoration: dec.copyWith(labelText: 'Email'),
              style: const TextStyle(fontSize: 13),
            ));
            final f3 = field(TextFormField(
              controller: _partyAddressCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Address'),
              style: const TextStyle(fontSize: 13),
            ));
            return isMobile
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2)]), const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: f3),
                  ])
                : Row(children: [Expanded(child: f1), const SizedBox(width: 12), Expanded(child: f2), const SizedBox(width: 12), Expanded(flex: 2, child: f3)]);
          }),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final f1 = field(DropdownButtonFormField<String>(
              decoration: dec.copyWith(label: _req('Currency')),
              isExpanded: true, isDense: true, itemHeight: null,
              initialValue: _quotationCurrencyId,
              items: _currencies.map((c) => DropdownMenuItem(value: c['id'] as String,
                  child: Text(c['currency_id'] as String, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: locked ? null : (v) {
                final c = _currencies.firstWhere((e) => e['id'] == v);
                unawaited(_onCurrencySelected(c));
              },
            ));
            final f2 = field(TextFormField(
              controller: _rateToBaseCtrl, enabled: !locked && showRate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: dec.copyWith(labelText: 'Rate to Base ($_baseCurrency)'),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() {}),
            ));
            final f3 = field(TextFormField(
              controller: _paymentTermsCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Payment Terms'),
              style: const TextStyle(fontSize: 13),
            ));
            final f4 = field(TextFormField(
              controller: _deliveryTermsCtrl, enabled: !locked,
              decoration: dec.copyWith(labelText: 'Delivery Terms'),
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
                    width: 240,
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
                  SizedBox(width: 70, child: InputDecorator(
                    decoration: dec.copyWith(labelText: 'Unit'),
                    child: Text(row.uomLabel ?? '—', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                  )),
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
                  SizedBox(width: 100, child: TextFormField(
                    controller: row.rateCtrl, enabled: !locked,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Rate'),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                  )),
                  SizedBox(width: 80, child: TextFormField(
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
                  if (row.convertedQty > 0) SizedBox(width: 110, child: Text('Converted: ${row.convertedQty.toStringAsFixed(2)}',
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
            const Expanded(child: Text('Charges (optional)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
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

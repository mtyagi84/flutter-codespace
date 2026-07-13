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
import '../../domain/repositories/price_master_repository.dart';
import '../providers/price_master_providers.dart';

class _PriceLineRow {
  String? productId;
  String  productDisplay = '';
  // Product's own rim_products.cost_currency_id — needed for the Cost
  // Price three-way currency rule (see docs/screens/sales_price_master.md
  // §4). Fetched alongside the product, never re-derived.
  String? costCurrencyId;
  List<Map<String, dynamic>> uomOptions = [];
  bool    uomLoading = false;
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  // What was actually scanned to build/identify this line — audit only,
  // null if the line was added via the Product Autocomplete instead.
  String? barcode;
  bool    costLoading = false;
  double  costPrice = 0;
  bool    syncing = false; // guards the Margin% <-> Selling Price recompute loop
  final TextEditingController marginPercentCtrl = TextEditingController();
  final TextEditingController sellingPriceCtrl  = TextEditingController(text: '0');
  final FocusNode marginFocusNode = FocusNode();
  String? belowCostReasonId;
  // No taxGroupId — rim_products.sales_tax_group_id is already the
  // authoritative link, resolved at the point of sale by a future Sales
  // Order/Invoice, not carried on this line.
  bool    isTaxInclusive = false;
  final TextEditingController remarksCtrl = TextEditingController();

  double get sellingPrice => double.tryParse(sellingPriceCtrl.text) ?? 0;
  bool get isBelowCost => costPrice > 0 && sellingPrice < costPrice;

  void dispose() {
    sellingPriceCtrl.dispose();
    marginPercentCtrl.dispose();
    marginFocusNode.dispose();
    remarksCtrl.dispose();
  }
}

class PriceMasterEntryScreen extends ConsumerStatefulWidget {
  final String? editEntryNo;
  final String? editEntryDate;
  const PriceMasterEntryScreen({super.key, this.editEntryNo, this.editEntryDate});

  @override
  ConsumerState<PriceMasterEntryScreen> createState() => _PriceMasterEntryScreenState();
}

class _PriceMasterEntryScreenState extends ConsumerState<PriceMasterEntryScreen>
    with ScreenPermissionMixin<PriceMasterEntryScreen> {
  @override String get screenName => RouteNames.salesPriceMaster;

  PriceMasterRepository get _ds => ref.read(priceMasterRepositoryProvider);

  String?  _entryNo;
  DateTime _entryDate     = DateTime.now();
  DateTime _effectiveDate = DateTime.now();
  String   _status = 'DRAFT';
  String?  _locationId;
  String   _priceType = 'GENERIC'; // GENERIC | CUSTOMER
  String?  _customerId;
  String   _customerDisplay = '';
  String?  _priceCurrencyId;
  String?  _priceCurrencyCode;
  final _rateToBaseCtrl  = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');
  final _scanCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();

  List<Map<String, dynamic>> _locations  = [];
  List<Map<String, dynamic>> _currencies = [];
  String _baseCurrency  = '';
  String _localCurrency = '';
  List<Map<String, dynamic>> _products   = [];
  List<Map<String, dynamic>> _belowCostReasons = [];
  final List<_PriceLineRow> _lines = [];

  bool    _loading = true;
  String? _error;
  String? _actionError;
  bool    _saving = false;
  bool    _approving = false;
  bool    _printing = false;

  bool get _isNew => _entryNo == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _rateToBaseCtrl.dispose();
    _rateToLocalCtrl.dispose();
    _scanCtrl.dispose();
    _remarksCtrl.dispose();
    for (final l in _lines) { l.dispose(); }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    _locationId = session.locationId;
    try {
      final results = await Future.wait<dynamic>([
        _ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId),
        _ds.getReasons(clientId: session.clientId, companyId: session.companyId),
        ref.read(locationsProvider.future),
        ref.read(currenciesProvider.future),
        ref.read(baseCurrencyProvider.future),
        ref.read(localCurrencyProvider.future),
      ]);
      _products         = results[0] as List<Map<String, dynamic>>;
      _belowCostReasons = results[1] as List<Map<String, dynamic>>;
      _locations        = results[2] as List<Map<String, dynamic>>;
      _currencies       = results[3] as List<Map<String, dynamic>>;
      _baseCurrency     = results[4] as String;
      _localCurrency    = results[5] as String;

      if (widget.editEntryNo != null) {
        await _loadExisting(widget.editEntryNo!, widget.editEntryDate);
      } else {
        // Default Currency to the company's base currency (rate stays 1,
        // no fetch needed since currency == base).
        final baseMatch = _currencies.where((c) => c['currency_id'] == _baseCurrency).toList();
        if (baseMatch.isNotEmpty) {
          _priceCurrencyId   = baseMatch.first['id'] as String;
          _priceCurrencyCode = _baseCurrency;
        }
        // Deliberately no auto-added first line here (unlike Sales
        // Quotation/Stock Adjustment) — Price Type and Location must stay
        // pickable until the user actually adds a line, since adding one
        // locks both.
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load data: $e'; });
    }
  }

  Future<void> _loadExisting(String entryNo, [String? entryDate]) async {
    final session = ref.read(sessionProvider)!;
    final header = await _ds.getHeader(
      clientId: session.clientId, companyId: session.companyId,
      entryNo: entryNo, entryDate: entryDate,
    );
    if (header == null || !mounted) { setState(() => _loading = false); return; }

    final customer = header['customer'] as Map<String, dynamic>?;
    final currency = header['currency'] as Map<String, dynamic>?;
    _entryNo         = header['entry_no'] as String;
    _entryDate       = DateTime.parse(header['entry_date'] as String);
    _effectiveDate   = DateTime.tryParse(header['effective_date'] as String? ?? '') ?? _effectiveDate;
    _status          = header['status'] as String;
    _locationId      = header['location_id'] as String? ?? _locationId;
    _priceType       = header['price_type'] as String? ?? 'GENERIC';
    _customerId      = header['customer_id'] as String?;
    _customerDisplay = customer != null ? '[${customer['account_code']}] ${customer['account_name']}' : '';
    _priceCurrencyId   = header['price_currency_id'] as String?;
    _priceCurrencyCode = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text  = (header['rate_to_base']  as num? ?? 1).toString();
    _rateToLocalCtrl.text = (header['rate_to_local'] as num? ?? 1).toString();
    _remarksCtrl.text = header['remarks'] as String? ?? '';

    final savedLines = await _ds.getLines(
      clientId: session.clientId, companyId: session.companyId,
      entryNo: _entryNo!, entryDate: _fmtDate(_entryDate),
    );
    for (final l in _lines) { l.dispose(); }
    _lines.clear();
    for (final sl in savedLines) {
      final product = sl['product'] as Map<String, dynamic>?;
      final uom     = sl['uom'] as Map<String, dynamic>?;
      final row = _PriceLineRow()
        ..productId = sl['product_id'] as String?
        ..productDisplay = product != null ? '[${product['product_code']}] ${product['product_name']}' : ''
        ..costCurrencyId = product?['cost_currency_id'] as String?
        ..uomId = sl['uom_id'] as String?
        ..uomLabel = uom?['description'] as String?
        ..uomConversionFactor = (sl['uom_conversion_factor'] as num? ?? 1).toDouble()
        ..barcode = sl['barcode'] as String?
        ..costPrice = (sl['cost_price'] as num? ?? 0).toDouble()
        ..belowCostReasonId = sl['below_cost_reason_id'] as String?
        ..isTaxInclusive = sl['is_tax_inclusive'] as bool? ?? false;
      row.sellingPriceCtrl.text = (sl['selling_price'] as num? ?? 0).toString();
      final margin = sl['margin_percent'] as num?;
      row.marginPercentCtrl.text = margin != null ? margin.toString() : '';
      row.remarksCtrl.text = sl['remarks'] as String? ?? '';
      _lines.add(row);
      if (row.productId != null) unawaited(_loadUomOptions(row, row.productId!, resetSelection: false));
    }

    if (mounted) setState(() => _loading = false);
  }

  void _addLine() {
    if (_locationId == null) {
      _showSnack('Select a Location first.', color: AppColors.negative);
      return;
    }
    setState(() => _lines.add(_PriceLineRow()));
  }

  void _removeLine(_PriceLineRow row) => setState(() { _lines.remove(row); row.dispose(); });

  bool _isDuplicatePair(String productId, String uomId, {_PriceLineRow? excluding}) =>
      _lines.any((l) => l != excluding && l.productId == productId && l.uomId == uomId);

  Future<void> _loadUomOptions(_PriceLineRow row, String productId, {bool resetSelection = true}) async {
    setState(() => row.uomLoading = true);
    try {
      final uoms = await _ds.getProductUoms(productId);
      if (!mounted) return;
      setState(() {
        row.uomOptions = uoms;
        row.uomLoading = false;
        if (resetSelection) {
          if (uoms.isNotEmpty) {
            final base = uoms.firstWhere((u) => u['is_base_uom'] == true, orElse: () => uoms.first);
            row.uomId = base['uom_id'] as String?;
            row.uomLabel = (base['uom'] as Map<String, dynamic>?)?['description'] as String?;
            row.uomConversionFactor = (base['conversion_factor'] as num? ?? 1).toDouble();
          } else {
            row.uomId = null;
            row.uomLabel = null;
            row.uomConversionFactor = 1;
          }
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => row.uomLoading = false);
        _showSnack('Could not load pack sizes for "${row.productDisplay}": $e', color: AppColors.negative);
      }
    }
  }

  Future<void> _onProductSelected(_PriceLineRow row, Map<String, dynamic> product) async {
    setState(() {
      row.productId = product['id'] as String;
      row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
      row.costCurrencyId = product['cost_currency_id'] as String?;
      row.uomOptions = [];
      row.uomId = null;
      row.uomLabel = null;
    });
    await _loadUomOptions(row, row.productId!);
    await _refreshLineCost(row);
  }

  void _onUomSelected(_PriceLineRow row, Map<String, dynamic> uomOption) {
    final uomId = uomOption['uom_id'] as String;
    if (row.productId != null && _isDuplicatePair(row.productId!, uomId, excluding: row)) {
      _showSnack('This product + UOM is already on another line in this batch.', color: AppColors.negative);
      return;
    }
    setState(() {
      row.uomId = uomId;
      row.uomLabel = (uomOption['uom'] as Map<String, dynamic>?)?['description'] as String?;
      row.uomConversionFactor = (uomOption['conversion_factor'] as num? ?? 1).toDouble();
    });
  }

  void _onPriceTypeChanged(String type) {
    if (_lines.isNotEmpty) return; // segmented button is disabled by then anyway
    setState(() {
      _priceType = type;
      if (type == 'GENERIC') {
        _customerId = null;
        _customerDisplay = '';
      }
    });
  }

  String? _duplicatePairError(List<_PriceLineRow> validLines) {
    for (var i = 0; i < validLines.length; i++) {
      for (var j = i + 1; j < validLines.length; j++) {
        if (validLines[i].productId == validLines[j].productId && validLines[i].uomId == validLines[j].uomId) {
          return '${validLines[i].productDisplay} already has a price for this UOM on another line.';
        }
      }
    }
    return null;
  }

  String? _duplicateBarcodeError(List<_PriceLineRow> validLines) {
    final seen = <String>{};
    for (final l in validLines) {
      final bc = l.barcode;
      if (bc == null || bc.isEmpty) continue;
      if (!seen.add(bc)) return 'Barcode "$bc" is scanned onto more than one line in this batch.';
    }
    return null;
  }

  String? _belowCostReasonMissingError(List<_PriceLineRow> validLines) {
    for (final l in validLines) {
      if (l.isBelowCost && (l.belowCostReasonId == null || l.belowCostReasonId!.isEmpty)) {
        return '${l.productDisplay} is priced below cost — choose a reason.';
      }
    }
    return null;
  }

  // ── Currency / Rate / Cost Price (three-way rule) ───────────────────────

  Future<void> _onCurrencySelected(Map<String, dynamic> currency) async {
    setState(() {
      _priceCurrencyId   = currency['id'] as String;
      _priceCurrencyCode = currency['currency_id'] as String;
      _rateToBaseCtrl.text  = '1';
      _rateToLocalCtrl.text = '1';
    });
    await _fetchRates();
    // Currency is NOT locked once lines exist (unlike Location/Price Type) —
    // re-resolve every existing line's Cost Price against the new currency.
    for (final row in _lines) {
      if (row.productId != null) unawaited(_refreshLineCost(row));
    }
  }

  Future<void> _fetchRates() async {
    if (_priceCurrencyCode == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    if (_priceCurrencyCode != _baseCurrency && _baseCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _priceCurrencyCode!, toCurrency: _baseCurrency, rateDate: _fmtDate(_entryDate));
      if (mounted && r != null) setState(() => _rateToBaseCtrl.text = r.toString());
    } else if (mounted) {
      setState(() => _rateToBaseCtrl.text = '1');
    }
    if (_localCurrency.isNotEmpty) {
      final r = await _ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId!,
        fromCurrency: _priceCurrencyCode!, toCurrency: _localCurrency, rateDate: _fmtDate(_entryDate));
      if (mounted && r != null) setState(() => _rateToLocalCtrl.text = r.toString());
    }
  }

  /// Three-way Cost Price rule (docs/screens/sales_price_master.md §4):
  /// 1. Currency == base            -> rim_product_location.cost_price
  /// 2. Currency == product's own cost_currency_id -> cost_price_specific
  /// 3. Anything else               -> cost_price / header's own rate_to_base
  /// (never a fresh fn_get_exchange_rate lookup for #3 — reuse the header's
  /// already-confirmed rate, same rule GRN's migration 057 fix established).
  Future<void> _refreshLineCost(_PriceLineRow row) async {
    if (row.productId == null || _locationId == null) return;
    setState(() => row.costLoading = true);
    final session = ref.read(sessionProvider)!;
    try {
      final pl = await _ds.getProductLocationCost(
        clientId: session.clientId, companyId: session.companyId,
        locationId: _locationId!, productId: row.productId!,
      );
      final costBase      = (pl?['cost_price'] as num? ?? 0).toDouble();
      final costSpecific  = (pl?['cost_price_specific'] as num?)?.toDouble();
      double resolvedCost;
      if (_priceCurrencyCode != null && _priceCurrencyCode == _baseCurrency) {
        resolvedCost = costBase;
      } else if (_priceCurrencyId != null && row.costCurrencyId != null &&
          _priceCurrencyId == row.costCurrencyId && costSpecific != null) {
        resolvedCost = costSpecific;
      } else {
        final rate = double.tryParse(_rateToBaseCtrl.text) ?? 1;
        resolvedCost = rate > 0 ? costBase / rate : costBase;
      }
      if (!mounted) return;
      setState(() {
        row.costPrice = resolvedCost;
        row.costLoading = false;
      });
      _onSellingPriceChanged(row); // recompute margin against the new cost
    } catch (e) {
      if (mounted) {
        setState(() => row.costLoading = false);
        _showSnack('Could not load cost for "${row.productDisplay}": $e', color: AppColors.negative);
      }
    }
  }

  // ── Margin % <-> Selling Price, markup-on-cost ───────────────────────────

  void _onSellingPriceChanged(_PriceLineRow row) {
    if (row.syncing) return;
    row.syncing = true;
    if (row.costPrice > 0) {
      final margin = (row.sellingPrice - row.costPrice) / row.costPrice * 100;
      final marginStr = margin.toStringAsFixed(2);
      if (row.marginPercentCtrl.text != marginStr) row.marginPercentCtrl.text = marginStr;
    }
    row.syncing = false;
    setState(() {}); // refresh below-cost-reason visibility
  }

  void _onMarginChanged(_PriceLineRow row) {
    if (row.syncing || row.costPrice <= 0) return;
    row.syncing = true;
    final margin = double.tryParse(row.marginPercentCtrl.text) ?? 0;
    final selling = row.costPrice * (1 + margin / 100);
    final sellingStr = selling.toStringAsFixed(4);
    if (row.sellingPriceCtrl.text != sellingStr) row.sellingPriceCtrl.text = sellingStr;
    row.syncing = false;
    setState(() {});
  }

  // ── Barcode / Part Number header scan ────────────────────────────────────

  Future<void> _onHeaderScanSubmitted(String raw) async {
    final code = raw.trim();
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
    if (match == null) { _showSnack('No product found for "$code".', color: AppColors.negative); _scanCtrl.clear(); return; }
    final matchedProduct = match;

    final productId    = matchedProduct['id'] as String;
    final matchedUomId = matchedProduct['matched_uom_id'] as String? ?? matchedProduct['base_uom_id'] as String?;
    final existing = _lines.where((l) => l.productId == productId && l.uomId == matchedUomId).toList();
    if (existing.isNotEmpty) {
      // Already priced in this batch — jump straight to its Margin % field
      // rather than creating a duplicate line (also how a duplicate-scan is
      // naturally handled — no separate logic needed).
      _scanCtrl.clear();
      FocusScope.of(context).requestFocus(existing.first.marginFocusNode);
      return;
    }

    if (_locationId == null) {
      _showSnack('Select a Location first.', color: AppColors.negative);
      return;
    }

    final row = _PriceLineRow()
      ..productId = productId
      ..productDisplay = '[${matchedProduct['product_code']}] ${matchedProduct['product_name']}'
      ..costCurrencyId = matchedProduct['cost_currency_id'] as String?
      ..barcode = code;
    setState(() => _lines.add(row));

    final matchedConversionFactor = matchedProduct['matched_uom_conversion_factor'] as num?;
    await _loadUomOptions(row, productId, resetSelection: matchedUomId == null);
    if (matchedUomId != null) {
      setState(() {
        row.uomId = matchedUomId;
        row.uomLabel = matchedProduct['matched_uom_label'] as String? ?? row.uomLabel;
        row.uomConversionFactor = (matchedConversionFactor ?? 1).toDouble();
      });
    }
    await _refreshLineCost(row);
    _scanCtrl.clear();
  }

  // ── Save / Approve ───────────────────────────────────────────────────────

  Future<bool> _saveDraft() async {
    if (_locationId == null) {
      _showSnack('Select a Location.', color: AppColors.negative);
      return false;
    }
    if (_priceCurrencyId == null) {
      _showSnack('Select a Currency.', color: AppColors.negative);
      return false;
    }
    if (_priceType == 'CUSTOMER' && _customerId == null) {
      _showSnack('Select a customer, or switch to Generic.', color: AppColors.negative);
      return false;
    }
    final validLines = _lines.where((l) => l.productId != null && l.uomId != null).toList();
    if (validLines.isEmpty) {
      _showSnack('Add at least one line with a product and UOM.', color: AppColors.negative);
      return false;
    }
    final dupError = _duplicatePairError(validLines);
    if (dupError != null) {
      _showSnack(dupError, color: AppColors.negative);
      return false;
    }
    final dupBarcodeError = _duplicateBarcodeError(validLines);
    if (dupBarcodeError != null) {
      _showSnack(dupBarcodeError, color: AppColors.negative);
      return false;
    }
    final belowCostError = _belowCostReasonMissingError(validLines);
    if (belowCostError != null) {
      _showSnack(belowCostError, color: AppColors.negative);
      return false;
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id':         session.clientId,
        'company_id':        session.companyId,
        'entry_no':          _entryNo,
        'entry_date':        _fmtDate(_entryDate),
        'location_id':       _locationId,
        'price_type':        _priceType,
        'customer_id':       _priceType == 'CUSTOMER' ? _customerId : null,
        'effective_date':    _fmtDate(_effectiveDate),
        'price_currency_id': _priceCurrencyId,
        'rate_to_base':      double.tryParse(_rateToBaseCtrl.text) ?? 1,
        'rate_to_local':     double.tryParse(_rateToLocalCtrl.text) ?? 1,
        'remarks':           _remarksCtrl.text.trim(),
      };
      final lines = validLines.asMap().entries.map((e) => {
        'serial_no':             e.key + 1,
        'product_id':            e.value.productId,
        'uom_id':                e.value.uomId,
        'uom_conversion_factor': e.value.uomConversionFactor,
        'barcode':               e.value.barcode,
        'cost_price':            e.value.costPrice,
        'margin_percent':        double.tryParse(e.value.marginPercentCtrl.text),
        'selling_price':         e.value.sellingPrice,
        'below_cost_reason_id':  e.value.belowCostReasonId,
        'is_tax_inclusive':      e.value.isTaxInclusive,
        'remarks':               e.value.remarksCtrl.text.trim(),
      }).toList();

      if (session.offlineMode) {
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'PRICE_MASTER',
          documentId:   localId,
          endpoint:     '/rpc/fn_save_price_master_batch',
          payload:      {'p_header': header, 'p_lines': lines, 'p_user_id': session.userId},
        );
        await _ds.cacheBatchLocally(effectiveEntryNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() { _entryNo = localId; _saving = false; });
          _showSnack('Saved offline — will sync when online.', color: AppColors.secondary);
          return true;
        }
      } else {
        final entryNo = await _ds.save(header: header, lines: lines, userId: session.userId);
        unawaited(_ds.cacheBatchLocally(effectiveEntryNo: entryNo, header: header, lines: lines));
        if (mounted) {
          setState(() { _entryNo = entryNo; _saving = false; });
          _showSnack('Price Master batch $entryNo saved.', color: AppColors.positive);
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
    if (_entryNo == null) {
      final saved = await _saveDraft();
      if (!saved) return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Price Master Batch'),
        content: const Text('Once approved, these prices become eligible for use once their Effective Date '
            'arrives, and this batch can no longer be edited. Continue?'),
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
        entryNo: _entryNo!, entryDate: _fmtDate(_entryDate), approvedBy: session.userId,
      );
      if (mounted) {
        _showSnack('Price Master batch $_entryNo approved.', color: AppColors.positive);
        await _loadExisting(_entryNo!, _fmtDate(_entryDate));
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

  // ── Print ─────────────────────────────────────────────────────────────

  String _locationLabel(String? id) {
    if (id == null) return '';
    final match = _locations.where((l) => l['id'] == id).toList();
    return match.isNotEmpty ? match.first['location_name'] as String? ?? '' : '';
  }

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) => {
    'company': company,
    'header': {
      'entry_no':         _entryNo ?? '',
      'entry_date':       _displayDate(_entryDate),
      'effective_date':   _displayDate(_effectiveDate),
      'status':           _status,
      'location_name':    _locationLabel(_locationId),
      'price_type_label': _priceType == 'GENERIC' ? 'Generic' : 'Customer-Specific',
      'customer_name':    _priceType == 'CUSTOMER' ? _customerDisplay : '',
      'currency_code':    _priceCurrencyCode ?? '',
      'remarks':          _remarksCtrl.text,
    },
    'lines': _lines.map((l) => {
      'product_name':   l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
      'uom_label':      l.uomLabel ?? '',
      'cost_price':     l.costPrice,
      'margin_percent': double.tryParse(l.marginPercentCtrl.text) ?? 0,
      'selling_price':  l.sellingPrice,
    }).toList(),
  };

  Future<void> _printBatch() async {
    if (_entryNo == null) return;
    setState(() => _printing = true);
    try {
      final company  = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('PRICE_MASTER').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_entryNo.pdf');
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
      onPressed: _printing ? null : _printBatch,
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

  // Effective Date deliberately has no firstDate/lastDate bound — scheduling
  // a future price list is the entire point of this screen; a backdated
  // correction is likewise allowed since nothing here posts to the books.
  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> onPicked, {bool bounded = true}) async {
    final d = await showDatePicker(
      context: context, initialDate: current ?? DateTime.now(),
      firstDate: bounded ? DateTime(2020) : DateTime(1900),
      lastDate:  bounded ? DateTime(2100) : DateTime(2200),
    );
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
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);
    final showBarcode = session?.enableBarcode ?? false;
    final showPartNo  = session?.enablePartNumber ?? false;
    final showScan    = showBarcode || showPartNo;

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
                  if (_entryNo != null || canSave || showApprove) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (_entryNo != null) _buildPrintButton(),
                      if (canSave || showApprove) Expanded(child: _buildActionButtons(canSave: canSave, showApprove: showApprove)),
                    ]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_entryNo != null) _buildPrintButton(),
                  if (canSave || showApprove) _buildActionButtons(canSave: canSave, showApprove: showApprove),
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
                    _buildHeaderCard(locked, isMobile, showScan),
                    const SizedBox(height: 16),
                    _buildLinesCard(locked),
                  ]),
                ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(_entryNo != null ? 'Sales Price Master · $_entryNo' : 'New Price Master Batch',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
    const SizedBox(height: 2),
    Row(children: [
      _status == 'APPROVED' ? _statusChip() : Text(_entryNo != null ? 'Draft' : 'Unsaved draft',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      if (_entryNo != null) ...[
        const SizedBox(width: 8),
        PendingSyncBadge(documentType: 'PRICE_MASTER', documentId: _entryNo!),
      ],
    ]),
  ]);

  Widget _statusChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
    child: const Text('APPROVED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
  );

  Widget _buildActionButtons({required bool canSave, required bool showApprove}) => Wrap(spacing: 12, runSpacing: 8, children: [
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

  Widget _buildHeaderCard(bool locked, bool isMobile, bool showScan) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    const fh = 56.0;
    Widget field(Widget child) => SizedBox(height: fh, child: child);
    final priceTypeLocked = locked || _lines.isNotEmpty;
    final locationLocked  = locked || _lines.isNotEmpty;
    final showRate = _priceCurrencyCode != null && _priceCurrencyCode != _baseCurrency;

    final entryNoField = field(InputDecorator(
      decoration: dec.copyWith(labelText: 'Entry No'),
      child: Text(_entryNo ?? '(auto on save)',
          style: TextStyle(fontSize: 13, color: _entryNo != null ? AppColors.textPrimary : AppColors.textDisabled)),
    ));
    final entryDateField = field(InkWell(
      onTap: locked ? null : () => _pickDate(_entryDate, (d) {
        setState(() => _entryDate = d);
        unawaited(_fetchRates());
      }),
      child: InputDecorator(
        decoration: dec.copyWith(label: _req('Entry Date'),
            suffixIcon: Icon(Icons.calendar_today_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
        child: Text(_displayDate(_entryDate), style: const TextStyle(fontSize: 13)),
      ),
    ));
    final effDateField = field(InkWell(
      onTap: locked ? null : () => _pickDate(_effectiveDate, (d) => setState(() => _effectiveDate = d), bounded: false),
      child: InputDecorator(
        decoration: dec.copyWith(label: _req('Effective Date'),
            suffixIcon: Icon(Icons.event_outlined, size: 15, color: locked ? AppColors.textDisabled : AppColors.primary)),
        child: Text(_displayDate(_effectiveDate), style: const TextStyle(fontSize: 13)),
      ),
    ));

    final locationField = field(DropdownButtonFormField<String>(
      decoration: dec.copyWith(label: _req('Location')),
      isExpanded: true, isDense: true, itemHeight: null,
      initialValue: _locationId,
      items: _locations.map((l) => DropdownMenuItem(value: l['id'] as String,
          child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
      onChanged: locationLocked ? null : (v) {
        setState(() => _locationId = v);
        unawaited(_fetchRates());
      },
    ));
    final currencyField = field(DropdownButtonFormField<String>(
      decoration: dec.copyWith(label: _req('Currency')),
      isExpanded: true, isDense: true, itemHeight: null,
      initialValue: _priceCurrencyId,
      items: _currencies.map((c) => DropdownMenuItem(value: c['id'] as String,
          child: Text(c['currency_id'] as String, style: const TextStyle(fontSize: 13)))).toList(),
      onChanged: locked ? null : (v) {
        final c = _currencies.firstWhere((e) => e['id'] == v);
        unawaited(_onCurrencySelected(c));
      },
    ));
    final rateField = field(TextFormField(
      controller: _rateToBaseCtrl, enabled: !locked && showRate,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: dec.copyWith(labelText: 'Rate to Base ($_baseCurrency)'),
      style: const TextStyle(fontSize: 13),
      onChanged: (_) {
        setState(() {});
        for (final row in _lines) {
          if (row.productId != null) unawaited(_refreshLineCost(row));
        }
      },
    ));

    final customerField = Autocomplete<Map<String, dynamic>>(
      initialValue: TextEditingValue(text: _customerDisplay),
      displayStringForOption: (a) => '[${a['account_code']}] ${a['account_name']}',
      optionsBuilder: (v) async {
        if (locked) return const [];
        final accounts = await ref.read(accountsProvider.future);
        final customers = accounts.where((a) => a['account_nature'] == 'Customer');
        final q = v.text.toLowerCase().trim();
        if (q.isEmpty) return customers;
        return customers.where((a) =>
            (a['account_code'] as String).toLowerCase().contains(q) ||
            (a['account_name'] as String).toLowerCase().contains(q));
      },
      onSelected: (a) => setState(() {
        _customerId = a['id'] as String;
        _customerDisplay = '[${a['account_code']}] ${a['account_name']}';
      }),
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
    );

    final scanField = field(TextFormField(
      controller: _scanCtrl, enabled: !locked,
      decoration: dec.copyWith(labelText: 'Scan Barcode / Part Number', prefixIcon: const Icon(Icons.qr_code_scanner, size: 18)),
      style: const TextStyle(fontSize: 13),
      onFieldSubmitted: (v) => _onHeaderScanSubmitted(v),
    ));

    final remarksField = field(TextFormField(
      controller: _remarksCtrl, enabled: !locked,
      decoration: dec.copyWith(labelText: 'Remarks'),
      style: const TextStyle(fontSize: 13),
    ));

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  entryNoField, const SizedBox(height: 8),
                  Row(children: [Expanded(child: entryDateField), const SizedBox(width: 12), Expanded(child: effDateField)]),
                ])
              : Row(children: [
                  Expanded(flex: 2, child: entryNoField), const SizedBox(width: 12),
                  Expanded(flex: 2, child: entryDateField), const SizedBox(width: 12),
                  Expanded(flex: 2, child: effDateField),
                ]),
          const SizedBox(height: 12),
          isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  locationField, const SizedBox(height: 8),
                  Row(children: [Expanded(child: currencyField), const SizedBox(width: 12), Expanded(child: rateField)]),
                ])
              : Row(children: [
                  Expanded(flex: 2, child: locationField), const SizedBox(width: 12),
                  Expanded(flex: 2, child: currencyField), const SizedBox(width: 12),
                  Expanded(flex: 2, child: rateField),
                ]),
          if (locationLocked && !locked)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Location is locked once a line has been added — remove all lines to change it.',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'GENERIC', label: Text('Generic'), icon: Icon(Icons.public, size: 16)),
              ButtonSegment(value: 'CUSTOMER', label: Text('Customer-Specific'), icon: Icon(Icons.person_outline, size: 16)),
            ],
            selected: {_priceType},
            onSelectionChanged: priceTypeLocked ? null : (s) => _onPriceTypeChanged(s.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          if (priceTypeLocked && !locked)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Price Type is locked once a line has been added — remove all lines to change it.',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          if (_priceType == 'CUSTOMER') ...[
            const SizedBox(height: 12),
            isMobile ? field(customerField) : SizedBox(width: 400, height: fh, child: customerField),
          ],
          if (showScan) ...[
            const SizedBox(height: 12),
            isMobile ? scanField : SizedBox(width: 320, child: scanField),
          ],
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: remarksField),
        ]),
      ),
    );
  }

  Widget _buildLinesCard(bool locked) {
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
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No lines yet — add a product or scan a barcode.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)))
          else
            ..._lines.asMap().entries.map((entry) {
              final idx = entry.key;
              final row = entry.value;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                color: AppColors.background,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    SizedBox(width: 20, child: Text('${idx + 1}', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
                    SizedBox(
                      width: 210,
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
                          decoration: dec.copyWith(label: _req('Product')),
                          style: const TextStyle(fontSize: 13),
                        ),
                        optionsViewBuilder: (context, onSel, opts) => Align(
                          alignment: Alignment.topLeft,
                          child: Material(elevation: 4, borderRadius: BorderRadius.circular(4),
                            child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 260, minWidth: 260),
                              child: ListView.builder(padding: EdgeInsets.zero, shrinkWrap: true, itemCount: opts.length,
                                itemBuilder: (context, idx2) {
                                  final p = opts.elementAt(idx2);
                                  return InkWell(onTap: () => onSel(p),
                                      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          child: Text('[${p['product_code']}] ${p['product_name']}', style: const TextStyle(fontSize: 13))));
                                }),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 130, height: 48,
                      child: row.uomLoading
                          ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                          : DropdownButtonFormField<String>(
                              decoration: dec.copyWith(label: _req('UOM')),
                              isExpanded: true, isDense: true, itemHeight: null,
                              initialValue: row.uomId,
                              items: row.uomOptions.map((u) => DropdownMenuItem(
                                  value: u['uom_id'] as String,
                                  child: Text((u['uom'] as Map<String, dynamic>?)?['description'] as String? ?? '',
                                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                              onChanged: (locked || row.productId == null) ? null : (v) {
                                final opt = row.uomOptions.firstWhere((u) => u['uom_id'] == v);
                                _onUomSelected(row, opt);
                              },
                            ),
                    ),
                    SizedBox(width: 90, height: 48, child: InputDecorator(
                      decoration: dec.copyWith(labelText: 'Cost Price'),
                      child: row.costLoading
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(row.costPrice.toStringAsFixed(2), style: const TextStyle(fontSize: 13)),
                    )),
                    SizedBox(width: 90, child: TextFormField(
                      controller: row.marginPercentCtrl, enabled: !locked && row.costPrice > 0,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: dec.copyWith(labelText: 'Margin %'),
                      focusNode: row.marginFocusNode,
                      style: const TextStyle(fontSize: 13),
                      onChanged: locked ? null : (_) => _onMarginChanged(row),
                    )),
                    SizedBox(width: 110, child: TextFormField(
                      controller: row.sellingPriceCtrl, enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: dec.copyWith(label: _req('Selling Price')),
                      style: const TextStyle(fontSize: 13),
                      onChanged: locked ? null : (_) => _onSellingPriceChanged(row),
                    )),
                    if (row.isBelowCost)
                      SizedBox(width: 170, height: 48, child: DropdownButtonFormField<String>(
                        decoration: dec.copyWith(label: _req('Below-Cost Reason')),
                        isExpanded: true, isDense: true, itemHeight: null,
                        initialValue: row.belowCostReasonId,
                        items: _belowCostReasons.map((r) => DropdownMenuItem(value: r['id'] as String,
                            child: Text(r['description'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))).toList(),
                        onChanged: locked ? null : (v) => setState(() => row.belowCostReasonId = v),
                      )),
                    SizedBox(
                      width: 100,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Checkbox(
                          value: row.isTaxInclusive,
                          onChanged: locked ? null : (v) => setState(() => row.isTaxInclusive = v ?? false),
                        ),
                        const Text('Incl. Tax', style: TextStyle(fontSize: 12)),
                      ]),
                    ),
                    if (row.barcode != null && row.barcode!.isNotEmpty)
                      Tooltip(message: 'Scanned: ${row.barcode}', child: const Icon(Icons.qr_code, size: 18, color: AppColors.textSecondary)),
                    if (!locked) IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                      onPressed: () => _removeLine(row),
                    ),
                  ]),
                ),
              );
            }),
        ]),
      ),
    );
  }
}

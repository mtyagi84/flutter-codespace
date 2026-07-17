import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../providers/sales_invoice_providers.dart';

class _BatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final num availableBalance;
  final TextEditingController qtyCtrl = TextEditingController(text: '0');
  _BatchCandidate({required this.batchNo, this.expiryDate, required this.availableBalance});
  double get allocatedQty => double.tryParse(qtyCtrl.text) ?? 0;
}

class _SerialCandidate {
  final String serialNo;
  bool selected = false;
  _SerialCandidate({required this.serialNo});
}

class _InvoiceLineRow {
  String? productId;
  String  productDisplay = '';
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController barcodeCtrl = TextEditingController();
  String? matchedBarcode;
  String? uomId;
  String? uomLabel;
  double  uomConversionFactor = 1;
  final TextEditingController qtyPackCtrl  = TextEditingController(text: '0');
  final TextEditingController qtyLooseCtrl = TextEditingController(text: '0');
  final TextEditingController rateCtrl     = TextEditingController(text: '0');
  final TextEditingController discountPctCtrl = TextEditingController(text: '0');
  String? taxGroupId;
  String? taxGroupName;
  final TextEditingController remarksCtrl = TextEditingController();

  bool   priceResolved = false;
  String priceSource = 'PRICE_MASTER';
  final TextEditingController overrideReasonCtrl = TextEditingController();
  String? priceSourceEntryNo;

  // Set true the moment the user edits the Rate field directly; checked by
  // _resolvePrice before it applies an async-resolved price, so a slow
  // price lookup can never clobber a rate the cashier already typed while
  // it was in flight. Reset whenever a fresh resolution starts (new
  // product picked on this row).
  bool rateEditedByUser = false;

  String? discountGivenBy;
  String? discountGivenByName;

  int? sourceQuotationLineSerial;
  int? sourceOrderLineSerial;

  String trackingType = 'NONE';
  bool get isBatchTracked => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';
  List<_BatchCandidate> batchCandidates = [];
  List<_SerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int get serialSelectedCount => serialCandidates.where((s) => s.selected).length;

  // Set by _recompute() — plain fields, not getters, so line-loop
  // dependencies (charge apportionment, totals) never trigger repeated
  // recalculation mid-pass.
  double baseQty = 0;
  double grossAmount = 0;
  double discountAmount = 0;
  double taxableAmount = 0;
  double taxAmount = 0;
  double finalAmount = 0;
  double chargeAmount = 0;
  double landedAmount = 0;

  void dispose() {
    descCtrl.dispose();
    barcodeCtrl.dispose();
    qtyPackCtrl.dispose();
    qtyLooseCtrl.dispose();
    rateCtrl.dispose();
    discountPctCtrl.dispose();
    remarksCtrl.dispose();
    overrideReasonCtrl.dispose();
    for (final b in batchCandidates) {
      b.qtyCtrl.dispose();
    }
  }
}

class _InvoiceChargeRow {
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

class SalesInvoiceEntryScreen extends ConsumerStatefulWidget {
  final String? editInvoiceNo;
  final String? editInvoiceDate;
  final String? newInvoiceMode;
  final String? sourceQuotationNo;
  final String? sourceQuotationDate;
  final String? sourceOrderNo;
  final String? sourceOrderDate;

  const SalesInvoiceEntryScreen({
    super.key,
    this.editInvoiceNo,
    this.editInvoiceDate,
    this.newInvoiceMode,
    this.sourceQuotationNo,
    this.sourceQuotationDate,
    this.sourceOrderNo,
    this.sourceOrderDate,
  });

  @override
  ConsumerState<SalesInvoiceEntryScreen> createState() => _SalesInvoiceEntryScreenState();
}

class _SalesInvoiceEntryScreenState extends ConsumerState<SalesInvoiceEntryScreen>
    with ScreenPermissionMixin<SalesInvoiceEntryScreen> {
  @override
  String get screenName => '/sales/invoices';

  String? _invoiceNo;
  DateTime _invoiceDate = DateTime.now();
  String _invoiceMode = 'DIRECT';
  String _saleType = 'CASH';
  String _status = 'DRAFT';
  bool get _isNew => _invoiceNo == null;
  bool get _isAgainstSource => _invoiceMode != 'DIRECT';

  String? _sourceQuotationNo;
  String? _sourceQuotationDate;
  String? _sourceOrderNo;
  String? _sourceOrderDate;

  String? _customerId;
  String  _customerDisplay = '';
  final _partyNameCtrl = TextEditingController();
  final _partyPhoneCtrl = TextEditingController();
  final _partyAddressCtrl = TextEditingController();
  String? _salesPersonId;
  String  _salesPersonDisplay = '';

  String? _locationId;
  String  _locationName = '';
  String? _invoiceCurrencyId;
  String? _invoiceCurrencyCode;
  String  _baseCurrency = '';
  String  _localCurrency = '';
  final _rateToBaseCtrl = TextEditingController(text: '1');
  final _rateToLocalCtrl = TextEditingController(text: '1');

  final _headerDiscountPctCtrl = TextEditingController(text: '0');
  final _remarksCtrl = TextEditingController();

  final _collectedLocalCtrl = TextEditingController();
  final _collectedBaseCtrl = TextEditingController();

  List<_InvoiceLineRow> _lines = [];
  final List<_InvoiceChargeRow> _charges = [];
  List<Map<String, dynamic>> _additionalCharges = [];

  Map<String, dynamic>? _quickSetup;
  bool _cashSetupMissing = false;

  bool _canOverridePrice = false;
  bool _canGiveDiscount = false;
  double? _maxDiscountPercent;

  List<Map<String, dynamic>> _taxGroups = [];
  List<Map<String, dynamic>> _users = [];
  Map<String, double> _taxRatePct = {};
  Map<String, double> _taxGroupRatePct = {};

  // Snapshotted once at load time — never re-read mid-edit, matching the
  // backend's own "snapshot at save, never reinterpreted later" rule.
  bool _dispatchStock = true;
  bool _collectCash = true;

  bool _loading = true;
  bool _saving = false;
  bool _cancelling = false;
  bool _printing = false;
  String? _error;
  String? _actionError;

  double _grossTotal = 0, _discountTotal = 0, _taxTotal = 0, _grandTotal = 0;

  @override
  void initState() {
    super.initState();
    _invoiceNo = widget.editInvoiceNo;
    _sourceQuotationNo = widget.sourceQuotationNo;
    _sourceQuotationDate = widget.sourceQuotationDate;
    _sourceOrderNo = widget.sourceOrderNo;
    _sourceOrderDate = widget.sourceOrderDate;
    if (widget.newInvoiceMode != null) _invoiceMode = widget.newInvoiceMode!;
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _partyNameCtrl.dispose();
    _partyPhoneCtrl.dispose();
    _partyAddressCtrl.dispose();
    _rateToBaseCtrl.dispose();
    _rateToLocalCtrl.dispose();
    _headerDiscountPctCtrl.dispose();
    _remarksCtrl.dispose();
    _collectedLocalCtrl.dispose();
    _collectedBaseCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in _charges) {
      c.dispose();
    }
    super.dispose();
  }

  String _fmtDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _displayDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
  }

  void _showSnack(String msg, {required Color color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    _dispatchStock = session.quickInvoiceDispatchStock;
    _collectCash   = session.quickInvoiceCollectCash;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    try {
      final results = await Future.wait([
        ds.getUserSalesControls(clientId: session.clientId, companyId: session.companyId, userId: session.userId),
        ds.getTaxGroups(clientId: session.clientId, companyId: session.companyId),
        ds.getUsersForAutocomplete(clientId: session.clientId, companyId: session.companyId),
        ds.getAdditionalCharges(clientId: session.clientId, companyId: session.companyId),
      ]);
      final controls = results[0] as Map<String, dynamic>?;
      _taxGroups = results[1] as List<Map<String, dynamic>>;
      _users = results[2] as List<Map<String, dynamic>>;
      _additionalCharges = results[3] as List<Map<String, dynamic>>;
      _canOverridePrice  = controls?['can_override_price'] as bool? ?? false;
      _canGiveDiscount    = controls?['can_give_discount'] as bool? ?? false;
      _maxDiscountPercent = (controls?['max_discount_percent'] as num?)?.toDouble();
      await _loadTaxRates(ds);

      // Previously skipped offline entirely (leaving _quickSetup null —
      // cash customer/accounts never prefilled), because there was no
      // offline read path at all. Now that the repository serves this from
      // the shared Master-Data Sync cache when offline, call it
      // unconditionally like every other line in _init().
      _quickSetup = await ds.getQuickInvoiceSetup(clientId: session.clientId, companyId: session.companyId, userId: session.userId);

      if (_invoiceNo != null) {
        await _loadExisting(_invoiceNo!, widget.editInvoiceDate);
      } else if (_invoiceMode == 'AGAINST_QUOTATION') {
        await _loadFromQuotation(_sourceQuotationNo!, _sourceQuotationDate!, ds, session);
      } else if (_invoiceMode == 'AGAINST_ORDER') {
        await _loadFromOrder(_sourceOrderNo!, _sourceOrderDate!, ds, session);
      } else {
        _locationId = _quickSetup?['location_id'] as String? ?? session.locationId;
        _locationName = (_quickSetup?['location'] as Map<String, dynamic>?)?['location_name'] as String? ?? '';
        if (_saleType == 'CASH') await _applyCashCustomer(ds);
        _addLine();
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load data: $e'; });
    }
  }

  Future<void> _loadTaxRates(dynamic ds) async {
    final today = _fmtDate(DateTime.now());
    final groupIds = _taxGroups.map((g) => g['id'] as String).toList();
    final memberMap = await ds.getTaxGroupMemberTaxIds(groupIds);
    // Charges reference a single tax_id directly (not a tax group), so
    // their own tax IDs are folded in here too — otherwise a charge's tax
    // that happens not to also be a member of any product's tax group
    // would silently resolve to a 0% rate on screen.
    final chargeTaxIds = _additionalCharges
        .where((c) => c['is_taxable'] == true && c['tax_id'] != null)
        .map((c) => c['tax_id'] as String);
    final allTaxIds = <String>{...memberMap.values.expand((v) => v as List<String>), ...chargeTaxIds}.toList();
    _taxRatePct = await ds.getTaxRatesByIds(taxIds: allTaxIds, asOfDate: today);
    _taxGroupRatePct = {
      for (final entry in (memberMap as Map<String, List<String>>).entries)
        entry.key: entry.value.fold<double>(0, (s, taxId) => s + (_taxRatePct[taxId] ?? 0)),
    };
  }

  Future<void> _applyCashCustomer(dynamic ds) async {
    if (_quickSetup == null) { _cashSetupMissing = true; return; }
    final cashCustomer = _quickSetup!['cash_customer'] as Map<String, dynamic>?;
    _customerId = _quickSetup!['cash_customer_id'] as String?;
    _customerDisplay = cashCustomer == null ? '' : '[${cashCustomer['account_code']}] ${cashCustomer['account_name']}';
    _salesPersonId = _quickSetup!['default_sales_person_id'] as String?;
    _salesPersonDisplay = (_quickSetup!['default_sales_person'] as Map<String, dynamic>?)?['full_name'] as String? ?? '';
    if (_customerId != null) await _resolveCurrencyForCustomer(ds, _customerId!);
  }

  Future<void> _resolveCurrencyForCustomer(dynamic ds, String customerId) async {
    final session = ref.read(sessionProvider)!;
    final details = await ds.getCustomerDetails(customerId: customerId);
    final currency = details?['rim_currencies'] as Map<String, dynamic>?;
    final baseCcy = await ref.read(baseCurrencyProvider.future);
    final localCcy = await ref.read(localCurrencyProvider.future);
    _baseCurrency = baseCcy;
    _localCurrency = localCcy;
    final ccyCode = currency?['currency_id'] as String? ?? baseCcy;
    final currencies = await ref.read(currenciesProvider.future);
    if (currencies.isEmpty) {
      // No currency master data cached (e.g. offline and this module was
      // never synced) — bail out instead of crashing on currencies.first.
      // _saveAndApprove already blocks Save with a clear "Select a
      // currency" message when _invoiceCurrencyId stays null.
      _invoiceCurrencyId = null;
      _invoiceCurrencyCode = null;
      _showSnack('No currencies available — sync master data (Offline Data) before selecting a customer.', color: AppColors.negative);
      return;
    }
    final match = currencies.firstWhere((c) => c['currency_id'] == ccyCode, orElse: () => currencies.first);
    _invoiceCurrencyId = match['id'] as String;
    _invoiceCurrencyCode = ccyCode;
    if (ccyCode == baseCcy) {
      _rateToBaseCtrl.text = '1';
    } else {
      final r = await ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId ?? '', fromCurrency: ccyCode,
        toCurrency: baseCcy, rateDate: _fmtDate(_invoiceDate),
      );
      _rateToBaseCtrl.text = (r ?? 1).toString();
    }
    if (ccyCode == localCcy) {
      _rateToLocalCtrl.text = '1';
    } else {
      final r = await ds.getExchangeRate(
        companyId: session.companyId, locationId: _locationId ?? '', fromCurrency: ccyCode,
        toCurrency: localCcy, rateDate: _fmtDate(_invoiceDate),
      );
      _rateToLocalCtrl.text = (r ?? 1).toString();
    }
  }

  Future<void> _loadExisting(String invoiceNo, String? invoiceDate) async {
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final header = await ds.getHeader(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);
    if (header == null || !mounted) { setState(() => _loading = false); return; }

    final customer = header['customer'] as Map<String, dynamic>?;
    final salesPerson = header['sales_person'] as Map<String, dynamic>?;
    final currency = header['currency'] as Map<String, dynamic>?;
    final location = header['location'] as Map<String, dynamic>?;

    _invoiceNo = header['invoice_no'] as String;
    _invoiceDate = DateTime.parse(header['invoice_date'] as String);
    _invoiceMode = header['invoice_mode'] as String? ?? 'DIRECT';
    _saleType = header['sale_type'] as String? ?? 'CASH';
    _status = header['status'] as String? ?? 'DRAFT';
    _sourceQuotationNo = header['quotation_no'] as String?;
    _sourceQuotationDate = header['quotation_date'] as String?;
    _sourceOrderNo = header['order_no'] as String?;
    _sourceOrderDate = header['order_date'] as String?;
    _customerId = header['customer_id'] as String?;
    _customerDisplay = customer == null ? '' : '[${customer['account_code']}] ${customer['account_name']}';
    _partyNameCtrl.text = header['party_name'] as String? ?? '';
    _partyPhoneCtrl.text = header['party_phone'] as String? ?? '';
    _partyAddressCtrl.text = header['party_address'] as String? ?? '';
    _salesPersonId = header['sales_person_id'] as String?;
    _salesPersonDisplay = salesPerson?['full_name'] as String? ?? '';
    _locationId = header['location_id'] as String?;
    _locationName = location?['location_name'] as String? ?? '';
    _invoiceCurrencyId = header['invoice_currency_id'] as String?;
    _invoiceCurrencyCode = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text = '${header['rate_to_base'] ?? 1}';
    _rateToLocalCtrl.text = '${header['rate_to_local'] ?? 1}';
    _headerDiscountPctCtrl.text = '${header['discount_percent'] ?? 0}';
    _remarksCtrl.text = header['remarks'] as String? ?? '';
    _dispatchStock = header['stock_dispatch_mode'] == 'IMMEDIATE';
    _collectCash = header['cash_collection_mode'] == 'IMMEDIATE';
    _collectedLocalCtrl.text = header['collected_amount_local'] != null ? '${header['collected_amount_local']}' : '';
    _collectedBaseCtrl.text = header['collected_amount_base'] != null ? '${header['collected_amount_base']}' : '';

    final lines = await ds.getLines(clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate));
    for (final l in _lines) {
      l.dispose();
    }
    _lines = lines.map(_lineRowFromMap).toList();

    await _prefillChargesFromSource(await ds.getCharges(
      clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate),
    ));

    // Resume a DRAFT's batch/serial allocations — without this, reopening
    // one loses the previous allocation entirely (candidates would reload
    // at zero). Only relevant when this invoice will still dispatch stock.
    if (_dispatchStock && _lines.any((l) => l.isBatchTracked || l.isSerialTracked)) {
      await _restoreBatchSerialAllocations(ds, session);
    }

    if (mounted) setState(() { _loading = false; });
  }

  Future<void> _restoreBatchSerialAllocations(dynamic ds, dynamic session) async {
    final batchAllocs = await ds.getLineBatchAllocations(
      clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate),
    );
    final serialAllocs = await ds.getLineSerialAllocations(
      clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate),
    );
    for (final entry in _lines.asMap().entries) {
      final lineSerial = entry.key + 1;
      final row = entry.value;
      if (row.isBatchTracked || row.isSerialTracked) {
        await _loadCandidates(row); // populates the CURRENT candidate list
      }
      if (row.isBatchTracked) {
        for (final a in batchAllocs.where((a) => a['line_serial'] == lineSerial)) {
          final match = row.batchCandidates.where((b) => b.batchNo == a['batch_no']).toList();
          if (match.isNotEmpty) match.first.qtyCtrl.text = '${a['base_qty']}';
        }
      } else if (row.isSerialTracked) {
        for (final a in serialAllocs.where((a) => a['line_serial'] == lineSerial)) {
          final match = row.serialCandidates.where((s) => s.serialNo == a['serial_no']).toList();
          if (match.isNotEmpty) match.first.selected = true;
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadFromQuotation(String quotationNo, String quotationDate, dynamic ds, dynamic session) async {
    final header = await ds.getQuotationHeader(clientId: session.clientId, companyId: session.companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    if (header == null || !mounted) { setState(() { _loading = false; _error = 'Source quotation not found.'; }); return; }
    final customer = header['customer'] as Map<String, dynamic>?;
    final currency = header['currency'] as Map<String, dynamic>?;
    _saleType = 'CREDIT';
    _customerId = header['customer_id'] as String?;
    _customerDisplay = customer == null ? '' : '[${customer['account_code']}] ${customer['account_name']}';
    _invoiceCurrencyId = header['quotation_currency_id'] as String?;
    _invoiceCurrencyCode = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text = '${header['rate_to_base'] ?? 1}';
    _rateToLocalCtrl.text = '${header['rate_to_local'] ?? 1}';
    _locationId = session.locationId;

    final lines = await ds.getQuotationLines(clientId: session.clientId, companyId: session.companyId, quotationNo: quotationNo, quotationDate: quotationDate);
    _lines = lines.map((m) => _lineRowFromMap(m, sourceQuotationSerial: m['serial_no'] as int)).toList();
    for (final l in _lines) {
      if (l.isBatchTracked || l.isSerialTracked) {
        unawaited(_loadCandidates(l).then((_) => _autoAllocateBatchSerial(l)));
      }
    }

    // Read-only carry-forward — fn_save_sales_invoice copies the source
    // quotation's own charges verbatim server-side regardless of what's
    // shown here; this is purely so the cashier sees what will post.
    await _prefillChargesFromSource(await ds.getQuotationCharges(
      clientId: session.clientId, companyId: session.companyId, quotationNo: quotationNo, quotationDate: quotationDate,
    ));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadFromOrder(String orderNo, String orderDate, dynamic ds, dynamic session) async {
    final header = await ds.getOrderHeader(clientId: session.clientId, companyId: session.companyId, orderNo: orderNo, orderDate: orderDate);
    if (header == null || !mounted) { setState(() { _loading = false; _error = 'Source order not found.'; }); return; }
    final customer = header['customer'] as Map<String, dynamic>?;
    final currency = header['currency'] as Map<String, dynamic>?;
    _saleType = 'CREDIT';
    _customerId = header['customer_id'] as String?;
    _customerDisplay = customer == null ? '' : '[${customer['account_code']}] ${customer['account_name']}';
    _invoiceCurrencyId = header['order_currency_id'] as String?;
    _invoiceCurrencyCode = currency?['currency_id'] as String?;
    _rateToBaseCtrl.text = '${header['rate_to_base'] ?? 1}';
    _rateToLocalCtrl.text = '${header['rate_to_local'] ?? 1}';
    _locationId = session.locationId;

    final lines = await ds.getOrderLines(clientId: session.clientId, companyId: session.companyId, orderNo: orderNo, orderDate: orderDate);
    _lines = lines.map((m) => _lineRowFromMap(m, sourceOrderSerial: m['serial_no'] as int)).toList();
    for (final l in _lines) {
      if (l.isBatchTracked || l.isSerialTracked) {
        unawaited(_loadCandidates(l).then((_) => _autoAllocateBatchSerial(l)));
      }
    }

    await _prefillChargesFromSource(await ds.getOrderCharges(
      clientId: session.clientId, companyId: session.companyId, orderNo: orderNo, orderDate: orderDate,
    ));
    if (mounted) setState(() => _loading = false);
  }

  /// Shared by both AGAINST_QUOTATION and AGAINST_ORDER — populates
  /// _charges from the source document's own saved rows, read-only.
  Future<void> _prefillChargesFromSource(List<Map<String, dynamic>> sourceCharges) async {
    for (final c in _charges) { c.dispose(); }
    _charges.clear();
    for (final sc in sourceCharges) {
      final row = _InvoiceChargeRow()
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
  }

  _InvoiceLineRow _lineRowFromMap(Map<String, dynamic> m, {int? sourceQuotationSerial, int? sourceOrderSerial}) {
    final product = m['product'] as Map<String, dynamic>?;
    final uom = m['uom'] as Map<String, dynamic>?;
    final taxGroup = m['tax_group'] as Map<String, dynamic>?;
    final discountGiver = m['discount_giver'] as Map<String, dynamic>?;
    final row = _InvoiceLineRow()
      ..productId = m['product_id'] as String?
      ..productDisplay = product == null ? '' : '[${product['product_code']}] ${product['product_name']}'
      ..trackingType = product?['tracking_type'] as String? ?? 'NONE'
      ..uomId = m['uom_id'] as String?
      ..uomLabel = uom?['description'] as String?
      ..uomConversionFactor = (m['uom_conversion_factor'] as num? ?? 1).toDouble()
      ..taxGroupId = m['tax_group_id'] as String?
      ..taxGroupName = taxGroup?['group_name'] as String?
      ..priceSource = m['price_source'] as String? ?? 'PRICE_MASTER'
      ..priceResolved = true
      ..priceSourceEntryNo = m['price_source_entry_no'] as String?
      ..discountGivenBy = m['discount_given_by'] as String?
      ..discountGivenByName = discountGiver?['full_name'] as String?
      ..sourceQuotationLineSerial = sourceQuotationSerial ?? m['source_quotation_line_serial'] as int?
      ..sourceOrderLineSerial = sourceOrderSerial ?? m['source_order_line_serial'] as int?;
    row.descCtrl.text = m['item_description'] as String? ?? '';
    row.matchedBarcode = m['barcode'] as String?;
    row.qtyPackCtrl.text = '${m['qty_pack'] ?? m['base_qty'] ?? 0}';
    row.qtyLooseCtrl.text = '${m['qty_loose'] ?? 0}';
    row.rateCtrl.text = '${m['rate'] ?? 0}';
    row.discountPctCtrl.text = '${m['discount_percent'] ?? 0}';
    row.overrideReasonCtrl.text = m['price_override_reason'] as String? ?? '';
    row.remarksCtrl.text = m['remarks'] as String? ?? '';
    if (sourceQuotationSerial != null || sourceOrderSerial != null) {
      // Whole-document copy — qty is frozen, use base_qty directly.
      row.qtyPackCtrl.text = '${m['base_qty'] ?? 0}';
      row.qtyLooseCtrl.text = '0';
      row.uomConversionFactor = 1;
    }
    return row;
  }

  // ── Lines ────────────────────────────────────────────────────────────────

  void _addLine() {
    final row = _InvoiceLineRow();
    final headerDiscount = double.tryParse(_headerDiscountPctCtrl.text) ?? 0;
    if (headerDiscount > 0) row.discountPctCtrl.text = '$headerDiscount';
    setState(() => _lines.add(row));
  }

  void _removeLine(_InvoiceLineRow row) => setState(() { _lines.remove(row); row.dispose(); });

  // ── Charges (DIRECT mode only — AGAINST_QUOTATION/AGAINST_ORDER show a
  // read-only carry-forward from the source document, see
  // _prefillChargesFromSource) ────────────────────────────────────────────

  void _addCharge() => setState(() => _charges.add(_InvoiceChargeRow()));
  void _removeCharge(_InvoiceChargeRow row) => setState(() { _charges.remove(row); row.dispose(); });

  void _onChargeSelected(_InvoiceChargeRow row, Map<String, dynamic> charge) {
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

  Future<void> _onProductSelected(_InvoiceLineRow row, Map<String, dynamic> product) async {
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final session = ref.read(sessionProvider)!;
    row.productId = product['id'] as String;
    row.productDisplay = '[${product['product_code']}] ${product['product_name']}';
    row.trackingType = product['tracking_type'] as String? ?? 'NONE';
    row.taxGroupId = product['sales_tax_group_id'] as String?;
    row.taxGroupName = _taxGroups.firstWhere((g) => g['id'] == row.taxGroupId, orElse: () => const {})['group_name'] as String?;
    row.uomId = product['base_uom_id'] as String?;
    row.uomLabel = (product['uom'] as Map<String, dynamic>?)?['description'] as String?;
    row.uomConversionFactor = 1;
    row.rateEditedByUser = false; // a fresh product selection starts a new resolution
    if (row.qtyPackCtrl.text == '0' || row.qtyPackCtrl.text.isEmpty) row.qtyPackCtrl.text = '1';
    setState(() {});
    await _resolvePrice(row, ds, session);
    if (_dispatchStock && (row.isBatchTracked || row.isSerialTracked)) {
      await _loadCandidates(row);
      _autoAllocateBatchSerial(row);
    }
  }

  Future<void> _resolvePrice(_InvoiceLineRow row, dynamic ds, dynamic session) async {
    if (row.productId == null || row.uomId == null || _customerId == null || _invoiceCurrencyCode == null) return;
    final price = await ds.getActivePrice(
      clientId: session.clientId, companyId: session.companyId, locationId: _locationId ?? '',
      productId: row.productId!, uomId: row.uomId!, customerId: _customerId!,
      asOfDate: _fmtDate(_invoiceDate), currencyCode: _invoiceCurrencyCode!,
    );
    // The cashier may have already typed their own rate while this lookup
    // was in flight (the Rate field is editable pre-resolution whenever
    // canOverridePrice is true) — never clobber that with a stale result.
    if (row.rateEditedByUser) return;
    if (price != null) {
      row.rateCtrl.text = '${price['selling_price']}';
      row.priceSource = 'PRICE_MASTER';
      row.priceResolved = true;
      row.priceSourceEntryNo = price['entry_no'] as String?;
    } else {
      row.priceResolved = false;
      row.rateCtrl.text = '0';
    }
    if (mounted) setState(() {});
  }

  Future<void> _onBarcodeSubmitted(_InvoiceLineRow row, String code) async {
    if (code.trim().isEmpty) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final match = await ds.getProductByCode(
      clientId: session.clientId, companyId: session.companyId, code: code.trim(), tryPartNumber: false,
    );
    if (match == null) {
      _showSnack('No product found for "$code".', color: AppColors.negative);
      return;
    }
    await _onProductSelected(row, match);
    row.uomId = match['matched_uom_id'] as String? ?? row.uomId;
    row.uomConversionFactor = (match['matched_uom_conversion_factor'] as num?)?.toDouble() ?? row.uomConversionFactor;
    row.uomLabel = match['matched_uom_label'] as String? ?? row.uomLabel;
    row.matchedBarcode = code.trim();
    row.barcodeCtrl.clear();
    await _resolvePrice(row, ds, session);
    setState(() {});
  }

  Future<void> _loadCandidates(_InvoiceLineRow row) async {
    if (row.productId == null || _locationId == null) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    try {
      if (row.isBatchTracked) {
        final rows = await ds.getBatchStockBalance(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
        );
        row.batchCandidates = rows.map((b) => _BatchCandidate(
          batchNo: b['batch_no'] as String, expiryDate: b['expiry_date'] as String?,
          availableBalance: b['balance'] as num? ?? 0,
        )).toList();
      } else if (row.isSerialTracked) {
        final rows = await ds.getSerialStockStatus(
          clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: row.productId!,
        );
        row.serialCandidates = rows.map((s) => _SerialCandidate(serialNo: s['serial_no'] as String)).toList();
      }
      if (mounted) setState(() => row.candidatesLoaded = true);
    } catch (e) {
      if (mounted) _showSnack('Could not load batch/serial data for "${row.productDisplay}": $e', color: AppColors.negative);
    }
  }

  /// FEFO auto-fill — Quick Invoice is a POS checkout flow, so (unlike
  /// every back-office module in this schema, where batch/serial
  /// allocation is deliberately manual) the system pre-fills the required
  /// qty/count straight from the candidate lists' own existing order:
  /// batches come back from getBatchStockBalance already sorted
  /// expiry_date.asc.nullslast (FEFO — the same convention every other
  /// module's picker already uses as a UX hint), serials come back
  /// serial_no.asc. Deliberately NOT a company-configurable toggle — same
  /// reasoning CLAUDE.md already documents for why batch/serial handling
  /// in general never got a ric_companies flag: tracking_type is a
  /// per-product attribute, and here the auto-fill is a per-screen (Quick
  /// Invoice only) UX behaviour, not a per-company policy choice.
  ///
  /// Fields stay fully editable afterward — this is a starting point, not
  /// a lock. If a candidate's balance is insufficient to cover the line,
  /// the shortfall is left unfilled so the existing _batchSerialError /
  /// server-side BATCH_INSUFFICIENT_STOCK check still catches it, exactly
  /// as it would for a manual entry that comes up short.
  ///
  /// Re-running this (product changed, or the line's own qty changed)
  /// always recomputes from a clean slate — a cashier's earlier manual
  /// override on this line does NOT survive a qty edit. Deliberate
  /// trade-off for a fast-entry screen: re-deriving from scratch is
  /// simpler and more predictable than trying to preserve a partial
  /// manual edit against a now-different required quantity.
  void _onLineQtyChanged(_InvoiceLineRow row) {
    setState(() {});
    if (row.isBatchTracked || row.isSerialTracked) _autoAllocateBatchSerial(row);
  }

  void _autoAllocateBatchSerial(_InvoiceLineRow row) {
    if (!_dispatchStock || !row.candidatesLoaded) return;
    final needed = _isAgainstSource
        ? (double.tryParse(row.qtyPackCtrl.text) ?? 0)
        : (double.tryParse(row.qtyPackCtrl.text) ?? 0) * row.uomConversionFactor + (double.tryParse(row.qtyLooseCtrl.text) ?? 0);
    if (needed <= 0) return;
    if (row.isBatchTracked) {
      var remaining = needed;
      for (final b in row.batchCandidates) {
        final available = b.availableBalance.toDouble();
        final take = remaining <= 0 ? 0.0 : (available < remaining ? available : remaining);
        b.qtyCtrl.text = take > 0 ? take.toString() : '0';
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

  String? _batchSerialError(_InvoiceLineRow row) {
    if (!_dispatchStock || row.baseQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No batches currently in stock for "${row.productDisplay}".';
      if ((row.batchQtySum - row.baseQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productDisplay}" total ${row.batchQtySum.toStringAsFixed(2)} but the line quantity is ${row.baseQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialSelectedCount != row.baseQty.round()) {
        return 'Select exactly ${row.baseQty.round()} serial(s) for "${row.productDisplay}" (${row.serialSelectedCount} selected).';
      }
    }
    return null;
  }

  // ── Discount governance ─────────────────────────────────────────────────

  Future<void> _onDiscountChanged(_InvoiceLineRow row, String value) async {
    var pct = double.tryParse(value) ?? 0;
    // A discount outside [0, 100] is mathematically nonsensical regardless
    // of the cashier's own authorized cap (>100% makes the taxable amount
    // negative) — this is a hard ceiling, separate from the withinCap
    // authorization check below, which governs WHO can discount how much,
    // not whether an absurd value is ever valid at all.
    if (pct > 100 || pct < 0) {
      pct = pct.clamp(0, 100).toDouble();
      row.discountPctCtrl.text = pct.toStringAsFixed(0);
      _showSnack('Discount must be between 0% and 100% — capped at ${pct.toStringAsFixed(0)}%.', color: Colors.orange);
    }
    final withinCap = _canGiveDiscount && (_maxDiscountPercent == null || pct <= _maxDiscountPercent!);
    if (pct <= 0) {
      row.discountGivenBy = null;
      row.discountGivenByName = null;
    } else if (withinCap) {
      final session = ref.read(sessionProvider)!;
      row.discountGivenBy = session.userId;
      row.discountGivenByName = session.fullName;
    } else {
      // Exceeds cap (or no discount rights at all) — require an override
      // before the value is accepted; revert visually until authorized.
      final authorized = await _showDiscountOverrideDialog(pct);
      if (authorized == null) {
        row.discountPctCtrl.text = '0';
        row.discountGivenBy = null;
        row.discountGivenByName = null;
      } else {
        row.discountGivenBy = authorized['user_id'] as String;
        row.discountGivenByName = authorized['full_name'] as String;
      }
    }
    setState(() {});
  }

  Future<Map<String, dynamic>?> _showDiscountOverrideDialog(double requestedPct) async {
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String? dialogError;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Supervisor Override Required'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('A discount of ${requestedPct.toStringAsFixed(1)}% exceeds your authorized limit. '
                'Enter a supervisor\'s credentials to authorize it.'),
            const SizedBox(height: 12),
            TextField(controller: usernameCtrl, autofocus: true, decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: passwordCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
            if (dialogError != null) ...[
              const SizedBox(height: 10),
              Text(dialogError!, style: const TextStyle(color: AppColors.negative, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final session = ref.read(sessionProvider)!;
                try {
                  final res = await ref.read(salesInvoiceRepositoryProvider).verifyDiscountOverride(
                    clientId: session.clientId, companyId: session.companyId,
                    username: usernameCtrl.text.trim(), password: passwordCtrl.text,
                    requestedDiscountPercent: requestedPct,
                  );
                  if (dialogContext.mounted) Navigator.of(dialogContext, rootNavigator: true).pop(res);
                } on DioException catch (e) {
                  setDialogState(() => dialogError = e.response?.data?['message'] ?? 'Verification failed.');
                } catch (e) {
                  setDialogState(() => dialogError = 'Unexpected error: $e');
                }
              },
              child: const Text('Authorize'),
            ),
          ],
        ),
      ),
    );
    usernameCtrl.dispose();
    passwordCtrl.dispose();
    return result;
  }

  // ── Computed totals ──────────────────────────────────────────────────────

  void _recompute() {
    double subtotalBeforeCharges = 0;
    for (final l in _lines) {
      l.baseQty = _isAgainstSource ? (double.tryParse(l.qtyPackCtrl.text) ?? 0) : (double.tryParse(l.qtyPackCtrl.text) ?? 0) * l.uomConversionFactor + (double.tryParse(l.qtyLooseCtrl.text) ?? 0);
      final rate = double.tryParse(l.rateCtrl.text) ?? 0;
      final discountPct = double.tryParse(l.discountPctCtrl.text) ?? 0;
      l.grossAmount = l.baseQty * rate;
      l.discountAmount = l.grossAmount * discountPct / 100;
      l.taxableAmount = l.grossAmount - l.discountAmount;
      final ratePct = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount = l.taxableAmount * ratePct / 100;
      l.finalAmount = l.taxableAmount + l.taxAmount;
      subtotalBeforeCharges += l.taxableAmount;
    }
    // AGAINST_QUOTATION/AGAINST_ORDER: _charges is a read-only display of
    // what the server will copy verbatim from the source document — still
    // recomputed the same way so the on-screen total matches what posts.
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
    _grossTotal = _lines.fold(0.0, (s, l) => s + l.grossAmount);
    _discountTotal = _lines.fold(0.0, (s, l) => s + l.discountAmount);
    _taxTotal = _lines.fold(0.0, (s, l) => s + l.taxAmount);
    _grandTotal = _lines.fold(0.0, (s, l) => s + l.finalAmount) + _chargesTotal + _chargeTaxTotal;
  }

  double get _chargesTotal   => _charges.fold(0.0, (s, c) => s + (c.nature == 'DEDUCT' ? -c.amount : c.amount));
  double get _chargeTaxTotal => _charges.fold(0.0, (s, c) => s + c.taxAmount);

  /// Fans the header % out to every line as if it had been typed into
  /// each one individually — but resolves the override dialog (if the
  /// value exceeds the cashier's own cap) exactly ONCE for the whole
  /// batch, not once per line. Calling _onDiscountChanged per line here
  /// would pop one stacked dialog per line for the same value.
  Future<void> _applyHeaderDiscount(String value) async {
    var pct = double.tryParse(value) ?? 0;
    if (pct > 100 || pct < 0) {
      pct = pct.clamp(0, 100).toDouble();
      _headerDiscountPctCtrl.text = pct.toStringAsFixed(0);
      _showSnack('Discount must be between 0% and 100% — capped at ${pct.toStringAsFixed(0)}%.', color: Colors.orange);
    }

    final session = ref.read(sessionProvider)!;
    // Fanning the header % out to every line would otherwise silently wipe
    // any previously supervisor-authorized per-line discount — that
    // attribution is an audit trail, not just a number to overwrite.
    final authorizedByOthers = _lines.where((l) => l.discountGivenBy != null && l.discountGivenBy != session.userId).length;
    if (authorizedByOthers > 0) {
      final proceed = await _confirmOverwriteAuthorizedDiscounts(authorizedByOthers);
      if (!proceed) { setState(() {}); return; }
    }

    String? discountGivenBy;
    String? discountGivenByName;
    if (pct > 0) {
      final withinCap = _canGiveDiscount && (_maxDiscountPercent == null || pct <= _maxDiscountPercent!);
      if (withinCap) {
        discountGivenBy = session.userId;
        discountGivenByName = session.fullName;
      } else {
        final authorized = await _showDiscountOverrideDialog(pct);
        if (authorized == null) {
          // Not authorized — revert, don't touch any line.
          setState(() {});
          return;
        }
        discountGivenBy = authorized['user_id'] as String;
        discountGivenByName = authorized['full_name'] as String;
      }
    }
    for (final l in _lines) {
      l.discountPctCtrl.text = '$pct';
      l.discountGivenBy = pct > 0 ? discountGivenBy : null;
      l.discountGivenByName = pct > 0 ? discountGivenByName : null;
    }
    setState(() {});
  }

  Future<bool> _confirmOverwriteAuthorizedDiscounts(int count) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Overwrite Authorized Discount(s)?'),
        content: Text(
          '$count line${count == 1 ? '' : 's'} already ${count == 1 ? 'has' : 'have'} a supervisor-'
          'authorized discount. Applying the header discount will replace ${count == 1 ? 'it' : 'them'} '
          'with your own attribution instead. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Overwrite')),
        ],
      ),
    );
    return result ?? false;
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  Future<bool> _saveAndApprove() async {
    // Reentrancy guard — the Save button's own onPressed disable only takes
    // effect on the NEXT frame after setState, which leaves a real window
    // for a fast double-tap to fire this twice before the button visually
    // disables. This check is the actual guard; the button state is a UX nicety.
    if (_saving) return false;
    if (_saleType == 'CASH' && _cashSetupMissing) {
      _showSnack('You have no Quick Invoice Setup — ask an admin to assign a location, cash customer, and cash accounts first.', color: AppColors.negative);
      return false;
    }
    if (_customerId == null) { _showSnack('Select a customer.', color: AppColors.negative); return false; }
    if (_invoiceCurrencyId == null) { _showSnack('Select a currency.', color: AppColors.negative); return false; }
    if (_locationId == null) { _showSnack('Select a location.', color: AppColors.negative); return false; }
    final validLines = _lines.where((l) => l.productId != null).toList();
    if (validLines.isEmpty) { _showSnack('Add at least one line with a product and quantity.', color: AppColors.negative); return false; }

    _recompute();

    if (!_isAgainstSource) {
      for (final l in validLines) {
        if (l.baseQty <= 0) { _showSnack('${l.productDisplay}: quantity must be greater than zero.', color: AppColors.negative); return false; }
        if ((double.tryParse(l.rateCtrl.text) ?? 0) < 0) {
          _showSnack('${l.productDisplay}: rate cannot be negative.', color: AppColors.negative);
          return false;
        }
        if (!l.priceResolved && !_canOverridePrice) {
          _showSnack('${l.productDisplay}: no active price configured, and you are not authorized to override it.', color: AppColors.negative);
          return false;
        }
        if (l.priceSource == 'MANUAL_OVERRIDE' && l.overrideReasonCtrl.text.trim().isEmpty) {
          _showSnack('${l.productDisplay}: enter a reason for the price override.', color: AppColors.negative);
          return false;
        }
        final discountPct = double.tryParse(l.discountPctCtrl.text) ?? 0;
        if (discountPct > 0 && l.discountGivenBy == null) {
          _showSnack('${l.productDisplay}: discount needs authorization — re-enter it to trigger the check.', color: AppColors.negative);
          return false;
        }
      }
    }
    for (final l in validLines) {
      final err = _batchSerialError(l);
      if (err != null) { _showSnack(err, color: AppColors.negative); return false; }
    }
    final collectedLocal = double.tryParse(_collectedLocalCtrl.text);
    if (collectedLocal != null && collectedLocal < 0) {
      _showSnack('Collected amount (local currency) cannot be negative.', color: AppColors.negative);
      return false;
    }
    final collectedBase = double.tryParse(_collectedBaseCtrl.text);
    if (collectedBase != null && collectedBase < 0) {
      _showSnack('Collected amount (base currency) cannot be negative.', color: AppColors.negative);
      return false;
    }

    setState(() { _saving = true; _actionError = null; });
    final session = ref.read(sessionProvider)!;
    try {
      final header = {
        'client_id': session.clientId,
        'company_id': session.companyId,
        'location_id': _locationId,
        'invoice_no': _invoiceNo,
        'invoice_date': _fmtDate(_invoiceDate),
        'invoice_mode': _invoiceMode,
        'quotation_no': _sourceQuotationNo,
        'quotation_date': _sourceQuotationDate,
        'order_no': _sourceOrderNo,
        'order_date': _sourceOrderDate,
        'sale_type': _saleType,
        'customer_id': _customerId,
        'party_name': _partyNameCtrl.text.trim(),
        'party_phone': _partyPhoneCtrl.text.trim(),
        'party_address': _partyAddressCtrl.text.trim(),
        'sales_person_id': _salesPersonId,
        'invoice_currency_id': _invoiceCurrencyId,
        'rate_to_base': double.tryParse(_rateToBaseCtrl.text) ?? 1,
        'rate_to_local': double.tryParse(_rateToLocalCtrl.text) ?? 1,
        'discount_percent': double.tryParse(_headerDiscountPctCtrl.text) ?? 0,
        'gross_amount': _grossTotal,
        'discount_amount': _discountTotal,
        'charges_amount': _chargesTotal,
        'tax_amount': _taxTotal + _chargeTaxTotal,
        'grand_total': _grandTotal,
        'collected_amount_local': double.tryParse(_collectedLocalCtrl.text),
        'collected_amount_base': double.tryParse(_collectedBaseCtrl.text),
        'remarks': _remarksCtrl.text.trim(),
      };
      final lines = validLines.asMap().entries.map((e) => {
        'serial_no': e.key + 1,
        'product_id': e.value.productId,
        'item_description': e.value.descCtrl.text.trim(),
        'barcode': e.value.matchedBarcode ?? '',
        'uom_id': e.value.uomId,
        'uom_conversion_factor': e.value.uomConversionFactor,
        'qty_pack': _isAgainstSource ? 0 : (double.tryParse(e.value.qtyPackCtrl.text) ?? 0),
        'qty_loose': _isAgainstSource ? 0 : (double.tryParse(e.value.qtyLooseCtrl.text) ?? 0),
        'base_qty': e.value.baseQty,
        'rate': double.tryParse(e.value.rateCtrl.text) ?? 0,
        'price_override_reason': e.value.overrideReasonCtrl.text.trim(),
        'discount_given_by': e.value.discountGivenBy,
        'gross_amount': e.value.grossAmount,
        'discount_percent': double.tryParse(e.value.discountPctCtrl.text) ?? 0,
        'discount_amount': e.value.discountAmount,
        'tax_group_id': e.value.taxGroupId,
        'tax_amount': e.value.taxAmount,
        'final_amount': e.value.finalAmount,
        'base_amount': e.value.finalAmount * (double.tryParse(_rateToBaseCtrl.text) ?? 1),
        'local_amount': e.value.finalAmount * (double.tryParse(_rateToLocalCtrl.text) ?? 1),
        'charge_amount': e.value.chargeAmount,
        'landed_amount': e.value.landedAmount,
        'remarks': e.value.remarksCtrl.text.trim(),
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

      final batches = <Map<String, dynamic>>[];
      final serials = <Map<String, dynamic>>[];
      for (final e in validLines.asMap().entries) {
        final lineSerial = e.key + 1;
        final row = e.value;
        if (row.isBatchTracked) {
          for (final b in row.batchCandidates.where((b) => b.allocatedQty > 0)) {
            batches.add({'line_serial': lineSerial, 'batch_no': b.batchNo, 'expiry_date': b.expiryDate, 'qty_pack': b.allocatedQty, 'qty_loose': 0, 'base_qty': b.allocatedQty});
          }
        } else if (row.isSerialTracked) {
          for (final s in row.serialCandidates.where((s) => s.selected)) {
            serials.add({'line_serial': lineSerial, 'serial_no': s.serialNo});
          }
        }
      }

      final ds = ref.read(salesInvoiceRepositoryProvider);
      if (session.offlineMode) {
        if (_isAgainstSource) throw StateError('Against-Quotation/Order invoices require an online connection.');
        final localId = generateLocalId();
        await ref.read(syncEngineProvider).enqueue(
          documentType: 'SALES_INVOICE',
          documentId: localId,
          endpoint: '/rpc/fn_save_sales_invoice',
          payload: {'p_header': header, 'p_lines': lines, 'p_charges': charges, 'p_batches': batches, 'p_serials': serials, 'p_user_id': session.userId},
        );
        await ds.cacheInvoiceLocally(effectiveInvoiceNo: localId, header: header, lines: lines);
        if (mounted) {
          setState(() { _invoiceNo = localId; _status = 'DRAFT'; _saving = false; });
          _showSnack('Saved offline as $localId — will sync when online, then wait for Manager Review to post.', color: AppColors.secondary);
        }
        return true;
      }

      final invoiceNo = await ds.save(header: header, lines: lines, charges: charges, batches: batches, serials: serials, userId: session.userId);
      await ds.approve(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: _fmtDate(_invoiceDate), approvedBy: session.userId);
      await _loadExisting(invoiceNo, _fmtDate(_invoiceDate));
      if (mounted) {
        setState(() => _saving = false);
        _showSnack('Sales Invoice $invoiceNo completed.', color: AppColors.positive);
      }
      return true;
    } on DioException catch (e) {
      setState(() { _saving = false; _actionError = e.response?.data?['message'] ?? 'Save failed: ${e.message}'; });
      return false;
    } catch (e) {
      setState(() { _saving = false; _actionError = 'Unexpected error: $e'; });
      return false;
    }
  }

  Future<void> _cancel() async {
    if (_invoiceNo == null || _cancelling) return;
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel Invoice'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This marks the invoice as cancelled. Continue?'),
          const SizedBox(height: 12),
          TextFormField(controller: reasonCtrl, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Reason'), maxLines: 2),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(), child: const Text('No')),
          FilledButton(
            onPressed: () {
              if (reasonCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('Enter a reason for cancelling this invoice.'), backgroundColor: Colors.orange));
                return;
              }
              Navigator.of(dialogContext, rootNavigator: true).pop(reasonCtrl.text.trim());
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            child: const Text('Cancel Invoice'),
          ),
        ],
      ),
    );
    reasonCtrl.dispose();
    if (reason == null || reason.isEmpty) return;

    final session = ref.read(sessionProvider)!;
    setState(() { _actionError = null; _cancelling = true; });
    try {
      await ref.read(salesInvoiceRepositoryProvider).cancel(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate), reason: reason, userId: session.userId,
      );
      if (mounted) {
        _showSnack('Sales Invoice $_invoiceNo cancelled.', color: AppColors.positive);
        await _loadExisting(_invoiceNo!, _fmtDate(_invoiceDate));
      }
    } on DioException catch (e) {
      if (mounted) setState(() => _actionError = e.response?.data?['message'] ?? 'Cancel failed.');
    } catch (e) {
      if (mounted) setState(() => _actionError = 'Unexpected error: $e');
    } finally {
      // Reset in `finally`, not just the catch branches — a post-success
      // _loadExisting() failure would otherwise leave _cancelling stuck
      // true forever, permanently disabling the Cancel button.
      if (mounted) setState(() => _cancelling = false);
    }
  }

  // ── Print ────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company) {
    _recompute();
    return {
      'company': company,
      'header': {
        'invoice_no': _invoiceNo ?? '',
        'invoice_date': _displayDate(_fmtDate(_invoiceDate)),
        'provisional': (_invoiceNo ?? '').startsWith('LOCAL-'),
        'sale_type': _saleType,
        'status': _status,
        'customer_name': _saleType == 'CASH' && _partyNameCtrl.text.isNotEmpty
            ? _partyNameCtrl.text
            : (_customerDisplay.contains('] ') ? _customerDisplay.split('] ').last : _customerDisplay),
        'party_phone': _partyPhoneCtrl.text,
        'party_address': _partyAddressCtrl.text,
        'sales_person_name': _salesPersonDisplay,
        'currency_code': _invoiceCurrencyCode ?? '',
        'remarks': _remarksCtrl.text,
      },
      'lines': _lines.where((l) => l.productId != null && l.baseQty > 0).map((l) => {
        'product_name': l.productDisplay.contains('] ') ? l.productDisplay.split('] ').last : l.productDisplay,
        'uom_label': l.uomLabel ?? '',
        'base_qty': l.baseQty,
        'rate': double.tryParse(l.rateCtrl.text) ?? 0,
        'final_amount': l.finalAmount,
      }).toList(),
      'charges': _charges.where((c) => c.chargeId != null).map((c) => {
        'charge_name': c.chargeName,
        'amount': c.nature == 'DEDUCT' ? -c.amount : c.amount,
      }).toList(),
      'totals': {
        'gross_amount': _grossTotal,
        'discount_amount': _discountTotal,
        'charges_amount': _chargesTotal,
        'tax_amount': _taxTotal + _chargeTaxTotal,
        'grand_total': _grandTotal,
      },
    };
  }

  Future<void> _printInvoice() async {
    if (_invoiceNo == null) return;
    setState(() => _printing = true);
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('SALES_INVOICE').future);
      final document = _buildPrintDocument(company);
      await PrintEngine.printDocument(template: template, document: document, filename: '$_invoiceNo.pdf');
    } catch (e) {
      _showSnack('Print failed: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Widget _buildPrintButton() => Tooltip(
        message: 'Print',
        child: IconButton(
          onPressed: _printing ? null : _printInvoice,
          icon: _printing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.print_outlined),
        ),
      );

  // ── UI helpers ───────────────────────────────────────────────────────────

  static Widget _req(String text) => RichText(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
          children: const [TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600))],
        ),
      );

  Widget _statusChip(String status) {
    final color = switch (status) {
      'DRAFT' => AppColors.badgeDraft,
      'APPROVED' => AppColors.positive,
      'CANCELLED' => AppColors.negative,
      _ => AppColors.positive,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _errorBanner(String message, {VoidCallback? onRetry}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.negative.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.negative.withValues(alpha: 0.3))),
        child: Row(children: [
          const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(color: AppColors.negative, fontSize: 13))),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );

  Widget _buildTitleBlock() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_invoiceNo != null ? 'Quick Invoice · $_invoiceNo' : 'New Quick Invoice',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
        const SizedBox(height: 2),
        Row(children: [
          _invoiceNo != null ? _statusChip(_status) : const Text('Unsaved', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(width: 8),
          Text(_saleType == 'CASH' ? 'Cash Sale' : 'Credit Sale', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (_sourceQuotationNo != null) ...[const SizedBox(width: 8), Text('From $_sourceQuotationNo', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))],
          if (_sourceOrderNo != null) ...[const SizedBox(width: 8), Text('From $_sourceOrderNo', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))],
          if (_invoiceNo != null) ...[const SizedBox(width: 8), PendingSyncBadge(documentType: 'SALES_INVOICE', documentId: _invoiceNo!)],
        ]),
      ]);

  @override
  Widget build(BuildContext context) {
    if (!_loading) _recompute();
    final session = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    final showLooseQty = !_isAgainstSource && (session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
    final showBarcode = !_isAgainstSource && (session?.enableBarcode ?? false);
    final locked = _status != 'DRAFT';
    final canSave = _status == 'DRAFT' && (_isNew ? canAdd : canEdit);
    final showCancel = !isOffline && _status == 'DRAFT' && canApprove && !_isNew;

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
                    if (_invoiceNo != null) _buildPrintButton(),
                    Expanded(child: _buildActionButtons(canSave: canSave, showCancel: showCancel)),
                  ]),
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (_invoiceNo != null) _buildPrintButton(),
                  _buildActionButtons(canSave: canSave, showCancel: showCancel),
                ]),
        ),
        const Divider(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : CustomScrollView(
                  slivers: [
                    // Everything above the line items is small/fixed-size —
                    // a SliverToBoxAdapter per section is fine here. Only
                    // the line items themselves (previously a plain
                    // Column.map, i.e. every row built eagerly regardless
                    // of scroll position) get a real SliverList — the only
                    // part of this screen where a realistic basket size
                    // (30-50+ lines) could plausibly be built at once.
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                      sliver: SliverToBoxAdapter(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (_error != null) ...[_errorBanner(_error!, onRetry: _init), const SizedBox(height: 16)],
                          if (_actionError != null) ...[_errorBanner(_actionError!), const SizedBox(height: 16)],
                          if (_cashSetupMissing && _saleType == 'CASH') ...[
                            _errorBanner('This user has no Quick Invoice Setup — ask an admin to assign a location, cash customer, and cash accounts before making a Cash sale.'),
                            const SizedBox(height: 16),
                          ],
                          _buildHeaderCard(locked, isMobile),
                          const SizedBox(height: 16),
                          _buildLinesHeaderCard(locked),
                        ]),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _buildLineTile(_lines[index], locked, showLooseQty, showBarcode),
                          childCount: _lines.length,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                      sliver: SliverToBoxAdapter(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const SizedBox(height: 4),
                          _buildChargesCard(locked),
                          const SizedBox(height: 16),
                          if (_collectCash) ...[_buildPaymentCard(locked), const SizedBox(height: 16)],
                          _buildTotalsCard(),
                        ]),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildActionButtons({required bool canSave, required bool showCancel}) => Wrap(spacing: 12, runSpacing: 8, children: [
        if (canSave) FilledButton(
          onPressed: _saving ? null : _saveAndApprove,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save Invoice'),
        ),
        if (showCancel) OutlinedButton(
          onPressed: _cancelling ? null : _cancel,
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.negative, side: const BorderSide(color: AppColors.negative)),
          child: _cancelling
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.negative))
              : const Text('Cancel'),
        ),
      ]);

  Widget _buildHeaderCard(bool locked, bool isMobile) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_isNew) SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'CASH', label: Text('Cash'), icon: Icon(Icons.payments_outlined)),
              ButtonSegment(value: 'CREDIT', label: Text('Credit'), icon: Icon(Icons.credit_card_outlined)),
            ],
            selected: {_saleType},
            onSelectionChanged: _isAgainstSource ? null : (s) {
              setState(() { _saleType = s.first; });
              final ds = ref.read(salesInvoiceRepositoryProvider);
              if (_saleType == 'CASH') {
                unawaited(_applyCashCustomer(ds).then((_) { if (mounted) setState(() {}); }));
              } else {
                _customerId = null;
                _customerDisplay = '';
              }
            },
          ),
          const SizedBox(height: 16),
          if (_saleType == 'CASH') ...[
            Wrap(spacing: 16, runSpacing: 12, children: [
              SizedBox(width: isMobile ? double.infinity : 260, child: TextFormField(controller: _partyNameCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Walk-in Customer Name (optional)'))),
              SizedBox(width: isMobile ? double.infinity : 200, child: TextFormField(controller: _partyPhoneCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Mobile (optional)'))),
              SizedBox(width: isMobile ? double.infinity : 260, child: TextFormField(controller: _partyAddressCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Address (optional)'))),
            ]),
          ] else ...[
            _isAgainstSource
                ? InputDecorator(decoration: dec.copyWith(labelText: 'Customer'), child: Text(_customerDisplay.isEmpty ? '—' : _customerDisplay, style: const TextStyle(fontSize: 13)))
                : SizedBox(
                    width: isMobile ? double.infinity : 320,
                    child: Autocomplete<Map<String, dynamic>>(
                      initialValue: TextEditingValue(text: _customerDisplay),
                      displayStringForOption: (a) => '[${a['account_code']}] ${a['account_name']}',
                      optionsBuilder: (v) async {
                        final accounts = await ref.read(accountsProvider.future);
                        final customers = accounts.where((a) => a['account_nature'] == 'Customer');
                        final q = v.text.toLowerCase().trim();
                        if (q.isEmpty) return customers;
                        return customers.where((a) => (a['account_code'] as String).toLowerCase().contains(q) || (a['account_name'] as String).toLowerCase().contains(q));
                      },
                      onSelected: (a) async {
                        _customerId = a['id'] as String;
                        _customerDisplay = '[${a['account_code']}] ${a['account_name']}';
                        final session = ref.read(sessionProvider)!;
                        final ds = ref.read(salesInvoiceRepositoryProvider);
                        try {
                          await _resolveCurrencyForCustomer(ds, _customerId!);
                          // Re-resolve price for any line added before the
                          // customer was picked — _resolvePrice no-ops
                          // silently when _customerId is null, so those
                          // lines would otherwise be stuck unpriced.
                          for (final l in _lines.where((l) => l.productId != null)) {
                            await _resolvePrice(l, ds, session);
                          }
                        } catch (e) {
                          // Unlike the Cash-sale path (covered by _init()'s
                          // own try/catch), this callback has no enclosing
                          // handler — an uncaught error here previously
                          // surfaced as an unhandled exception with no user
                          // feedback at all.
                          if (mounted) _showSnack('Could not resolve currency/price for this customer: $e', color: AppColors.negative);
                        }
                        if (mounted) setState(() {});
                      },
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
                                      return InkWell(onTap: () => onSel(a), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text('[${a['account_code']}] ${a['account_name']}', style: const TextStyle(fontSize: 13))));
                                    }))),
                      ),
                    ),
                  ),
            const SizedBox(height: 12),
            SizedBox(
              width: isMobile ? double.infinity : 260,
              child: DropdownButtonFormField<String>(
                decoration: dec.copyWith(labelText: 'Sales Person'),
                isExpanded: true, isDense: true, itemHeight: null,
                initialValue: _salesPersonId,
                items: [
                  const DropdownMenuItem(value: null, child: Text('— None —')),
                  ..._users.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['full_name'] as String, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: locked ? null : (v) => setState(() {
                  _salesPersonId = v;
                  _salesPersonDisplay = _users.firstWhere((u) => u['id'] == v, orElse: () => const {})['full_name'] as String? ?? '';
                }),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('Location: ${_locationName.isEmpty ? '—' : _locationName}', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
            Text('Currency: ${_invoiceCurrencyCode ?? '—'}', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ]),
          // Previously resolved silently with no way for the cashier to see
          // or correct it — a missing/unconfigured rate defaulted to 1:1
          // invisibly. Shown (and, for authorized users, editable) whenever
          // the invoice currency actually differs from base/local.
          if (_invoiceCurrencyCode != null && (_invoiceCurrencyCode != _baseCurrency || _invoiceCurrencyCode != _localCurrency)) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 12, children: [
              if (_invoiceCurrencyCode != _baseCurrency)
                SizedBox(
                  width: isMobile ? double.infinity : 200,
                  child: TextFormField(
                    controller: _rateToBaseCtrl, enabled: !locked && _canOverridePrice,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Rate to Base ($_baseCurrency)'),
                    onChanged: locked ? null : (_) => setState(() {}),
                  ),
                ),
              if (_invoiceCurrencyCode != _localCurrency)
                SizedBox(
                  width: isMobile ? double.infinity : 200,
                  child: TextFormField(
                    controller: _rateToLocalCtrl, enabled: !locked && _canOverridePrice,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dec.copyWith(labelText: 'Rate to Local ($_localCurrency)'),
                    onChanged: locked ? null : (_) => setState(() {}),
                  ),
                ),
            ]),
          ],
          if (!_isAgainstSource) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: 200,
              child: TextFormField(
                controller: _headerDiscountPctCtrl, enabled: !locked,
                keyboardType: TextInputType.number,
                decoration: dec.copyWith(labelText: 'Header Discount % (fans out to lines)'),
                onChanged: locked ? null : _applyHeaderDiscount,
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Remarks (optional)'), maxLines: 2),
        ]),
      ),
    );
  }

  // Split from the line tiles themselves (build()'s SliverList renders
  // those directly) so a realistic 30-50+ line invoice doesn't build every
  // row eagerly regardless of scroll position — previously a plain
  // Column.map inside a SingleChildScrollView. This header keeps the same
  // "Lines" title + Add Line button; each tile below keeps its own
  // existing border/margin (see _buildLineTile), so the section still
  // reads as one group even without a single enclosing card border.
  Widget _buildLinesHeaderCard(bool locked) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          const Expanded(child: Text('Lines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          if (!locked && !_isAgainstSource) TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add, size: 16), label: const Text('Add Line')),
        ]),
      ),
    );
  }

  Widget _buildLineTile(_InvoiceLineRow row, bool locked, bool showLooseQty, bool showBarcode) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));
    final rowLocked = locked || _isAgainstSource;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            flex: 3,
            child: rowLocked
                ? InputDecorator(decoration: dec.copyWith(labelText: 'Product'), child: Text(row.productDisplay.isEmpty ? '—' : row.productDisplay, style: const TextStyle(fontSize: 13)))
                : Autocomplete<Map<String, dynamic>>(
                    initialValue: TextEditingValue(text: row.productDisplay),
                    displayStringForOption: (p) => '[${p['product_code']}] ${p['product_name']}',
                    optionsBuilder: (v) async {
                      final session = ref.read(sessionProvider)!;
                      final ds = ref.read(salesInvoiceRepositoryProvider);
                      return ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: v.text);
                    },
                    onSelected: (p) => _onProductSelected(row, p),
                    fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
                      controller: textCtrl, focusNode: focusNode,
                      decoration: dec.copyWith(label: _req('Product')),
                      style: const TextStyle(fontSize: 13),
                    ),
                    optionsViewBuilder: (context, onSel, opts) => Align(
                      alignment: Alignment.topLeft,
                      child: Material(elevation: 4, borderRadius: BorderRadius.circular(4),
                          child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 260, minWidth: 280),
                              child: ListView.builder(padding: EdgeInsets.zero, shrinkWrap: true, itemCount: opts.length,
                                  itemBuilder: (context, idx) {
                                    final p = opts.elementAt(idx);
                                    return InkWell(onTap: () => onSel(p), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text('[${p['product_code']}] ${p['product_name']}', style: const TextStyle(fontSize: 13))));
                                  }))),
                    ),
                  ),
          ),
          if (showBarcode && !rowLocked) ...[
            const SizedBox(width: 8),
            SizedBox(width: 140, child: TextFormField(controller: row.barcodeCtrl, decoration: dec.copyWith(labelText: 'Scan'), onFieldSubmitted: (v) => _onBarcodeSubmitted(row, v))),
          ],
          if (!locked && !_isAgainstSource) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeLine(row)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(width: 100, child: TextFormField(controller: row.qtyPackCtrl, enabled: !rowLocked, keyboardType: TextInputType.number,
              decoration: dec.copyWith(label: _req(showLooseQty ? 'Qty Pack' : 'Quantity')), onChanged: (_) => _onLineQtyChanged(row))),
          if (showLooseQty) SizedBox(width: 100, child: TextFormField(controller: row.qtyLooseCtrl, enabled: !rowLocked, keyboardType: TextInputType.number,
              decoration: dec.copyWith(labelText: 'Qty Loose'), onChanged: (_) => _onLineQtyChanged(row))),
          SizedBox(width: 110, child: TextFormField(controller: row.rateCtrl, enabled: !locked && (row.priceSource == 'MANUAL_OVERRIDE' || (!row.priceResolved && _canOverridePrice)),
              keyboardType: TextInputType.number, decoration: dec.copyWith(labelText: 'Rate'),
              onChanged: (_) { row.rateEditedByUser = true; setState(() {}); })),
          if (!locked && !_isAgainstSource && !row.priceResolved && _canOverridePrice)
            TextButton(onPressed: () => setState(() => row.priceSource = 'MANUAL_OVERRIDE'), child: const Text('Override Price')),
          SizedBox(width: 100, child: TextFormField(controller: row.discountPctCtrl, enabled: !rowLocked, keyboardType: TextInputType.number,
              decoration: dec.copyWith(labelText: 'Disc %'), onChanged: (v) => _onDiscountChanged(row, v))),
          if (row.discountGivenByName != null && row.discountGivenByName!.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text('by ${row.discountGivenByName}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
          SizedBox(width: 90, child: InputDecorator(decoration: dec.copyWith(labelText: 'Tax'), child: Text(row.taxGroupName ?? '—', style: const TextStyle(fontSize: 12)))),
          SizedBox(width: 110, child: Padding(padding: const EdgeInsets.only(top: 12), child: Text('= ${row.finalAmount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)))),
        ]),
        if (row.priceSource == 'MANUAL_OVERRIDE' && !locked)
          Padding(padding: const EdgeInsets.only(top: 10), child: TextFormField(controller: row.overrideReasonCtrl, decoration: dec.copyWith(label: _req('Override Reason')))),
        if (_dispatchStock && (row.isBatchTracked || row.isSerialTracked)) _buildBatchSerialSection(row, locked),
      ]),
    );
  }

  Widget _buildBatchSerialSection(_InvoiceLineRow row, bool locked) {
    if (!row.candidatesLoaded) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator());
    }
    final err = _batchSerialError(row);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(
              '${row.isBatchTracked ? 'Batch' : 'Serial'} Allocation — auto-filled (FEFO), edit if needed',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          if (!locked) TextButton(
            onPressed: () => _autoAllocateBatchSerial(row),
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Text('Reset to FEFO', style: TextStyle(fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 6),
        if (row.isBatchTracked)
          Wrap(spacing: 10, runSpacing: 8, children: row.batchCandidates.map((b) => SizedBox(
                width: 200,
                child: TextFormField(
                  controller: b.qtyCtrl, enabled: !locked, keyboardType: TextInputType.number,
                  decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, labelText: '${b.batchNo} (avail ${b.availableBalance})${b.expiryDate != null ? ' · exp ${b.expiryDate}' : ''}'),
                  onChanged: (_) => setState(() {}),
                ),
              )).toList())
        else
          Wrap(spacing: 8, runSpacing: 8, children: row.serialCandidates.map((s) => FilterChip(
                label: Text(s.serialNo, style: const TextStyle(fontSize: 12)),
                selected: s.selected,
                onSelected: locked ? null : (v) => setState(() => s.selected = v),
              )).toList()),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(err, style: const TextStyle(fontSize: 11, color: AppColors.negative))),
      ]),
    );
  }

  Widget _buildPaymentCard(bool locked) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Collect Payment', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Enter what was actually collected — one or both currencies. Leave blank/zero to defer.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          Wrap(spacing: 16, runSpacing: 12, children: [
            SizedBox(width: 220, child: TextFormField(controller: _collectedLocalCtrl, enabled: !locked, keyboardType: TextInputType.number, decoration: dec.copyWith(labelText: 'Collected — Local Currency'))),
            SizedBox(width: 220, child: TextFormField(controller: _collectedBaseCtrl, enabled: !locked, keyboardType: TextInputType.number, decoration: dec.copyWith(labelText: 'Collected — Base Currency'))),
          ]),
        ]),
      ),
    );
  }

  Widget _buildChargesCard(bool locked) {
    // AGAINST_QUOTATION/AGAINST_ORDER: always read-only — the server
    // copies the source document's own charges verbatim regardless of
    // what's shown here (see _prefillChargesFromSource), so there is
    // nothing to legitimately edit, same rule already governing this
    // module's line items in those two modes.
    final chargesLocked = locked || _isAgainstSource;
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(
                _isAgainstSource ? 'Charges (carried forward from source — read-only)' : 'Charges (optional)',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            if (!chargesLocked) TextButton.icon(onPressed: _addCharge, icon: const Icon(Icons.add, size: 16), label: const Text('Add Charge')),
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
                  onChanged: chargesLocked ? null : (v) {
                    final c = _additionalCharges.firstWhere((e) => e['id'] == v);
                    _onChargeSelected(row, c);
                  },
                )),
                SizedBox(width: 100, child: TextFormField(
                  controller: row.valueCtrl, enabled: !chargesLocked,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dec.copyWith(labelText: row.amountOrPercent == 'PERCENT' ? 'Percent' : 'Amount'),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() {}),
                )),
                SizedBox(width: 90, child: Text('${row.nature} · ${row.amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                if (row.isTaxable) SizedBox(width: 90, child: Text('Tax: ${row.taxAmount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                if (!chargesLocked) IconButton(
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
    Widget row(String label, double value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            SizedBox(width: 140, child: Text(label, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
            SizedBox(width: 120, child: Text(value.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
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
          row('Tax', _taxTotal + _chargeTaxTotal),
          row('Charges', _chargesTotal),
          const Divider(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            const SizedBox(width: 140, child: Text('GRAND TOTAL', textAlign: TextAlign.right, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
            SizedBox(width: 120, child: Text(_grandTotal.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.primary))),
          ]),
        ]),
      ),
    );
  }
}

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
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/local_id.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/pending_sync_badge.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../../../../core/widgets/sakal_field_row.dart';
import '../../../../core/widgets/sakal_financial_summary_card.dart';
import '../../../../core/widgets/sakal_formatted_number_field.dart';
import '../../../../core/widgets/sakal_line_item_card.dart';
import '../../../../core/widgets/sakal_table_header_bar.dart';
import '../../domain/repositories/sales_invoice_repository.dart';
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

  // Keyboard-only entry chaining: Enter on Disc% moves focus here; the (+)
  // button itself requests focus onto the NEXT row's productFocusNode once
  // that row exists.
  final FocusNode productFocusNode = FocusNode();
  final FocusNode addButtonFocusNode = FocusNode();

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
    productFocusNode.dispose();
    addButtonFocusNode.dispose();
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

  // Resolved once in _loadExisting (against _users, already loaded by
  // _init before it) — print's "Prepared By"/"Authorised By" data supply.
  // Sales Invoice's own default receipt template doesn't render a
  // signature block (deliberate — a POS receipt, not a document routed
  // for signature), but the data is still supplied so a company's own
  // custom template can bind to it via the print designer.
  String? _preparedByName;
  String? _authorisedByName;

  // Posted Journal Entries — an APPROVED invoice can have up to 4 separate
  // vouchers (sales always, cost-of-sales only if stock dispatched, either
  // cash-receipt voucher only if cash was actually collected). Each entry
  // is (label, voucherNo, voucherDate); lines are fetched per-voucher and
  // keyed by voucherNo in _voucherLines. See _buildPostedVoucherSection.
  bool _loadingVoucherLines = false;
  final Map<String, List<Map<String, dynamic>>> _voucherLines = {};
  final Map<String, String> _voucherNumbersByLabel = {};
  String? _salesVoucherNo, _salesVoucherDate;
  String? _cosVoucherNo, _cosVoucherDate;
  String? _localReceiptVoucherNo, _localReceiptVoucherDate;
  String? _baseReceiptVoucherNo, _baseReceiptVoucherDate;

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
  // A row removed from _lines (single delete, or a whole-list replace on
  // reload-after-save / mode-switch) is NEVER disposed at that moment —
  // its widget (and FocusNode) can still be mounted for the rest of the
  // CURRENT frame even after setState() schedules a rebuild, and disposing
  // a still-attached FocusNode throws "used after being disposed" (a real,
  // repeat crash). Deferring to a postFrameCallback was tried and still
  // didn't reliably avoid it, so disposal is deferred further still — all
  // the way to this screen's own dispose() — trading a few short-lived
  // controllers/focus nodes staying alive slightly longer per edit session
  // for a guaranteed-safe disposal point with zero timing assumptions.
  final List<_InvoiceLineRow> _pendingRowDisposal = [];
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

  // currency_id -> rate_decimal_places (rim_currencies), loaded once in
  // _init() — the formatted Rate field needs this per the invoice's own
  // currency (a USD unit price may need 4-5dp, CDF only 2).
  Map<String, int> _currencyDecimalPlaces = {};
  int get _rateDecimalPlaces => _currencyDecimalPlaces[_invoiceCurrencyCode] ?? 2;

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
    for (final l in _pendingRowDisposal) {
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

  // _users is loaded once in _init() (getUsersForAutocomplete, id+full_name)
  // — reused here rather than a fresh query, same as every other
  // UUID->name resolution already done on this screen (sales person, etc.).
  String? _resolveUserName(String? userId) {
    if (userId == null) return null;
    final match = _users.firstWhere((u) => u['id'] == userId, orElse: () => const {});
    return match['full_name'] as String?;
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
        ref.read(currenciesProvider.future),
      ]);
      final controls = results[0] as Map<String, dynamic>?;
      _taxGroups = results[1] as List<Map<String, dynamic>>;
      _users = results[2] as List<Map<String, dynamic>>;
      _additionalCharges = results[3] as List<Map<String, dynamic>>;
      _currencyDecimalPlaces = {
        for (final c in results[4] as List<Map<String, dynamic>>)
          c['currency_id'] as String: (c['rate_decimal_places'] as num?)?.toInt() ?? 2,
      };
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
    // Cash sale invoice currency is always the location's local currency,
    // regardless of whatever ledger currency the cash-customer account
    // itself happens to be configured with — user-specified: a cash
    // drawer only ever holds local-currency notes.
    if (_customerId != null) await _resolveCurrencyForCustomer(ds, _customerId!, forceLocalCurrency: true);
  }

  Future<void> _resolveCurrencyForCustomer(dynamic ds, String customerId, {bool forceLocalCurrency = false}) async {
    final session = ref.read(sessionProvider)!;
    final baseCcy = await ref.read(baseCurrencyProvider.future);
    final localCcy = await ref.read(localCurrencyProvider.future);
    _baseCurrency = baseCcy;
    _localCurrency = localCcy;
    String ccyCode;
    if (forceLocalCurrency) {
      ccyCode = localCcy;
    } else {
      final details = await ds.getCustomerDetails(customerId: customerId);
      final currency = details?['rim_currencies'] as Map<String, dynamic>?;
      ccyCode = currency?['currency_id'] as String? ?? baseCcy;
    }
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
    // _resolveCurrencyForCustomer (the Direct-mode customer-picker path)
    // is the only other place these get set — never called on this
    // reopen-an-existing-invoice path, so without this they stay at their
    // '' default and the Rate to Base/Local field labels render as the
    // empty "Rate to Base ()" a real screenshot caught.
    _baseCurrency = await ref.read(baseCurrencyProvider.future);
    _localCurrency = await ref.read(localCurrencyProvider.future);
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
    _preparedByName = _resolveUserName(header['created_by'] as String?);
    _authorisedByName = _resolveUserName(header['approved_by'] as String?);
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
    _salesVoucherNo = header['sales_voucher_no'] as String?;
    _salesVoucherDate = header['sales_voucher_date'] as String?;
    _cosVoucherNo = header['cos_voucher_no'] as String?;
    _cosVoucherDate = header['cos_voucher_date'] as String?;
    _localReceiptVoucherNo = header['local_receipt_voucher_no'] as String?;
    _localReceiptVoucherDate = header['local_receipt_voucher_date'] as String?;
    _baseReceiptVoucherNo = header['base_receipt_voucher_no'] as String?;
    _baseReceiptVoucherDate = header['base_receipt_voucher_date'] as String?;

    final lines = await ds.getLines(clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _fmtDate(_invoiceDate));
    _pendingRowDisposal.addAll(_lines);
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
    if (_status == 'APPROVED') unawaited(_loadPostedVoucherLines(ds, session));
  }

  Future<void> _loadPostedVoucherLines(SalesInvoiceRepository ds, UserSession session) async {
    final vouchers = <String, (String, String)>{
      if (_salesVoucherNo != null && _salesVoucherDate != null) 'Sales Voucher': (_salesVoucherNo!, _salesVoucherDate!),
      if (_cosVoucherNo != null && _cosVoucherDate != null) 'Cost of Sales': (_cosVoucherNo!, _cosVoucherDate!),
      if (_localReceiptVoucherNo != null && _localReceiptVoucherDate != null) 'Cash Receipt — Local': (_localReceiptVoucherNo!, _localReceiptVoucherDate!),
      if (_baseReceiptVoucherNo != null && _baseReceiptVoucherDate != null) 'Cash Receipt — Base': (_baseReceiptVoucherNo!, _baseReceiptVoucherDate!),
    };
    if (vouchers.isEmpty) return;
    setState(() => _loadingVoucherLines = true);
    try {
      final results = await Future.wait(vouchers.entries.map((e) async {
        final (voucherNo, voucherDate) = e.value;
        final lines = await ds.getPostedVoucherLines(
          clientId: session.clientId, companyId: session.companyId, voucherNo: voucherNo, voucherDate: voucherDate,
        );
        return MapEntry(e.key, lines);
      }));
      if (mounted) setState(() {
        _voucherLines..clear()..addEntries(results);
        _voucherNumbersByLabel..clear()..addEntries(vouchers.entries.map((e) => MapEntry(e.key, e.value.$1)));
        _loadingVoucherLines = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loadingVoucherLines = false);
    }
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

  // ds/session MUST be statically typed here, never `dynamic` — the line
  // list this method assigns into _lines (List<_InvoiceLineRow>) is built
  // via `lines.map(_lineRowFromMap).toList()`; if the receiver is dynamic,
  // that call becomes fully dynamic dispatch, generic-type inference is
  // lost, and `.toList()` produces a runtime List<dynamic> that fails the
  // implicit downcast into _lines with exactly the crash this fixes:
  // "type 'List<dynamic>' is not a subtype of type 'List<_InvoiceLineRow>'".
  Future<void> _loadFromQuotation(String quotationNo, String quotationDate, SalesInvoiceRepository ds, UserSession session) async {
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

  // See _loadFromQuotation's comment — same fix, same reason.
  Future<void> _loadFromOrder(String orderNo, String orderDate, SalesInvoiceRepository ds, UserSession session) async {
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

  // ── Live mode switching (inline Direct/Against Quotation/Against Order
  // selector on this screen itself) ───────────────────────────────────────
  // Replaces the old list-screen upfront picker dialog — "New Invoice"
  // now opens straight into this screen in DIRECT mode, and the mode can
  // be changed at any point while the invoice is still new/unsaved.

  Future<Map<String, dynamic>?> _pickQuotation() async {
    final session = ref.read(sessionProvider)!;
    List<Map<String, dynamic>> quotations = [];
    String? loadError;
    try {
      quotations = await ref.read(salesInvoiceRepositoryProvider).getInvoiceableQuotations(
        clientId: session.clientId, companyId: session.companyId,
      );
    } catch (e) {
      loadError = '$e';
    }
    if (!mounted) return null;
    if (loadError != null) {
      _showSnack('Could not load quotations: $loadError', color: AppColors.negative);
      return null;
    }
    if (quotations.isEmpty) {
      _showSnack('No quotation is available to invoice — it may already have an Order or Invoice against it.', color: AppColors.secondary);
      return null;
    }
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Select a Sales Quotation'),
        children: quotations.map((q) {
          final customer = q['customer'] as Map<String, dynamic>?;
          final isProspect = q['customer_type'] == 'PROSPECT';
          final party = isProspect ? (q['party_name'] as String? ?? '') : (customer?['account_name'] as String? ?? '');
          return SimpleDialogOption(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(q),
            child: ListTile(
              title: Text('${q['quotation_no']}'),
              subtitle: Text('$party${isProspect ? ' (Prospect)' : ''} · Grand Total ${q['grand_total']}'),
              trailing: Text('${q['status']}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<Map<String, dynamic>?> _pickOrder() async {
    final session = ref.read(sessionProvider)!;
    List<Map<String, dynamic>> orders = [];
    String? loadError;
    try {
      orders = await ref.read(salesInvoiceRepositoryProvider).getInvoiceableOrders(
        clientId: session.clientId, companyId: session.companyId,
      );
    } catch (e) {
      loadError = '$e';
    }
    if (!mounted) return null;
    if (loadError != null) {
      _showSnack('Could not load orders: $loadError', color: AppColors.negative);
      return null;
    }
    if (orders.isEmpty) {
      _showSnack('No approved Sales Order is available to invoice.', color: AppColors.secondary);
      return null;
    }
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Select a Sales Order'),
        children: orders.map((o) {
          final customer = o['customer'] as Map<String, dynamic>?;
          return SimpleDialogOption(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(o),
            child: ListTile(
              title: Text('${o['order_no']}'),
              subtitle: Text('${customer?['account_name'] ?? ''} · Grand Total ${o['grand_total']}'),
              trailing: Text('${o['status']}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// True whenever the invoice has real entered content that switching
  /// modes would silently discard — gates the confirm dialog below.
  bool get _hasUnsavedWork => _lines.any((l) => l.productId != null) || _remarksCtrl.text.trim().isNotEmpty;

  Future<bool> _confirmDiscardIfDirty() async {
    if (!_hasUnsavedWork) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Switch Invoice Source?'),
        content: const Text('Switching Direct/Against Quotation/Against Order discards the products and details already entered on this invoice. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Switch & Discard')),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _onModeSegmentChanged(String newMode) async {
    if (newMode == _invoiceMode) return;
    if (!await _confirmDiscardIfDirty() || !mounted) return;

    if (newMode == 'DIRECT') {
      await _resetToDirect();
    } else if (newMode == 'AGAINST_QUOTATION') {
      final picked = await _pickQuotation();
      if (picked == null || !mounted) return;
      await _switchToQuotation(picked);
    } else {
      final picked = await _pickOrder();
      if (picked == null || !mounted) return;
      await _switchToOrder(picked);
    }
  }

  /// "Change" link shown next to the already-picked quotation/order number
  /// — reopens the same picker without going through Direct first (the
  /// SegmentedButton's own onSelectionChanged only fires on a value
  /// change, so re-picking a different doc in the SAME mode needs its own
  /// entry point).
  Future<void> _reselectSource() async {
    if (!await _confirmDiscardIfDirty() || !mounted) return;
    if (_invoiceMode == 'AGAINST_QUOTATION') {
      final picked = await _pickQuotation();
      if (picked == null || !mounted) return;
      await _switchToQuotation(picked);
    } else {
      final picked = await _pickOrder();
      if (picked == null || !mounted) return;
      await _switchToOrder(picked);
    }
  }

  Future<void> _resetToDirect() async {
    setState(() => _loading = true);
    _pendingRowDisposal.addAll(_lines);
    _lines = [];
    for (final c in _charges) { c.dispose(); }
    _charges.clear();
    _invoiceMode = 'DIRECT';
    _sourceQuotationNo = null; _sourceQuotationDate = null;
    _sourceOrderNo = null; _sourceOrderDate = null;
    _saleType = 'CASH';
    _customerId = null; _customerDisplay = '';
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final session = ref.read(sessionProvider)!;
    _locationId = _quickSetup?['location_id'] as String? ?? session.locationId;
    _locationName = (_quickSetup?['location'] as Map<String, dynamic>?)?['location_name'] as String? ?? '';
    await _applyCashCustomer(ds);
    _addLine();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _switchToQuotation(Map<String, dynamic> picked) async {
    setState(() { _loading = true; _invoiceMode = 'AGAINST_QUOTATION'; });
    _pendingRowDisposal.addAll(_lines);
    _lines = [];
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final session = ref.read(sessionProvider)!;
    _sourceQuotationNo = picked['quotation_no'] as String;
    _sourceQuotationDate = picked['quotation_date'] as String;
    await _loadFromQuotation(_sourceQuotationNo!, _sourceQuotationDate!, ds, session);
  }

  Future<void> _switchToOrder(Map<String, dynamic> picked) async {
    setState(() { _loading = true; _invoiceMode = 'AGAINST_ORDER'; });
    _pendingRowDisposal.addAll(_lines);
    _lines = [];
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final session = ref.read(sessionProvider)!;
    _sourceOrderNo = picked['order_no'] as String;
    _sourceOrderDate = picked['order_date'] as String;
    await _loadFromOrder(_sourceOrderNo!, _sourceOrderDate!, ds, session);
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

  // Also the target of the (+) icon on every line row (not just an
  // "Add Line" button) — keyboard-chained from Disc%'s onFieldSubmitted
  // (see _buildLineTile), so pressing Enter after typing a discount and
  // then Enter/Space again on the now-focused (+) button adds the next
  // line with zero mouse use.
  void _addLine() {
    final row = _InvoiceLineRow();
    final headerDiscount = double.tryParse(_headerDiscountPctCtrl.text) ?? 0;
    if (headerDiscount > 0) row.discountPctCtrl.text = '$headerDiscount';
    setState(() => _lines.add(row));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.productFocusNode.requestFocus();
    });
  }

  // An invoice always needs >=1 line (fn_save_sales_invoice itself rejects
  // an empty DIRECT invoice) — rather than special-case an empty-lines
  // state in the UI, deleting down to zero simply re-seeds one fresh blank
  // line immediately, so there is only ever one line-rendering code path.
  void _removeLine(_InvoiceLineRow row) {
    setState(() {
      _lines.remove(row);
      if (_lines.isEmpty && !_isAgainstSource) _lines.add(_InvoiceLineRow());
    });
    // See _pendingRowDisposal's own doc comment — never dispose a just-
    // removed row synchronously (or even in "the next frame"); defer all
    // the way to this screen's own dispose().
    _pendingRowDisposal.add(row);
  }

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
    // Collect Cash Immediately: a NONZERO but insufficient amount is a
    // partial payment, which this fast-entry POS screen has no mechanism
    // to track as a remaining balance — reject it outright rather than
    // silently under-collecting. Zero (both fields blank/0) stays allowed
    // — that's the documented "leave blank to defer" path, unrelated to
    // this check. Each collected amount is converted back into the
    // invoice's own currency (dividing by the same rate that produces
    // base_amount/local_amount from it) before summing, since local and
    // base collections are two different currencies that can't be added
    // directly, and the invoice's own currency may be neither of them.
    if (_collectCash) {
      final rateToBase = double.tryParse(_rateToBaseCtrl.text) ?? 1;
      final rateToLocal = double.tryParse(_rateToLocalCtrl.text) ?? 1;
      final collectedInInvoiceCcy =
          (rateToBase > 0 ? (collectedBase ?? 0) / rateToBase : 0) +
          (rateToLocal > 0 ? (collectedLocal ?? 0) / rateToLocal : 0);
      const tolerance = 0.01;
      if (collectedInInvoiceCcy > tolerance && collectedInInvoiceCcy < _grandTotal - tolerance) {
        _showSnack(
          'Collected amount ($_invoiceCurrencyCode ${collectedInInvoiceCcy.toStringAsFixed(2)}) is less than the invoice total '
          '($_invoiceCurrencyCode ${_grandTotal.toStringAsFixed(2)}). Partial collection is not accepted — collect the full '
          'amount now or leave both fields blank to defer.',
          color: AppColors.negative,
        );
        return false;
      }
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
      // Not rendered by this document's own default receipt template
      // (deliberate — a POS receipt, not a document routed for signature)
      // but supplied regardless so a company's own custom template can
      // bind signatures.prepared_by/authorised_by via the print designer.
      'signatures': {
        'prepared_by': _preparedByName ?? '',
        'authorised_by': _authorisedByName ?? '',
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
                          _buildHeaderCard(locked, isMobile, isOffline),
                          const SizedBox(height: 16),
                        ]),
                      ),
                    ),
                    if (!isMobile)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                        sliver: SliverToBoxAdapter(
                          // showBarcode column must match _buildLineTile's own per-row
                          // condition exactly (showBarcode && !rowLocked) — showBarcode
                          // already excludes _isAgainstSource (see its own definition
                          // above), so ANDing !locked here reproduces !rowLocked without
                          // re-deriving it, keeping the header's Scan column from
                          // appearing when a locked/approved invoice's rows won't render one.
                          child: _buildLineItemsHeader(showLooseQty, showBarcode && !locked, !locked && !_isAgainstSource),
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(24, 0, 24, isMobile ? 0 : 12),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _buildLineTile(_lines[index], locked, showLooseQty, showBarcode, isMobile),
                          childCount: _lines.length,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                      sliver: SliverToBoxAdapter(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const SizedBox(height: 4),
                          _buildChargesCard(locked, isMobile),
                          const SizedBox(height: 16),
                          if (_collectCash) ...[_buildPaymentCard(locked, isMobile), const SizedBox(height: 16)],
                          _buildTotalsCard(),
                          if (_status == 'APPROVED') ...[
                            const SizedBox(height: 20),
                            _buildPostedVoucherSection(),
                          ],
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

  Widget _buildHeaderCard(bool locked, bool isMobile, bool isOffline) {
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12));
    final fieldTextStyle = SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider));
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_isNew) Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            // Against Quotation/Order need a live "not already invoiced by
            // someone else" server check — offline supports Direct only
            // (same restriction the old list-screen dialog used to
            // enforce before mode selection moved onto this screen). Each
            // hidden-when-offline segment stays present if it's already
            // the CURRENT mode (e.g. connectivity dropped mid-entry after
            // switching to Against Quotation while online) — SegmentedButton
            // asserts every `selected` value has a matching segment, so
            // unconditionally hiding it here would crash instead of just
            // blocking new entry into that mode.
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'DIRECT', label: Text('Direct'), icon: Icon(Icons.point_of_sale_outlined)),
                if (!isOffline || _invoiceMode == 'AGAINST_QUOTATION')
                  const ButtonSegment(value: 'AGAINST_QUOTATION', label: Text('Against Quotation'), icon: Icon(Icons.request_quote_outlined)),
                if (!isOffline || _invoiceMode == 'AGAINST_ORDER')
                  const ButtonSegment(value: 'AGAINST_ORDER', label: Text('Against Order'), icon: Icon(Icons.shopping_cart_checkout_outlined)),
              ],
              selected: {_invoiceMode},
              onSelectionChanged: (s) => _onModeSegmentChanged(s.first),
            ),
            if (_isAgainstSource) ...[
              Chip(label: Text(_sourceQuotationNo ?? _sourceOrderNo ?? '', style: const TextStyle(fontSize: 12))),
              TextButton(onPressed: _reselectSource, child: const Text('Change')),
            ],
            SegmentedButton<String>(
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
          ]),
          const SizedBox(height: 16),
          // Row 1 — identity: Location, Customer, Sales Person. Same shape
          // for Cash and Credit, Direct and Against-Source — user-specified
          // ("practically there should not be any difference in UI/UX of
          // credit sales or cash sales, they should look exactly same").
          // The ONLY thing that differs between modes is whether the
          // Customer slot is editable (Direct+Credit only) — every field,
          // position, and width below is shared code, not two parallel
          // layouts that happen to resemble each other.
          SakalFieldRow(isMobile: isMobile, children: [
            SakalFieldCard.readOnly(label: 'Location', value: _locationName.isEmpty ? '—' : _locationName),
            (_saleType == 'CREDIT' && !_isAgainstSource)
                ? SakalFieldCard(
                    label: 'Customer',
                    required: true,
                    editable: true,
                    child: SakalAutocomplete<Map<String, dynamic>>(
                        initialValue: TextEditingValue(text: _customerDisplay),
                        enabled: !locked,
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
                        decoration: SakalFieldCard.bareDecoration,
                        style: fieldTextStyle,
                      ),
                    )
                : SakalFieldCard.readOnly(label: 'Customer', value: _customerDisplay.isEmpty ? '—' : _customerDisplay),
            SakalFieldCard(
              label: 'Sales Person',
              editable: !locked,
              child: DropdownButtonFormField<String>(
                decoration: SakalFieldCard.bareDecoration,
                isExpanded: true, isDense: true, itemHeight: null,
                style: fieldTextStyle,
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
          ]),
          // Row 2 — Cash-only supplementary walk-in details. Clearly
          // secondary to Row 1's identity fields (which are what make Cash
          // and Credit look the same) — this row simply doesn't exist for
          // Credit.
          if (_saleType == 'CASH') ...[
            const SizedBox(height: 12),
            SakalFieldRow(isMobile: isMobile, children: [
              SakalFieldCard(label: 'Walk-in Customer Name (optional)', editable: !locked,
                  child: TextFormField(controller: _partyNameCtrl, enabled: !locked, decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle)),
              SakalFieldCard(label: 'Mobile (optional)', editable: !locked,
                  child: TextFormField(controller: _partyPhoneCtrl, enabled: !locked, decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle)),
              SakalFieldCard(label: 'Address (optional)', editable: !locked,
                  child: TextFormField(controller: _partyAddressCtrl, enabled: !locked, decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle)),
            ]),
          ],
          const SizedBox(height: 16),
          // Currency, rate, and header discount together on one line.
          // Currency is a disabled field (never a picker — this project's
          // Account Picker convention doesn't apply here, currency is
          // always derived, never chosen), matching Location's own
          // InputDecorator treatment above rather than plain Text. Rate is
          // locked (not just gated on _canOverridePrice) whenever the
          // invoice's currency isn't the cashier's own free choice to
          // begin with: AGAINST_QUOTATION/AGAINST_ORDER inherit the source
          // document's confirmed rate, and a Cash sale is always local
          // currency by construction (see _resolveCurrencyForCustomer's
          // forceLocalCurrency) — neither has a real exchange-rate
          // decision left for a human to make.
          SakalFieldRow(isMobile: isMobile, children: [
            SakalFieldCard.readOnly(label: 'Invoice Date', value: _displayDate(_fmtDate(_invoiceDate))),
            SakalFieldCard.readOnly(label: 'Currency', value: _invoiceCurrencyCode ?? '—'),
            if (_invoiceCurrencyCode != null && _invoiceCurrencyCode != _baseCurrency)
              SakalFieldCard(
                label: 'Rate to Base ($_baseCurrency)',
                editable: !locked && _canOverridePrice && !_isAgainstSource && _saleType != 'CASH',
                child: TextFormField(
                  controller: _rateToBaseCtrl, enabled: !locked && _canOverridePrice && !_isAgainstSource && _saleType != 'CASH',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: SakalFieldCard.bareDecoration,
                  style: fieldTextStyle,
                  onChanged: locked ? null : (_) => setState(() {}),
                ),
              ),
            if (_invoiceCurrencyCode != null && _invoiceCurrencyCode != _localCurrency)
              SakalFieldCard(
                label: 'Rate to Local ($_localCurrency)',
                editable: !locked && _canOverridePrice && !_isAgainstSource && _saleType != 'CASH',
                child: TextFormField(
                  controller: _rateToLocalCtrl, enabled: !locked && _canOverridePrice && !_isAgainstSource && _saleType != 'CASH',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: SakalFieldCard.bareDecoration,
                  style: fieldTextStyle,
                  onChanged: locked ? null : (_) => setState(() {}),
                ),
              ),
            if (!_isAgainstSource)
              SakalFieldCard(
                label: 'Header Discount %',
                editable: !locked,
                child: TextFormField(
                  controller: _headerDiscountPctCtrl, enabled: !locked,
                  keyboardType: TextInputType.number,
                  decoration: SakalFieldCard.bareDecoration,
                  style: fieldTextStyle,
                  onChanged: locked ? null : _applyHeaderDiscount,
                ),
              ),
          ]),
          const SizedBox(height: 12),
          TextFormField(controller: _remarksCtrl, enabled: !locked, decoration: dec.copyWith(labelText: 'Remarks (optional)'), maxLines: 2),
        ]),
      ),
    );
  }

  // Header row for the desktop line-items table — built with the EXACT same
  // SizedBox/Expanded widths as _buildLineTile's own desktop Row below, so
  // the dark SakalTableHeaderBar lines up column-for-column with the data
  // underneath rather than two independently-flexed layouts drifting apart.
  Widget _buildLineItemsHeader(bool showLooseQty, bool showBarcode, bool showActionsColumn) {
    return SakalTableHeaderBar(cells: [
      Expanded(flex: 3, child: SakalTableHeaderBar.label('Product')),
      if (showBarcode) ...[const SizedBox(width: 8), SizedBox(width: 140, child: SakalTableHeaderBar.label('Scan'))],
      const SizedBox(width: 10),
      SizedBox(width: 100, child: SakalTableHeaderBar.label(showLooseQty ? 'Qty Pack' : 'Quantity')),
      if (showLooseQty) ...[const SizedBox(width: 10), SizedBox(width: 100, child: SakalTableHeaderBar.label('Qty Loose'))],
      const SizedBox(width: 10),
      SizedBox(width: 110, child: SakalTableHeaderBar.label('Rate')),
      const SizedBox(width: 10),
      SizedBox(width: 100, child: SakalTableHeaderBar.label('Disc %')),
      const SizedBox(width: 10),
      Expanded(flex: 2, child: SakalTableHeaderBar.label('Tax')),
      const SizedBox(width: 10),
      SizedBox(width: 120, child: SakalTableHeaderBar.label('Amount')),
      if (showActionsColumn) const SizedBox(width: 92),
    ]);
  }

  Widget _buildLineTile(_InvoiceLineRow row, bool locked, bool showLooseQty, bool showBarcode, bool isMobile) {
    final rowLocked = locked || _isAgainstSource;
    final rateEditable = !locked && !_isAgainstSource && (row.priceSource == 'MANUAL_OVERRIDE' || (!row.priceResolved && _canOverridePrice));
    final isCompact = ref.watch(isCompactDensityProvider);
    final fieldTextStyle = SakalFieldCard.valueTextStyle(isCompact);
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';

    final productField = rowLocked
        ? SakalFieldCard.readOnly(label: 'Product', value: row.productDisplay.isEmpty ? '—' : row.productDisplay)
        : SakalFieldCard(
            label: 'Product',
            required: true,
            editable: true,
            child: SakalAutocomplete<Map<String, dynamic>>(
              initialValue: TextEditingValue(text: row.productDisplay),
              focusNode: row.productFocusNode,
              displayStringForOption: (p) => '[${p['product_code']}] ${p['product_name']}',
              optionsBuilder: (v) async {
                final session = ref.read(sessionProvider)!;
                final ds = ref.read(salesInvoiceRepositoryProvider);
                return ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: v.text);
              },
              onSelected: (p) => _onProductSelected(row, p),
              decoration: SakalFieldCard.bareDecoration,
              style: fieldTextStyle,
            ),
          );
    final barcodeField = SakalFieldCard(
      label: 'Scan',
      editable: true,
      child: TextFormField(controller: row.barcodeCtrl, decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle,
          onFieldSubmitted: (v) => _onBarcodeSubmitted(row, v)),
    );
    final qtyPackField = SakalFieldCard(
      label: showLooseQty ? 'Qty Pack' : 'Quantity', required: true, editable: !rowLocked,
      child: TextFormField(controller: row.qtyPackCtrl, enabled: !rowLocked, keyboardType: TextInputType.number,
          decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle, onChanged: (_) => _onLineQtyChanged(row)),
    );
    final qtyLooseField = SakalFieldCard(
      label: 'Qty Loose', editable: !rowLocked,
      child: TextFormField(controller: row.qtyLooseCtrl, enabled: !rowLocked, keyboardType: TextInputType.number,
          decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle, onChanged: (_) => _onLineQtyChanged(row)),
    );
    final rateField = SakalFieldCard(
      label: 'Rate', editable: rateEditable,
      child: SakalFormattedNumberField(
        controller: row.rateCtrl, enabled: rateEditable,
        decimalPlaces: _rateDecimalPlaces, numberFormatStyle: numberFormat,
        decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle,
        onChanged: (_) { row.rateEditedByUser = true; setState(() {}); },
      ),
    );
    final discField = SakalFieldCard(
      label: 'Disc %', editable: !rowLocked,
      child: TextFormField(controller: row.discountPctCtrl, enabled: !rowLocked, keyboardType: TextInputType.number,
          decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle,
          onChanged: (v) => _onDiscountChanged(row, v),
          // Keyboard-only chaining: Enter here jumps to this row's own (+)
          // button — Enter/Space on a focused IconButton activates it via
          // Flutter's standard button-focus semantics, no extra wiring needed.
          onFieldSubmitted: (_) => row.addButtonFocusNode.requestFocus()),
    );
    final taxField = SakalFieldCard.readOnly(label: 'Tax', value: row.taxGroupName ?? '—');
    final amountField = SakalFieldCard.readOnly(label: 'Amount', value: AppNumberFormat.amount(row.finalAmount, numberFormat));

    final showActions = !locked && !_isAgainstSource;
    final overrideVisible = !locked && !_isAgainstSource && !row.priceResolved && _canOverridePrice;
    final overrideReasonVisible = row.priceSource == 'MANUAL_OVERRIDE' && !locked;
    final batchSerialVisible = _dispatchStock && (row.isBatchTracked || row.isSerialTracked);
    final hasExtraBody = overrideVisible || overrideReasonVisible || batchSerialVisible;
    final extraBody = hasExtraBody
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (overrideVisible)
              Padding(padding: const EdgeInsets.only(bottom: 6),
                  child: TextButton(onPressed: () => setState(() => row.priceSource = 'MANUAL_OVERRIDE'), child: const Text('Override Price'))),
            if (overrideReasonVisible)
              Padding(padding: const EdgeInsets.only(bottom: 6),
                  child: TextFormField(controller: row.overrideReasonCtrl, decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, label: _req('Override Reason')))),
            if (batchSerialVisible) _buildBatchSerialSection(row, locked, isMobile),
          ])
        : null;

    if (isMobile) {
      return SakalLineItemCard(
        title: row.productDisplay.isEmpty ? 'New Line' : row.productDisplay,
        trailingHeaderAction: showActions
            ? IconButton(focusNode: row.addButtonFocusNode, icon: const Icon(Icons.add_circle_outline, size: 20, color: Colors.white), onPressed: _addLine, tooltip: 'Add line')
            : null,
        onDelete: showActions ? () => _removeLine(row) : null,
        fields: [
          SizedBox(width: double.infinity, child: productField),
          if (showBarcode && !rowLocked) SizedBox(width: double.infinity, child: barcodeField),
          SizedBox(width: 100, child: qtyPackField),
          if (showLooseQty) SizedBox(width: 100, child: qtyLooseField),
          SizedBox(width: 110, child: rateField),
          SizedBox(width: 100, child: discField),
          SizedBox(width: 150, child: taxField),
          SizedBox(width: 120, child: amountField),
        ],
        body: extraBody,
      );
    }

    // Desktop — a continuous row under _buildLineItemsHeader's dark bar (no
    // per-line bordered card any more), same left-to-right column order/
    // widths as that header so the two stay visually aligned.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: productField),
          if (showBarcode && !rowLocked) ...[const SizedBox(width: 8), SizedBox(width: 140, child: barcodeField)],
          const SizedBox(width: 10),
          SizedBox(width: 100, child: qtyPackField),
          if (showLooseQty) ...[const SizedBox(width: 10), SizedBox(width: 100, child: qtyLooseField)],
          const SizedBox(width: 10),
          SizedBox(width: 110, child: rateField),
          const SizedBox(width: 10),
          SizedBox(width: 100, child: discField),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: taxField),
          const SizedBox(width: 10),
          SizedBox(width: 120, child: amountField),
          if (showActions) ...[
            const SizedBox(width: 4),
            IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeLine(row), tooltip: 'Remove line'),
            IconButton(
              focusNode: row.addButtonFocusNode,
              icon: const Icon(Icons.add_circle_outline, size: 20, color: AppColors.primary),
              onPressed: _addLine,
              tooltip: 'Add line',
            ),
          ],
        ]),
        if (extraBody != null) Padding(padding: const EdgeInsets.only(top: 8), child: extraBody),
      ]),
    );
  }

  Widget _buildBatchSerialSection(_InvoiceLineRow row, bool locked, bool isMobile) {
    if (!row.candidatesLoaded) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator());
    }
    final err = _batchSerialError(row);
    final fieldTextStyle = SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider));

    // A small candidate set stretches to fill the row (SakalFieldRow) same
    // as every other field row on this screen — a Wrap of fixed-width boxes
    // left a large empty gap on the right when there were only 1-2
    // candidates, a real complaint on the confirmed redesign. A LARGER set
    // falls back to Wrap (wrapping to further lines) rather than being
    // squeezed to unreadable widths by an unbounded number of Expanded
    // columns in one Row.
    Widget batchFields() {
      final fields = row.batchCandidates.map((b) => SakalFieldCard(
            label: '${b.batchNo} (avail ${b.availableBalance})${b.expiryDate != null ? ' · exp ${b.expiryDate}' : ''}',
            editable: !locked,
            child: TextFormField(
              controller: b.qtyCtrl, enabled: !locked, keyboardType: TextInputType.number,
              decoration: SakalFieldCard.bareDecoration,
              style: fieldTextStyle,
              onChanged: (_) => setState(() {}),
            ),
          )).toList();
      if (isMobile || fields.length <= 4) {
        return SakalFieldRow(isMobile: isMobile, children: fields);
      }
      return Wrap(spacing: 10, runSpacing: 10, children: fields.map((f) => SizedBox(width: 220, child: f)).toList());
    }

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
          batchFields()
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

  Widget _buildPaymentCard(bool locked, bool isMobile) {
    final fieldTextStyle = SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider));
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
          SakalFieldRow(isMobile: isMobile, children: [
            SakalFieldCard(label: 'Collected — Local Currency', editable: !locked,
                child: TextFormField(controller: _collectedLocalCtrl, enabled: !locked, keyboardType: TextInputType.number,
                    decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle)),
            SakalFieldCard(label: 'Collected — Base Currency', editable: !locked,
                child: TextFormField(controller: _collectedBaseCtrl, enabled: !locked, keyboardType: TextInputType.number,
                    decoration: SakalFieldCard.bareDecoration, style: fieldTextStyle)),
          ]),
        ]),
      ),
    );
  }

  Widget _buildChargesCard(bool locked, bool isMobile) {
    // AGAINST_QUOTATION/AGAINST_ORDER: always read-only — the server
    // copies the source document's own charges verbatim regardless of
    // what's shown here (see _prefillChargesFromSource), so there is
    // nothing to legitimately edit, same rule already governing this
    // module's line items in those two modes.
    final chargesLocked = locked || _isAgainstSource;
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';
    final fieldTextStyle = SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider));
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
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: SakalFieldRow(isMobile: isMobile, spans: const [4, 3, 3, 2], children: [
                    SakalFieldCard(
                      label: 'Charge', editable: !chargesLocked,
                      child: DropdownButtonFormField<String>(
                        decoration: SakalFieldCard.bareDecoration,
                        isExpanded: true, isDense: true, itemHeight: null,
                        style: fieldTextStyle,
                        initialValue: row.chargeId,
                        items: _additionalCharges.map((c) => DropdownMenuItem(value: c['id'] as String,
                            child: Text(c['charge_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                        onChanged: chargesLocked ? null : (v) {
                          final c = _additionalCharges.firstWhere((e) => e['id'] == v);
                          _onChargeSelected(row, c);
                        },
                      ),
                    ),
                    SakalFieldCard(
                      label: row.amountOrPercent == 'PERCENT' ? 'Percent' : 'Amount', editable: !chargesLocked,
                      child: TextFormField(
                        controller: row.valueCtrl, enabled: !chargesLocked,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: SakalFieldCard.bareDecoration,
                        style: fieldTextStyle,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SakalFieldCard.readOnly(label: row.nature, value: AppNumberFormat.amount(row.amount, numberFormat)),
                    if (row.isTaxable) SakalFieldCard.readOnly(label: 'Tax', value: AppNumberFormat.amount(row.taxAmount, numberFormat)),
                  ]),
                ),
                if (!chargesLocked) Padding(
                  padding: const EdgeInsets.only(left: 8, top: 4),
                  child: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                    onPressed: () => _removeCharge(row),
                  ),
                ),
              ]),
            )),
        ]),
      ),
    );
  }

  // High-contrast financial summary — solid active-theme-preset background,
  // white typography throughout. Reactive to the live theme preset (unlike
  // most of this screen's still-fixed AppColors.X styling — see this
  // session's report for the exact scope of what is/isn't theme-reactive
  // yet), since a solid-color card is the one place a preset swap is most
  // visually obvious.
  Widget _buildTotalsCard() {
    return SakalFinancialSummaryCard(
      currencyCode: _invoiceCurrencyCode ?? '',
      total: _grandTotal,
      rows: [
        SakalSummaryRow(label: 'Subtotal', value: _grossTotal),
        SakalSummaryRow(label: 'Discount', value: -_discountTotal, isNegative: true),
        SakalSummaryRow(label: 'Tax', value: _taxTotal + _chargeTaxTotal),
        SakalSummaryRow(label: 'Charges', value: _chargesTotal),
      ],
    );
  }

  // ── Posted journal entries (read-only, APPROVED invoices only) ─────────
  // Same purpose as GRN's/Purchase Invoice's own "Posted Journal Entries"
  // section — Sales Invoice never got one, which is what made a correctly-
  // posted invoice look like nothing had happened: Save auto-approves (no
  // separate Approve button on this screen), and the app's central Finance
  // Voucher List screen deliberately excludes auto-posted vouchers
  // (posting_source='AUTO') by design, so this was the only place left
  // that could ever show the SLS/COS/CRV vouchers fn_approve_sales_invoice
  // actually creates.
  Widget _buildPostedVoucherSection() {
    if (_voucherLines.isEmpty && !_loadingVoucherLines) return const SizedBox.shrink();
    final numberFormat = ref.watch(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';

    Widget cell(String text, {TextAlign align = TextAlign.left, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(text, textAlign: align, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
    );

    Widget voucherCard(String label, String voucherNo, List<Map<String, dynamic>> lines) {
      double totalDebit = 0, totalCredit = 0;
      for (final l in lines) {
        final amount = (l['trans_amount'] as num? ?? 0).toDouble();
        if (l['trans_nature'] == 'DR') { totalDebit += amount; } else { totalCredit += amount; }
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(children: [
                Expanded(child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.positive.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                  child: Text(voucherNo, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            SakalTableHeaderBar(cells: [
              const Expanded(flex: 2, child: SizedBox.shrink()),
              Expanded(flex: 5, child: SakalTableHeaderBar.label('Ledger Name')),
              Expanded(flex: 2, child: SakalTableHeaderBar.label('Debit', textAlign: TextAlign.right)),
              Expanded(flex: 2, child: SakalTableHeaderBar.label('Credit', textAlign: TextAlign.right)),
            ]),
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
                  Expanded(flex: 5, child: cell(ledgerName)),
                  Expanded(flex: 2, child: cell(isDr ? AppNumberFormat.amount(amount, numberFormat) : '—', align: TextAlign.right)),
                  Expanded(flex: 2, child: cell(!isDr ? AppNumberFormat.amount(amount, numberFormat) : '—', align: TextAlign.right)),
                ]),
              );
            }),
            Container(
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.06), border: const Border(top: BorderSide(color: AppColors.border))),
              child: Row(children: [
                const Expanded(flex: 7, child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                )),
                Expanded(flex: 2, child: cell(AppNumberFormat.amount(totalDebit, numberFormat), align: TextAlign.right, bold: true)),
                Expanded(flex: 2, child: cell(AppNumberFormat.amount(totalCredit, numberFormat), align: TextAlign.right, bold: true)),
              ]),
            ),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Posted Journal Entries', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      const SizedBox(height: 8),
      if (_loadingVoucherLines)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
      else
        for (final entry in _voucherLines.entries)
          voucherCard(entry.key, _voucherNumbersByLabel[entry.key] ?? '', entry.value),
    ]);
  }
}

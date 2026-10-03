import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_invoice_providers.dart';
import '../../data/pos_auth_remote_ds.dart';
import '../../data/pos_device_storage.dart';
import '../widgets/pos_amount_field.dart';
import '../widgets/pos_numpad.dart';
import '../widgets/pos_pin_pad.dart';
import '../widgets/pos_qty_stepper.dart';
import '../widgets/pos_session_guard.dart';
import 'pos_browse_products_screen.dart';
import 'pos_credit_checkout_screen.dart';

/// POS New Sale — v1. Deliberately built DIRECTLY on the same, already-
/// proven `salesInvoiceRepositoryProvider` Quick Invoice itself uses
/// (fn_save_sales_invoice / fn_approve_sales_invoice, unchanged except for
/// the new, additive `pos_shift_id` column from migration 207) rather than
/// a parallel implementation — a POS sale IS a Sales Invoice row, per
/// docs/pos/00_index.md's central design decision.
///
/// Honest v1 scope cuts (stated here, not hidden — see the
/// docs/pos/ folder for the full design these will grow into):
/// - DIRECT mode only (no Against-Quotation/Order at the till in v1).
/// - Batch/serial-tracked products are blocked with a clear message
///   ("use the back-office Sales Invoice screen for now") rather than
///   half-supported — the mandatory-allocation UI is real work on its own
///   and deserves its own pass, not a rushed afterthought here.
/// - No charges, no schemes/promotions, no loyalty, no bundles yet — all
///   fully designed in docs/pos/02_pricing_promotions_loyalty.md, layered
///   on top of this core loop once it's been tested end to end.
/// - Cash collection still uses Quick Invoice's own proven
///   collected_amount_local/base + auto-CRV mechanism, one currency
///   (the invoice's own), not yet the multi-currency split-tender
///   rid_pos_tender_lines design — that table doesn't exist yet on purpose
///   (see migration 207's own header comment).
/// - Offline is NOT wired yet for this screen (Quick Invoice's own offline
///   path needs `_isAgainstSource`-style branching this screen hasn't
///   built) — a POS sale here requires connectivity for now.
class PosNewSaleScreen extends ConsumerStatefulWidget {
  /// Set only when resuming a held sale from the Hold Sales screen —
  /// identical shape to how SalesInvoiceEntryScreen/CreditSalesInvoiceEntryScreen
  /// already receive an edit target via GoRouter's `extra`.
  final String? editInvoiceNo;
  final String? editInvoiceDate;
  const PosNewSaleScreen({super.key, this.editInvoiceNo, this.editInvoiceDate});

  @override
  ConsumerState<PosNewSaleScreen> createState() => _PosNewSaleScreenState();
}

/// A candidate lot for a BATCH/BATCH_WITH_EXPIRY-tracked line — mirrors
/// Quick Invoice's own `_BatchCandidate` (`sales_invoice_entry_screen.dart`)
/// exactly, just with a plain `double` instead of a `TextEditingController`
/// since POS line fields are PosAmountField-driven, not raw TextFields.
class _PosBatchCandidate {
  final String batchNo;
  final String? expiryDate;
  final double availableBalance;
  double allocatedQty = 0;
  _PosBatchCandidate({required this.batchNo, this.expiryDate, required this.availableBalance});
}

/// A candidate unit for a SERIAL-tracked line — mirrors Quick Invoice's own
/// `_SerialCandidate`.
class _PosSerialCandidate {
  final String serialNo;
  bool selected = false;
  _PosSerialCandidate({required this.serialNo});
}

class _PosLineRow {
  final String productId;
  final String productCode;
  final String productName;
  final String uomId;
  final String uomLabel;
  final double uomConversionFactor;
  final String? taxGroupId;
  double qty;
  double rate;
  double discountPct = 0;
  String? discountGivenBy;
  String trackingType;
  // Null = no floor configured for this product — rim_products.min_selling_price.
  final double? minSellingPrice;

  double baseQty = 0;
  double grossAmount = 0;
  double discountAmount = 0;
  double taxableAmount = 0;
  double taxAmount = 0;
  double finalAmount = 0;

  bool get isBatchTracked => trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY';
  bool get isSerialTracked => trackingType == 'SERIAL';
  List<_PosBatchCandidate> batchCandidates = [];
  List<_PosSerialCandidate> serialCandidates = [];
  bool candidatesLoaded = false;
  double get batchQtySum => batchCandidates.fold(0.0, (s, b) => s + b.allocatedQty);
  int get serialSelectedCount => serialCandidates.where((s) => s.selected).length;

  _PosLineRow({
    required this.productId,
    required this.productCode,
    required this.productName,
    required this.uomId,
    required this.uomLabel,
    required this.uomConversionFactor,
    required this.taxGroupId,
    required this.rate,
    this.qty = 1,
    this.trackingType = 'NONE',
    this.minSellingPrice,
  });
}

class _PosNewSaleScreenState extends ConsumerState<PosNewSaleScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  bool _isSessionError = false;
  String? _actionError;

  Map<String, dynamic>? _shift;
  String _saleType = 'CASH';
  String? _customerId;
  String _customerDisplay = '';
  // Set once a DRAFT has been held/resumed — null means "a brand-new sale,
  // never saved yet" and _charge() takes the INSERT path; non-null means
  // "update this existing DRAFT" (fn_save_sales_invoice's own UPDATE path).
  String? _invoiceNo;
  String? _invoiceDate;
  bool _holding = false;

  final List<_PosLineRow> _lines = [];
  List<Map<String, dynamic>> _taxGroups = [];
  Map<String, double> _taxRatePct = {};
  Map<String, double> _taxGroupRatePct = {};
  Map<String, dynamic>? _quickSetup;
  bool _cashSetupMissing = false;
  bool _canOverridePrice = false;
  bool _canGiveDiscount = false;
  double? _maxDiscountPercent;

  String _baseCcy = '';
  String _localCcy = '';
  String? _invoiceCurrencyId;
  double _rateToBase = 1;
  double _rateToLocal = 1;

  final _searchCtrl = TextEditingController();
  double? _collectedAmount; // null = not overridden, defaults to the full total
  final _searchFocus = FocusNode();
  // Set via the "×N next scan" control below the search bar — applies to the
  // NEXT product added (scan or search), then resets to 1. Standard
  // "quantity then scan" supermarket POS flow, so selling 5 of an item
  // doesn't require scanning it 5 separate times.
  double _pendingQty = 1;

  double get _subtotal => _lines.fold(0, (s, l) => s + l.taxableAmount);
  double get _discountTotal => _lines.fold(0, (s, l) => s + l.discountAmount);
  double get _taxTotal => _lines.fold(0, (s, l) => s + l.taxAmount);
  double get _grandTotal => _lines.fold(0, (s, l) => s + l.finalAmount);

  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  // ── Idle-lock (ric_companies.pos_idle_lock_minutes) ───────────────────────
  int _idleLockMinutes = 0; // 0 = disabled
  DateTime _lastInteraction = DateTime.now();
  bool _locked = false;
  Timer? _idleCheckTimer;

  // ── Weighted-barcode parsing (ric_companies.weighted_barcode_*) ───────────
  String? _weightedPrefixFrom;
  String? _weightedPrefixTo;
  String? _weightedFormat; // 'WEIGHT_EMBEDDED' | 'PRICE_EMBEDDED' | null (disabled)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
    // A plain "Cash Sale" badge told the cashier nothing useful (it's
    // ALWAYS cash sale by default now) — a live clock is actually useful
    // at a till and was asked for directly.
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    // Checked periodically rather than via a single long-lived Timer keyed
    // to the configured minutes — company settings (and therefore the idle
    // threshold) aren't known until _init() resolves, and re-arming a timer
    // every time interaction resets would be needless churn for a window
    // this short either way.
    _idleCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkIdle());
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _idleCheckTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _recordInteraction() {
    _lastInteraction = DateTime.now();
  }

  void _checkIdle() {
    if (_idleLockMinutes <= 0 || _locked || !mounted) return;
    if (DateTime.now().difference(_lastInteraction).inMinutes >= _idleLockMinutes) {
      setState(() => _locked = true);
    }
  }

  /// Re-runs the same PIN login the till already uses — simplest correct
  /// way to verify "is this really an authorized user" without a second,
  /// parallel verify-only backend function. The resulting session/menu
  /// data is discarded; nothing about the cashier's existing session
  /// changes, only the lock overlay comes down.
  Future<void> _unlock(String pin) async {
    final deviceUid = await PosDeviceStorage.deviceUid();
    await PosAuthRemoteDs().pinLogin(deviceUid: deviceUid, pin: pin);
    _recordInteraction();
    if (mounted) setState(() => _locked = false);
  }

  String _formatClock(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}-${two(d.month)}-${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    if (session.posTerminalId == null) {
      setState(() { _loading = false; _error = 'This isn\'t a POS till session. Sign out and sign back in from the POS Login screen.'; _isSessionError = true; });
      return;
    }
    setState(() { _loading = true; _error = null; _isSessionError = false; });
    try {
      final shiftRes = await DioClient.instance.get('/rih_pos_shifts', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'terminal_id': 'eq.${session.posTerminalId}', 'status': 'eq.OPEN', 'is_deleted': 'eq.false',
        'select': 'id,shift_no', 'limit': '1',
      });
      final shifts = List<Map<String, dynamic>>.from(shiftRes.data as List);
      _shift = shifts.isEmpty ? null : shifts.first;

      final companyRes = await DioClient.instance.get('/ric_companies', queryParameters: {
        'id': 'eq.${session.companyId}',
        'select': 'base_currency,local_currency,pos_idle_lock_minutes,'
            'weighted_barcode_prefix_from,weighted_barcode_prefix_to,weighted_barcode_format',
      });
      final company = ((companyRes.data as List).first as Map<String, dynamic>);
      _baseCcy = company['base_currency'] as String? ?? '';
      _localCcy = company['local_currency'] as String? ?? '';
      _idleLockMinutes = (company['pos_idle_lock_minutes'] as num?)?.toInt() ?? 0;
      _weightedPrefixFrom = company['weighted_barcode_prefix_from'] as String?;
      _weightedPrefixTo = company['weighted_barcode_prefix_to'] as String?;
      _weightedFormat = company['weighted_barcode_format'] as String?;

      final ds = ref.read(salesInvoiceRepositoryProvider);
      _quickSetup = await ds.getQuickInvoiceSetup(clientId: session.clientId, companyId: session.companyId, userId: session.userId);
      final controls = await ds.getUserSalesControls(clientId: session.clientId, companyId: session.companyId, userId: session.userId);
      _canOverridePrice = controls?['can_override_price'] as bool? ?? false;
      _canGiveDiscount = controls?['can_give_discount'] as bool? ?? false;
      _maxDiscountPercent = (controls?['max_discount_percent'] as num?)?.toDouble();

      _taxGroups = await ds.getTaxGroups(clientId: session.clientId, companyId: session.companyId);
      final groupIds = _taxGroups.map((g) => g['id'] as String).toList();
      final memberMap = await ds.getTaxGroupMemberTaxIds(groupIds);
      final allTaxIds = memberMap.values.expand((v) => v).toSet().toList();
      _taxRatePct = await ds.getTaxRatesByIds(taxIds: allTaxIds, asOfDate: _fmtDate(DateTime.now()));
      _taxGroupRatePct = {
        for (final e in memberMap.entries) e.key: e.value.fold<double>(0, (s, id) => s + (_taxRatePct[id] ?? 0)),
      };

      if (widget.editInvoiceNo != null) {
        await _loadExisting(session, widget.editInvoiceNo!, widget.editInvoiceDate);
      } else {
        await _applyCashCustomerCurrency(session);
      }

      if (mounted) setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    } catch (e, st) {
      AppLogger.error('PosNewSaleInit', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load the till'); });
    }
  }

  /// Resumes a held (DRAFT) sale — loads header + lines back into the cart
  /// so Charge() takes the UPDATE path instead of creating a second invoice.
  /// Batch/serial allocations on a resumed DRAFT are a known, documented gap
  /// (New Sale never creates a tracked-product line in the first place, so
  /// there is nothing to restore here — consistent with this screen's own
  /// scope cut, not an oversight specific to resume).
  Future<void> _loadExisting(UserSession session, String invoiceNo, String? invoiceDate) async {
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final header = await ds.getHeader(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);
    if (header == null) {
      _error = 'Held sale $invoiceNo was not found.';
      return;
    }
    _invoiceNo = header['invoice_no'] as String;
    _invoiceDate = header['invoice_date'] as String;
    _saleType = header['sale_type'] as String? ?? 'CASH';
    _customerId = header['customer_id'] as String?;
    _invoiceCurrencyId = header['invoice_currency_id'] as String?;
    _rateToBase = (header['rate_to_base'] as num?)?.toDouble() ?? 1;
    _rateToLocal = (header['rate_to_local'] as num?)?.toDouble() ?? 1;

    if (_saleType == 'CASH') {
      final cashCustomer = _quickSetup?['cash_customer'] as Map<String, dynamic>?;
      _customerDisplay = cashCustomer != null ? '[${cashCustomer['account_code']}] ${cashCustomer['account_name']}' : 'Cash Customer';
    } else if (_customerId != null) {
      final acctRes = await DioClient.instance.get('/rim_accounts', queryParameters: {'id': 'eq.$_customerId', 'select': 'account_code,account_name'});
      final rows = acctRes.data as List;
      if (rows.isNotEmpty) {
        final a = rows.first as Map<String, dynamic>;
        _customerDisplay = '[${a['account_code']}] ${a['account_name']}';
      }
    }

    final lines = await ds.getLines(clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!);
    // Resuming a DRAFT with a tracked line previously lost its allocation
    // entirely (candidates reload at zero) — same class of bug this app has
    // hit before (see Sales Invoice's own "Resume-a-DRAFT gap" fix). Fetch
    // both up front, keyed by the line's own saved serial_no.
    final savedBatches = await ds.getLineBatchAllocations(clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!);
    final savedSerials = await ds.getLineSerialAllocations(clientId: session.clientId, companyId: session.companyId, invoiceNo: _invoiceNo!, invoiceDate: _invoiceDate!);
    for (final l in lines) {
      final product = l['product'] as Map<String, dynamic>?;
      final uom = l['uom'] as Map<String, dynamic>?;
      final lineSerial = l['serial_no'] as int;
      final row = _PosLineRow(
        productId: l['product_id'] as String,
        productCode: product?['product_code'] as String? ?? '',
        productName: (l['item_description'] as String?) ?? product?['product_name'] as String? ?? '',
        uomId: l['uom_id'] as String,
        uomLabel: uom?['description'] as String? ?? '',
        uomConversionFactor: (l['uom_conversion_factor'] as num?)?.toDouble() ?? 1,
        taxGroupId: l['tax_group_id'] as String?,
        rate: (l['rate'] as num?)?.toDouble() ?? 0,
        qty: (l['qty_pack'] as num?)?.toDouble() ?? 0,
        trackingType: product?['tracking_type'] as String? ?? 'NONE',
      );
      row.discountPct = (l['discount_percent'] as num?)?.toDouble() ?? 0;
      row.discountGivenBy = l['discount_given_by'] as String?;
      _lines.add(row);

      if (row.isBatchTracked || row.isSerialTracked) {
        await _loadCandidates(row);
        if (row.isBatchTracked) {
          for (final sb in savedBatches.where((sb) => sb['line_serial'] == lineSerial)) {
            final batchNo = sb['batch_no'] as String;
            final allocated = (sb['base_qty'] as num?)?.toDouble() ?? 0;
            final existing = row.batchCandidates.where((b) => b.batchNo == batchNo).toList();
            if (existing.isNotEmpty) {
              existing.first.allocatedQty = allocated;
            } else {
              // The live candidate list no longer has this batch (e.g. it's
              // since been fully consumed elsewhere) — still show what was
              // actually saved, so a resumed DRAFT never silently loses
              // what it already committed to.
              row.batchCandidates.add(_PosBatchCandidate(batchNo: batchNo, expiryDate: sb['expiry_date'] as String?, availableBalance: allocated)..allocatedQty = allocated);
            }
          }
        } else {
          final selectedSerials = savedSerials.where((ss) => ss['line_serial'] == lineSerial).map((ss) => ss['serial_no'] as String).toSet();
          for (final s in row.serialCandidates) {
            if (selectedSerials.contains(s.serialNo)) s.selected = true;
          }
          for (final serialNo in selectedSerials) {
            if (!row.serialCandidates.any((s) => s.serialNo == serialNo)) {
              row.serialCandidates.add(_PosSerialCandidate(serialNo: serialNo)..selected = true);
            }
          }
        }
      }
    }
    _recompute();
  }

  Future<void> _applyCashCustomerCurrency(UserSession session) async {
    // Cash is always forced to local currency — a drawer only holds local
    // notes, same rule as Quick Invoice (sales_invoice_entry_screen.dart).
    if (_saleType == 'CASH') {
      if (_quickSetup == null) { _cashSetupMissing = true; return; }
      _cashSetupMissing = false;
      _customerId = _quickSetup!['cash_customer_id'] as String?;
      final cashCustomer = _quickSetup!['cash_customer'] as Map<String, dynamic>?;
      _customerDisplay = cashCustomer != null ? '[${cashCustomer['account_code']}] ${cashCustomer['account_name']}' : 'Cash Customer';
      await _setInvoiceCurrency(_localCcy, session);
    } else {
      await _setInvoiceCurrency(_localCcy, session);
    }
  }

  Future<void> _setInvoiceCurrency(String currencyCode, UserSession session) async {
    final res = await DioClient.instance.get('/rim_currencies', queryParameters: {
      'company_id': 'eq.${session.companyId}', 'currency_id': 'eq.$currencyCode', 'select': 'id',
    });
    final rows = res.data as List;
    _invoiceCurrencyId = rows.isNotEmpty ? (rows.first as Map<String, dynamic>)['id'] as String : null;

    _rateToBase = currencyCode == _baseCcy ? 1 : await _lookupRate(session, currencyCode, _baseCcy) ?? 1;
    _rateToLocal = currencyCode == _localCcy ? 1 : await _lookupRate(session, currencyCode, _localCcy) ?? 1;
  }

  Future<double?> _lookupRate(UserSession session, String from, String to) async {
    final locationId = session.locationId;
    if (locationId == null || locationId.isEmpty) return null;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    return ds.getExchangeRate(companyId: session.companyId, locationId: locationId, fromCurrency: from, toCurrency: to, rateDate: _fmtDate(DateTime.now()));
  }

  /// Every POS invoice is cash by default; Credit is a deliberate extra
  /// step from the nav rail, only enabled once the cart has at least one
  /// line. Shows the cart's own totals read-only, picks a customer, then
  /// hands straight into this screen's own `_charge()` — no separate
  /// Cash/Credit toggle to forget to switch back.
  Future<void> _startCreditCheckout() async {
    if (_lines.isEmpty) return;
    final customer = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => PosCreditCheckoutScreen(
          subtotal: _subtotal + _discountTotal,
          discount: _discountTotal,
          tax: _taxTotal,
          total: _grandTotal,
          currency: _localCcy,
        ),
      ),
    );
    if (customer == null || !mounted) return;
    setState(() {
      _saleType = 'CREDIT';
      _customerId = customer['id'] as String;
      _customerDisplay = '[${customer['account_code']}] ${customer['account_name']}';
    });
    await _charge();
  }

  /// A separate, category-drill-down screen for MANUAL product discovery —
  /// distinct from Price Check (which stays scan-only). Returns the picked
  /// product map shaped identically to `getProductsForPicker`'s rows, so it
  /// feeds straight into the existing `_addProduct`.
  Future<void> _browseProducts() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => PosBrowseProductsScreen(customerId: _customerId, localCurrency: _localCcy)),
    );
    if (picked != null) await _addProduct(picked);
  }

  /// A flat grid of common products for one-tap add — no scanning, no
  /// typing, no category drilling. One of the original "Phase 1" UX gaps
  /// flagged by the user early in this module's design.
  Future<void> _quickPick() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => PosBrowseProductsScreen(customerId: _customerId, localCurrency: _localCcy, quickPick: true)),
    );
    if (picked != null) await _addProduct(picked);
  }

  /// The common supermarket "in-store weighing scale" convention: a 13-digit
  /// barcode where positions 1-2 are a reserved prefix (configured per
  /// company as a RANGE, e.g. '20'..'29'), 3-7 are the product's own short
  /// code, 8-12 embed either the weight (grams) or the price (cents)
  /// depending on `weighted_barcode_format`, and 13 is a check digit this
  /// app doesn't need to verify (the scale that printed the label already
  /// guarantees it). Returns null for any barcode that isn't in this
  /// company's configured prefix range — i.e. every ordinary product
  /// barcode is completely unaffected.
  ({String itemCode, double? weightKg, double? embeddedPrice})? _parseWeightedBarcode(String code) {
    if (_weightedFormat == null || _weightedPrefixFrom == null || _weightedPrefixTo == null) return null;
    if (code.length != 13 || int.tryParse(code) == null) return null;
    final prefix = code.substring(0, 2);
    if (prefix.compareTo(_weightedPrefixFrom!) < 0 || prefix.compareTo(_weightedPrefixTo!) > 0) return null;
    final itemCode = code.substring(2, 7);
    final embeddedValue = int.parse(code.substring(7, 12));
    return _weightedFormat == 'WEIGHT_EMBEDDED'
        ? (itemCode: itemCode, weightKg: embeddedValue / 1000.0, embeddedPrice: null)
        : (itemCode: itemCode, weightKg: null, embeddedPrice: embeddedValue / 100.0);
  }

  Future<void> _onSearchSubmitted(String value) async {
    final code = value.trim();
    if (code.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    try {
      final weighted = _parseWeightedBarcode(code);
      if (weighted != null) {
        final matches = await ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: weighted.itemCode);
        final product = matches.where((p) => p['product_code'] == weighted.itemCode).toList();
        if (product.isNotEmpty) {
          await _addProduct(product.first, qtyOverride: weighted.weightKg, rateOverride: weighted.embeddedPrice);
          _searchCtrl.clear();
          return;
        }
        // Falls through to the normal lookup below if the embedded item
        // code doesn't match any product — a prefix landing in range is a
        // strong signal, not a guarantee (e.g. a coincidental EAN clash).
      }
      final byBarcode = await ds.getProductByCode(clientId: session.clientId, companyId: session.companyId, code: code, tryPartNumber: true);
      if (byBarcode != null) {
        await _addProduct(byBarcode, uomIdOverride: byBarcode['matched_uom_id'] as String?, uomFactorOverride: (byBarcode['matched_uom_conversion_factor'] as num?)?.toDouble());
        _searchCtrl.clear();
        return;
      }
      final matches = await ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: code);
      if (matches.isEmpty) {
        _showMsg('No product found for "$code".', color: AppColors.negative);
        return;
      }
      if (matches.length == 1) {
        await _addProduct(matches.first);
        _searchCtrl.clear();
        return;
      }
      if (!mounted) return;
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => SimpleDialog(
          title: const Text('Select Product'),
          children: matches.map((p) => SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(p),
                child: Text('${p['product_code']} — ${p['product_name']}'),
              )).toList(),
        ),
      );
      if (picked != null) await _addProduct(picked);
      _searchCtrl.clear();
    } catch (e, st) {
      AppLogger.error('PosNewSaleSearch', e, st);
      _showMsg(ErrorPresenter.format(e, action: 'find this product'), color: AppColors.negative);
    }
  }

  Future<void> _addProduct(Map<String, dynamic> product, {String? uomIdOverride, double? uomFactorOverride, double? qtyOverride, double? rateOverride}) async {
    final trackingType = product['tracking_type'] as String? ?? 'NONE';
    // Age-restricted sale confirmation — rim_products.flags is the existing
    // dynamic, admin-defined flag mechanism (rim_product_flag_types), not a
    // new column; a company that hasn't defined/enabled this flag simply
    // never trips it, so this is inert everywhere it isn't configured.
    final flags = product['flags'] as Map<String, dynamic>?;
    if (flags?['is_age_restricted'] == true) {
      final confirmed = await _confirmAgeRestricted(product['product_name'] as String);
      if (!confirmed) return;
    }
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final uomId = uomIdOverride ?? product['base_uom_id'] as String;
    final uomLabel = (product['uom'] as Map<String, dynamic>?)?['description'] as String? ?? '';

    // A PRICE_EMBEDDED weighted barcode already fixes the rate at the scale
    // itself — never re-resolve a price lookup for it.
    double rate = rateOverride ?? 0;
    final locationId = session.locationId;
    if (rateOverride == null && _customerId != null && _invoiceCurrencyId != null && locationId != null && locationId.isNotEmpty) {
      try {
        final price = await ds.getActivePrice(
          clientId: session.clientId, companyId: session.companyId, locationId: locationId,
          productId: product['id'] as String, uomId: uomId, customerId: _customerId!,
          asOfDate: _fmtDate(DateTime.now()), currencyCode: _localCcy,
        );
        rate = (price?['selling_price'] as num?)?.toDouble() ?? 0;
      } catch (_) {
        // No active price configured — rate starts at 0; a cashier with
        // can_override_price can still type one in, same governance as
        // every other sales screen in this app.
      }
    }

    // No price, no invoice: a cashier without override rights can't add a
    // line at all for an unpriced product — stops a zero-value line from
    // ever reaching a saved invoice in the first place, rather than only
    // catching it later at Charge.
    if (rate <= 0 && !_canOverridePrice) {
      _showMsg('${product['product_name']} has no price configured — ask a supervisor.', color: AppColors.negative);
      return;
    }

    // A WEIGHT_EMBEDDED barcode's own weight IS the quantity — never the
    // "×N next scan" pending multiplier, which has nothing to do with a
    // weighing-scale label.
    final qtyToAdd = qtyOverride ?? _pendingQty;
    _pendingQty = 1;

    // Batch/serial-tracked products never merge into an existing line the
    // way untracked ones do — each scan may draw from a different lot, and
    // merging would make the FEFO re-allocation below ambiguous about which
    // physical units the combined quantity actually represents. A second
    // scan of the same tracked product adds a SEPARATE line instead.
    final isTracked = trackingType == 'BATCH' || trackingType == 'BATCH_WITH_EXPIRY' || trackingType == 'SERIAL';
    if (!isTracked) {
      final existing = _lines.where((l) => l.productId == product['id'] && l.uomId == uomId).toList();
      if (existing.isNotEmpty) {
        existing.first.qty += qtyToAdd;
        _recompute();
        return;
      }
    }

    final row = _PosLineRow(
      productId: product['id'] as String,
      productCode: product['product_code'] as String,
      productName: product['product_name'] as String,
      uomId: uomId,
      uomLabel: uomLabel,
      uomConversionFactor: uomFactorOverride ?? 1,
      taxGroupId: product['sales_tax_group_id'] as String?,
      rate: rate,
      qty: qtyToAdd,
      trackingType: trackingType,
      minSellingPrice: (product['min_selling_price'] as num?)?.toDouble(),
    );
    setState(() {
      _lines.add(row);
      _recompute();
    });
    if (isTracked) {
      await _loadCandidates(row);
      _autoAllocateBatchSerial(row);
    }
  }

  // ── Batch/serial allocation (FEFO) ────────────────────────────────────────
  // Ported from Quick Invoice's own sales_invoice_entry_screen.dart, scoped
  // down to POS's DIRECT/immediate-dispatch-only context (no against-source
  // mode, dispatch is always immediate — both guards that method needs are
  // unconditionally true here, so they're simply omitted).

  Future<void> _loadCandidates(_PosLineRow row) async {
    final session = ref.read(sessionProvider)!;
    final locationId = session.locationId;
    if (locationId == null || locationId.isEmpty) return;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    try {
      if (row.isBatchTracked) {
        final rows = await ds.getBatchStockBalance(clientId: session.clientId, companyId: session.companyId, locationId: locationId, productId: row.productId);
        row.batchCandidates = rows.map((b) => _PosBatchCandidate(
              batchNo: b['batch_no'] as String,
              expiryDate: b['expiry_date'] as String?,
              availableBalance: (b['balance'] as num?)?.toDouble() ?? 0,
            )).toList();
      } else if (row.isSerialTracked) {
        final rows = await ds.getSerialStockStatus(clientId: session.clientId, companyId: session.companyId, locationId: locationId, productId: row.productId);
        row.serialCandidates = rows.map((s) => _PosSerialCandidate(serialNo: s['serial_no'] as String)).toList();
      }
      if (mounted) setState(() => row.candidatesLoaded = true);
    } catch (e, st) {
      AppLogger.error('PosNewSaleLoadCandidates', e, st);
      if (mounted) _showMsg('Could not load batch/serial stock for "${row.productName}".', color: AppColors.negative);
    }
  }

  void _autoAllocateBatchSerial(_PosLineRow row) {
    if (!row.candidatesLoaded) return;
    final needed = row.baseQty;
    if (needed <= 0) return;
    if (row.isBatchTracked) {
      var remaining = needed;
      for (final b in row.batchCandidates) {
        final take = remaining <= 0 ? 0.0 : (b.availableBalance < remaining ? b.availableBalance : remaining);
        b.allocatedQty = take;
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

  /// Same tolerance/shape as Quick Invoice's own `_batchSerialError` — the
  /// batch sum must equal the line's base qty exactly (within rounding),
  /// and the serial count must equal it too.
  String? _batchSerialError(_PosLineRow row) {
    if (row.baseQty <= 0) return null;
    if (row.isBatchTracked) {
      if (row.batchCandidates.isEmpty) return 'No batches currently in stock for "${row.productName}".';
      if ((row.batchQtySum - row.baseQty).abs() > 0.0001) {
        return 'Batch quantities for "${row.productName}" total ${row.batchQtySum.toStringAsFixed(2)} but the line quantity is ${row.baseQty.toStringAsFixed(2)}.';
      }
    } else if (row.isSerialTracked) {
      if (row.serialSelectedCount != row.baseQty.round()) {
        return 'Select exactly ${row.baseQty.round()} serial(s) for "${row.productName}" (${row.serialSelectedCount} selected).';
      }
    }
    return null;
  }

  void _removeLine(_PosLineRow row) {
    setState(() {
      _lines.remove(row);
      _recompute();
    });
  }

  void _recompute() {
    for (final l in _lines) {
      l.baseQty = l.qty * l.uomConversionFactor;
      l.grossAmount = l.baseQty * l.rate;
      l.discountAmount = l.grossAmount * l.discountPct / 100;
      l.taxableAmount = l.grossAmount - l.discountAmount;
      final ratePct = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount = l.taxableAmount * ratePct / 100;
      l.finalAmount = l.taxableAmount + l.taxAmount;
    }
    setState(() {});
  }

  Future<void> _onDiscountChanged(_PosLineRow row, double pct) async {
    final withinCap = _canGiveDiscount && (_maxDiscountPercent == null || pct <= _maxDiscountPercent!);
    final session = ref.read(sessionProvider)!;
    if (pct <= 0) {
      row.discountPct = 0;
      row.discountGivenBy = null;
    } else if (withinCap) {
      row.discountPct = pct;
      row.discountGivenBy = session.userId;
    } else {
      final approverId = await _showDiscountOverrideDialog(pct);
      if (approverId == null) {
        row.discountPct = 0;
      } else {
        row.discountPct = pct;
        row.discountGivenBy = approverId;
      }
    }
    _recompute();
  }

  // PIN-based, not username/password — no password is typed on the till
  // outside Device Setup. fn_verify_pos_discount_override_pin (migration
  // 210) never logs the supervisor in or touches the cashier's own
  // session; it only checks a matching active user's PIN + their own
  // discount eligibility.
  Future<String?> _showDiscountOverrideDialog(double requestedPct) async {
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final pinPadKey = GlobalKey<PosPinPadState>();
    bool verifying = false;
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Supervisor Approval Needed'),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('$requestedPct% exceeds your discount limit. A supervisor must enter their PIN to authorize it.', textAlign: TextAlign.center),
              const SizedBox(height: 14),
              if (error != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(error!, style: const TextStyle(color: AppColors.negative, fontSize: 12), textAlign: TextAlign.center)),
              PosPinPad(
                key: pinPadKey,
                enabled: !verifying,
                onSubmitted: (pin) async {
                  setDialogState(() { verifying = true; error = null; });
                  try {
                    final r = await ds.verifyDiscountOverridePin(
                      clientId: session.clientId, companyId: session.companyId,
                      pin: pin, requestedDiscountPercent: requestedPct,
                    );
                    if (dialogContext.mounted) Navigator.of(dialogContext).pop(r['user_id'] as String);
                  } catch (e) {
                    pinPadKey.currentState?.clear();
                    setDialogState(() { verifying = false; error = ErrorPresenter.format(e, action: 'verify this override'); });
                  }
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          ],
        ),
      ),
    );
    return result;
  }

  void _showMsg(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<bool> _confirmAgeRestricted(String productName) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Age-Restricted Item'),
        content: Text('"$productName" is age-restricted. Confirm you have checked the customer\'s age before selling it.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Confirmed — Add Item')),
        ],
      ),
    );
    return result ?? false;
  }

  /// `rim_products.min_selling_price` — a base-currency floor no
  /// discount/override may cross (seeded since migration 205, never
  /// consumed by any screen until now).
  String? _minPriceError(_PosLineRow row) {
    final floor = row.minSellingPrice;
    if (floor == null) return null;
    final effectiveRate = row.rate * (1 - row.discountPct / 100);
    if (effectiveRate < floor) {
      return '${row.productName}: rate after discount (${effectiveRate.toStringAsFixed(2)}) is below its minimum selling price (${floor.toStringAsFixed(2)}).';
    }
    return null;
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Receipt printing ──────────────────────────────────────────────────────
  // A POS sale is a Sales Invoice row (see this file's own header comment),
  // so it reuses the exact same 'SALES_INVOICE' print template/field
  // registry the back-office Quick Invoice screen already prints with —
  // same document shape, same PrintEngine call, just always fired
  // automatically rather than behind a Print button or a "print now?"
  // confirmation dialog.

  Map<String, dynamic> _buildPrintDocument(Map<String, dynamic> company, String invoiceNo, String invoiceDate) {
    return {
      'company': company,
      'header': {
        'invoice_no': invoiceNo,
        'invoice_date': invoiceDate,
        'provisional': false,
        'sale_type': _saleType,
        'status': 'APPROVED',
        'customer_name': _customerDisplay.contains('] ') ? _customerDisplay.split('] ').last : _customerDisplay,
        'party_phone': '',
        'party_address': '',
        'sales_person_name': '',
        'currency_code': _localCcy,
        'remarks': '',
      },
      'lines': _lines.map((l) => {
        'product_name': l.productName,
        'uom_label': l.uomLabel,
        'base_qty': l.baseQty,
        'rate': l.rate,
        'final_amount': l.finalAmount,
      }).toList(),
      'charges': const [],
      'totals': {
        'gross_amount': _subtotal + _discountTotal,
        'discount_amount': _discountTotal,
        'charges_amount': 0,
        'tax_amount': _taxTotal,
        'grand_total': _grandTotal,
      },
      'signatures': {'prepared_by': '', 'authorised_by': ''},
    };
  }

  Future<void> _printReceipt(String invoiceNo, String invoiceDate) async {
    try {
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      final template = await ref.read(printTemplateProvider('SALES_INVOICE').future);
      final document = _buildPrintDocument(company, invoiceNo, invoiceDate);
      final session = ref.read(sessionProvider);
      if (!mounted) return;
      await PrintEngine.printDocument(
        template: template,
        document: document,
        filename: '$invoiceNo.pdf',
        printedByName: session?.fullName,
        printedOn: DateTime.now(),
        directPrint: true,
      );
    } catch (e, st) {
      // Printing is best-effort — a printer/PDF failure must never block
      // the sale itself, which has already been saved and approved by the
      // time this runs. The cashier sees a clear message and can use the
      // back-office Sales Invoice screen's own Print button to retry.
      AppLogger.error('PosReceiptPrint', e, st);
      if (mounted) _showMsg('Sale saved, but printing the receipt failed: ${ErrorPresenter.format(e, action: 'print this receipt')}', color: AppColors.secondary);
    }
  }

  Future<void> _charge() async {
    if (_lines.isEmpty) {
      _showMsg('Add at least one item.', color: AppColors.negative);
      return;
    }
    final unpriced = _lines.where((l) => l.rate <= 0).toList();
    if (unpriced.isNotEmpty) {
      _showMsg('${unpriced.first.productName} has no price — cannot charge an unpriced item.', color: AppColors.negative);
      return;
    }
    for (final l in _lines) {
      final err = _batchSerialError(l);
      if (err != null) {
        _showMsg(err, color: AppColors.negative);
        return;
      }
      final priceErr = _minPriceError(l);
      if (priceErr != null) {
        _showMsg(priceErr, color: AppColors.negative);
        return;
      }
    }
    if (_customerId == null) {
      // A credit sale's customer is always picked via the dedicated Credit
      // checkout screen BEFORE this is ever called with _saleType=='CREDIT'
      // — reaching this branch means Quick Invoice Setup itself is missing.
      _showMsg('Quick Invoice Setup is missing for this user — ask an admin.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _actionError = null; });
    try {
      final header = _buildHeader(session);
      final lines = _buildLines();
      final (batches, serials) = _buildBatchesAndSerials();
      final ds = ref.read(salesInvoiceRepositoryProvider);
      final invoiceNo = await ds.save(header: header, lines: lines, charges: const [], batches: batches, serials: serials, userId: session.userId);
      final invoiceDate = header['invoice_date'] as String;
      await ds.approve(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate, approvedBy: session.userId);

      if (mounted) {
        _showMsg('$invoiceNo completed.', color: AppColors.positive);
        // Every sale prints a receipt automatically — no "print now?"
        // confirmation like the back-office Quick Invoice screen uses; a
        // till is expected to just print, every time, per direct user
        // instruction ("every save action needs a direct print").
        await _printReceipt(invoiceNo, invoiceDate);
        _resetForNextSale();
      }
    } catch (e, st) {
      AppLogger.error('PosNewSaleCharge', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'complete this sale'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Map<String, dynamic> _buildHeader(UserSession session) {
    return {
      'client_id': session.clientId,
      'company_id': session.companyId,
      'location_id': session.locationId,
      'invoice_no': _invoiceNo,
      'invoice_date': _invoiceDate ?? _fmtDate(DateTime.now()),
      'invoice_mode': 'DIRECT',
      'sale_type': _saleType,
      'customer_id': _customerId,
      'invoice_currency_id': _invoiceCurrencyId,
      'rate_to_base': _rateToBase,
      'rate_to_local': _rateToLocal,
      'discount_percent': 0,
      'gross_amount': _subtotal + _discountTotal,
      'discount_amount': _discountTotal,
      'charges_amount': 0,
      'tax_amount': _taxTotal,
      'grand_total': _grandTotal,
      'collected_amount_local': _saleType == 'CASH' ? (_collectedAmount ?? _grandTotal) : null,
      'collected_amount_base': null,
      'remarks': '',
      'pos_shift_id': _shift?['id'],
    };
  }

  List<Map<String, dynamic>> _buildLines() {
    return _lines.asMap().entries.map((e) => {
            'serial_no': e.key + 1,
            'product_id': e.value.productId,
            'item_description': e.value.productName,
            'barcode': '',
            'uom_id': e.value.uomId,
            'uom_conversion_factor': e.value.uomConversionFactor,
            'qty_pack': e.value.qty,
            'qty_loose': 0,
            'base_qty': e.value.baseQty,
            'rate': e.value.rate,
            'price_override_reason': '',
            'discount_given_by': e.value.discountGivenBy,
            'gross_amount': e.value.grossAmount,
            'discount_percent': e.value.discountPct,
            'discount_amount': e.value.discountAmount,
            'tax_group_id': e.value.taxGroupId,
            'tax_amount': e.value.taxAmount,
            'final_amount': e.value.finalAmount,
            'base_amount': e.value.finalAmount * _rateToBase,
            'local_amount': e.value.finalAmount * _rateToLocal,
            'charge_amount': 0,
            'landed_amount': e.value.finalAmount,
            'remarks': '',
          }).toList();
  }

  /// Keyed to the exact same `_lines` index `_buildLines()` uses for its own
  /// `serial_no` (1-based, no filtering) — `line_serial` on each batch/serial
  /// object must match the line it belongs to.
  (List<Map<String, dynamic>>, List<Map<String, dynamic>>) _buildBatchesAndSerials() {
    final batches = <Map<String, dynamic>>[];
    final serials = <Map<String, dynamic>>[];
    for (final e in _lines.asMap().entries) {
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
    return (batches, serials);
  }

  /// Saves the current cart as a DRAFT (no approve) and resets for the next
  /// customer — "Hold Sale". Resuming it later (via the Hold Sales list,
  /// RouteNames.posSale with editInvoiceNo set) calls Charge() again, which
  /// now takes the UPDATE path since `_invoiceNo` round-trips through
  /// `_buildHeader`.
  Future<void> _hold() async {
    if (_lines.isEmpty) {
      _showMsg('Nothing to hold.', color: AppColors.negative);
      return;
    }
    if (_customerId == null) {
      // Hold is only ever reached in CASH mode (Credit always goes
      // straight to _charge() via its own checkout screen) — a null
      // customer here means Quick Invoice Setup itself is missing.
      _showMsg('Quick Invoice Setup is missing for this user — ask an admin.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() { _holding = true; _actionError = null; });
    try {
      final ds = ref.read(salesInvoiceRepositoryProvider);
      final (batches, serials) = _buildBatchesAndSerials();
      final invoiceNo = await ds.save(header: _buildHeader(session), lines: _buildLines(), charges: const [], batches: batches, serials: serials, userId: session.userId);
      if (mounted) {
        _showMsg('Held as $invoiceNo.', color: AppColors.secondary);
        _resetForNextSale();
      }
    } catch (e, st) {
      AppLogger.error('PosNewSaleHold', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'hold this sale'));
    } finally {
      if (mounted) setState(() => _holding = false);
    }
  }

  void _resetForNextSale() {
    _lines.clear();
    _collectedAmount = null;
    _pendingQty = 1;
    _invoiceNo = null;
    _invoiceDate = null;
    // Every sale is cash by default — without this, a sale right after a
    // Credit checkout would stay stuck in CREDIT mode (wrong customer, no
    // cash customer re-applied) since _saleType is only ever set to
    // CREDIT transiently by _startCreditCheckout.
    _saleType = 'CASH';
    setState(() {});
    final session = ref.read(sessionProvider);
    if (session != null) _applyCashCustomerCurrency(session);
    _searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final bodyContent = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? (_isSessionError
                ? buildPosSessionGuardError(context, _error!, _init)
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.negative)),
                        const SizedBox(height: 14),
                        Wrap(alignment: WrapAlignment.center, spacing: 10, children: [
                          TextButton(onPressed: _init, child: const Text('Retry')),
                          // Resuming a held sale can fail (e.g. a transient
                          // timeout) — this gets back to a fresh New Sale
                          // instead of leaving the only options as "retry
                          // the same failing resume" or "log out".
                          FilledButton(onPressed: () => context.go(RouteNames.posSale), child: const Text('Back to New Sale')),
                        ]),
                      ]),
                    ),
                  ))
            : _shift == null
                ? _buildNoShift()
                : _buildSaleBody(session!);
    return Scaffold(
      backgroundColor: AppColors.background,
      // Any tap/scan anywhere on this screen counts as activity — resets
      // the idle-lock clock. A barcode scanner's own keystrokes land in the
      // focused search field and already go through _onSearchSubmitted,
      // which also counts, but a pure browse/scroll with no field focused
      // needs this to not falsely lock mid-use.
      body: Listener(
        onPointerDown: (_) => _recordInteraction(),
        child: Stack(children: [
          bodyContent,
          if (_locked) _buildIdleLockOverlay(),
        ]),
      ),
    );
  }

  Widget _buildIdleLockOverlay() {
    return _IdleLockOverlay(
      cashierName: ref.read(sessionProvider)?.fullName ?? '',
      onSubmitPin: _unlock,
    );
  }

  Widget _buildNoShift() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_clock_outlined, size: 40, color: AppColors.textSecondary),
        const SizedBox(height: 12),
        const Text('No shift is open on this till.', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        FilledButton(onPressed: () => context.go(RouteNames.posShift), child: const Text('Open Shift')),
      ]),
    );
  }

  Widget _buildSaleBody(UserSession session) {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _buildNavRail(),
      Expanded(child: _buildMainColumn(session)),
    ]);
  }

  /// A narrow, vertical, top-to-bottom nav rail — replaces the earlier
  /// horizontally-scrollable row of action buttons, per direct user
  /// feedback that these belong on the left side, stacked, not scrolled
  /// through along the top.
  Widget _buildNavRail() {
    return Container(
      width: 88,
      color: AppColors.primary,
      child: SafeArea(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          _HeaderActionButton(icon: Icons.bolt_outlined, label: 'Quick Pick', onTap: _quickPick),
          _HeaderActionButton(icon: Icons.grid_view_rounded, label: 'Browse', onTap: _browseProducts),
          _HeaderActionButton(
            icon: Icons.credit_score_outlined, label: 'Credit', enabled: _lines.isNotEmpty,
            onTap: _startCreditCheckout,
          ),
          _HeaderActionButton(icon: Icons.undo, label: 'Return', onTap: () => context.go(RouteNames.posReturn)),
          _HeaderActionButton(icon: Icons.search, label: 'Price Check', onTap: () => context.go(RouteNames.posPriceCheck)),
          _HeaderActionButton(icon: Icons.pause_circle_outline, label: 'Held Sales', onTap: () => context.go(RouteNames.posHold)),
          _HeaderActionButton(icon: Icons.point_of_sale_outlined, label: 'Shift & Cash', onTap: () => context.go(RouteNames.posShift)),
          _HeaderActionButton(icon: Icons.bar_chart_outlined, label: 'Reports', onTap: () => context.go(RouteNames.posReports)),
          _HeaderActionButton(icon: Icons.fact_check_outlined, label: 'Manager Review', onTap: () => context.go(RouteNames.posApprovals)),
        ]),
      ),
    );
  }

  Widget _buildMainColumn(UserSession session) {
    return Column(children: [
      Container(
        color: AppColors.primary,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          const Text('SAKAL POS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(width: 12),
          _Pill(text: session.posTerminalName ?? ''),
          const SizedBox(width: 8),
          _Pill(text: session.fullName),
          const Spacer(),
          if (_saleType == 'CREDIT' && _customerDisplay.isNotEmpty) ...[
            _Pill(text: _customerDisplay),
            const SizedBox(width: 8),
          ],
          // A live clock is actually useful at a till — a static "Cash
          // Sale" badge told the cashier nothing (every sale is cash by
          // default now anyway).
          _Pill(text: _formatClock(_now)),
        ]),
      ),
      if (_cashSetupMissing)
        Container(
          width: double.infinity, color: AppColors.negative.withValues(alpha: 0.1), padding: const EdgeInsets.all(10),
          child: const Text('Quick Invoice Setup is missing for this user — ask an admin to configure it before cash sales can be made.', style: TextStyle(color: AppColors.negative, fontSize: 12.5)),
        ),
      if (_actionError != null)
        Container(
          width: double.infinity, color: AppColors.negative.withValues(alpha: 0.08), padding: const EdgeInsets.all(10),
          child: Text(_actionError!, style: const TextStyle(color: AppColors.negative, fontSize: 12.5)),
        ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          // Set a quantity BEFORE scanning (standard "quantity-then-scan"
          // supermarket POS flow) — selling 5 of an item no longer requires
          // scanning it 5 separate times.
          Material(
            color: _pendingQty != 1 ? AppColors.secondary.withValues(alpha: 0.15) : AppColors.background,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => PosNumpad.show(
                context,
                title: 'Quantity for next scan',
                initialValue: _pendingQty,
                onConfirm: (v) => setState(() => _pendingQty = v <= 0 ? 1 : v),
              ),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
                alignment: Alignment.center,
                child: Text('×${_pendingQty == _pendingQty.roundToDouble() ? _pendingQty.toInt() : _pendingQty}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl, focusNode: _searchFocus, autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Scan barcode or search product…', border: OutlineInputBorder(), isDense: true),
              onSubmitted: _onSearchSubmitted,
            ),
          ),
          const SizedBox(width: 8),
          // The primary flow is scan-first (a barcode scanner needs no
          // on-screen UI at all) — this keyboard icon is the explicit,
          // visible fallback for manual typing. Opens the same full-screen,
          // live-filtered Browse Products screen (not a bare type-then-Done
          // keyboard sheet with no results shown) — a cashier typing "coc"
          // should see every matching product immediately, not just submit
          // a search and hope for one exact hit.
          Material(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _browseProducts,
              child: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
                child: const Icon(Icons.keyboard_outlined, color: AppColors.textSecondary),
              ),
            ),
          ),
        ]),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final cart = _buildCart();
          final totals = _buildTotals();
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: cart),
              SizedBox(width: 340, child: totals),
            ]);
          }
          return Column(children: [Expanded(child: cart), totals]);
        }),
      ),
    ]);
  }

  Widget _buildCart() {
    if (_lines.isEmpty) {
      return const Center(child: Text('Scan or search a product to begin.', style: TextStyle(color: AppColors.textSecondary)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _lines.length,
      itemBuilder: (context, i) {
        final l = _lines[i];
        final trackedVisible = l.isBatchTracked || l.isSerialTracked;
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  flex: 3,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('${l.productCode} · ${l.uomLabel}', style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
                  ]),
                ),
                SizedBox(width: 120, child: PosQtyStepper(value: l.qty, min: 0, buttonSize: 32, onChanged: (v) { l.qty = v; _recompute(); _autoAllocateBatchSerial(l); })),
                const SizedBox(width: 6),
                SizedBox(width: 88, child: PosAmountField(label: 'Rate', value: l.rate, enabled: _canOverridePrice, compact: true, onChanged: (v) { l.rate = v; _recompute(); })),
                const SizedBox(width: 6),
                SizedBox(width: 72, child: PosAmountField(label: 'Disc %', value: l.discountPct, enabled: _canGiveDiscount, compact: true, onChanged: (v) => _onDiscountChanged(l, v))),
                const SizedBox(width: 8),
                SizedBox(width: 72, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(l.finalAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800)))),
                IconButton(onPressed: () => _removeLine(l), icon: const Icon(Icons.close, size: 18, color: AppColors.negative), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
              ]),
              if (trackedVisible) _buildBatchSerialPanel(l),
            ]),
          ),
        );
      },
    );
  }

  /// FEFO auto-fills this on add/qty-change; a cashier can still tap any
  /// batch's amount or a serial chip to adjust it manually, same
  /// "starting point, never a lock" convention as Quick Invoice's own
  /// identical panel.
  Widget _buildBatchSerialPanel(_PosLineRow row) {
    final error = _batchSerialError(row);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Batch/Serial — auto-filled (FEFO), tap to adjust', style: TextStyle(fontSize: 11, color: AppColors.textSecondary))),
          TextButton(
            onPressed: !row.candidatesLoaded ? null : () => _autoAllocateBatchSerial(row),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 28)),
            child: const Text('Reset to FEFO', style: TextStyle(fontSize: 11)),
          ),
        ]),
        if (!row.candidatesLoaded)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
        else if (row.isBatchTracked)
          if (row.batchCandidates.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('No batches currently in stock.', style: TextStyle(fontSize: 11.5, color: AppColors.negative)))
          else
            Wrap(spacing: 8, runSpacing: 8, children: row.batchCandidates.map((b) {
              return SizedBox(
                width: 170,
                child: PosAmountField(
                  label: '${b.batchNo} (avail ${b.availableBalance.toStringAsFixed(0)})${b.expiryDate != null ? ' · exp ${b.expiryDate}' : ''}',
                  value: b.allocatedQty,
                  compact: true,
                  onChanged: (v) => setState(() => b.allocatedQty = v),
                ),
              );
            }).toList())
        else if (row.isSerialTracked)
          if (row.serialCandidates.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('No serials currently in stock.', style: TextStyle(fontSize: 11.5, color: AppColors.negative)))
          else
            Wrap(spacing: 8, runSpacing: 8, children: row.serialCandidates.map((s) => FilterChip(
                  label: Text(s.serialNo, style: const TextStyle(fontSize: 12)),
                  selected: s.selected,
                  onSelected: (v) => setState(() => s.selected = v),
                )).toList()),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error, style: const TextStyle(fontSize: 11, color: AppColors.negative))),
      ]),
    );
  }

  Widget _buildTotals() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppColors.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _totalRow('Subtotal', _subtotal + _discountTotal),
        _totalRow('Discount', -_discountTotal),
        _totalRow('Tax', _taxTotal),
        const Divider(),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          Text('${_grandTotal.toStringAsFixed(2)} $_localCcy', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
        ]),
        if (_saleType == 'CASH') ...[
          const SizedBox(height: 10),
          PosAmountField(
            label: 'Collected',
            value: _collectedAmount ?? _grandTotal,
            suffixText: _localCcy,
            onChanged: (v) => setState(() => _collectedAmount = v),
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _holding ? null : _hold,
            icon: _holding ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.pause_circle_outline, size: 18),
            label: const Text('Hold Sale'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving ? null : _charge,
          style: FilledButton.styleFrom(backgroundColor: AppColors.secondary, minimumSize: const Size.fromHeight(54)),
          child: _saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text('Charge ${_grandTotal.toStringAsFixed(2)} $_localCcy', style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }

  Widget _totalRow(String label, double value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          Text(value.toStringAsFixed(2), style: const TextStyle(fontSize: 13)),
        ]),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill({required this.text});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: const TextStyle(color: Color(0xFFC9D4EE), fontSize: 12)),
      );
}

/// Full-screen idle-lock — cart/session untouched underneath, just a PIN
/// gate on top (ric_companies.pos_idle_lock_minutes). Re-entering the SAME
/// (or any other authorized) user's PIN dismisses it.
class _IdleLockOverlay extends StatefulWidget {
  final String cashierName;
  final Future<void> Function(String pin) onSubmitPin;
  const _IdleLockOverlay({required this.cashierName, required this.onSubmitPin});

  @override
  State<_IdleLockOverlay> createState() => _IdleLockOverlayState();
}

class _IdleLockOverlayState extends State<_IdleLockOverlay> {
  final _pinPadKey = GlobalKey<PosPinPadState>();
  bool _verifying = false;
  String? _error;

  Future<void> _submit(String pin) async {
    setState(() { _verifying = true; _error = null; });
    try {
      await widget.onSubmitPin(pin);
    } catch (e) {
      _pinPadKey.currentState?.clear();
      if (mounted) setState(() => _error = ErrorPresenter.format(e, action: 'unlock this till'));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: AppColors.primary,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_outline, color: Colors.white, size: 36),
                  const SizedBox(height: 10),
                  const Text('Till Locked', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                  const SizedBox(height: 4),
                  Text('Enter your PIN to continue, ${widget.cashierName}.', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFC9D4EE), fontSize: 13)),
                  const SizedBox(height: 18),
                  if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12))),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: PosPinPad(key: _pinPadKey, enabled: !_verifying, onSubmitted: _submit),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single tile in New Sale's vertical left-side nav rail — replaces a bare
/// icon-only `IconButton` (36dp hit target, tooltip-only label) with a
/// ≥64dp finger-sized target that always shows its label.
class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  const _HeaderActionButton({required this.icon, required this.label, required this.onTap, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Material(
        color: Colors.white.withValues(alpha: enabled ? 0.12 : 0.05),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.35), size: 22),
              const SizedBox(height: 4),
              Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.35), fontSize: 10.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    );
  }
}


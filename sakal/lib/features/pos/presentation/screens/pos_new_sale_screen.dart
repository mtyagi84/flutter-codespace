import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_invoice_providers.dart';

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
  const PosNewSaleScreen({super.key});

  @override
  ConsumerState<PosNewSaleScreen> createState() => _PosNewSaleScreenState();
}

class _PosLineRow {
  final String productId;
  final String productCode;
  final String productName;
  final String uomId;
  final String uomLabel;
  final double uomConversionFactor;
  final String? taxGroupId;
  final TextEditingController qtyCtrl = TextEditingController(text: '1');
  final TextEditingController rateCtrl;
  final TextEditingController discountPctCtrl = TextEditingController(text: '0');
  String? discountGivenBy;

  double baseQty = 0;
  double grossAmount = 0;
  double discountAmount = 0;
  double taxableAmount = 0;
  double taxAmount = 0;
  double finalAmount = 0;

  _PosLineRow({
    required this.productId,
    required this.productCode,
    required this.productName,
    required this.uomId,
    required this.uomLabel,
    required this.uomConversionFactor,
    required this.taxGroupId,
    required double rate,
  }) : rateCtrl = TextEditingController(text: _trim(rate));

  static String _trim(double v) {
    var s = v.toStringAsFixed(4);
    s = s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
    return s;
  }

  void dispose() {
    qtyCtrl.dispose();
    rateCtrl.dispose();
    discountPctCtrl.dispose();
  }
}

class _PosNewSaleScreenState extends ConsumerState<PosNewSaleScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _actionError;

  Map<String, dynamic>? _shift;
  String _saleType = 'CASH';
  String? _customerId;
  String _customerDisplay = '';

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
  final _collectedCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  double get _subtotal => _lines.fold(0, (s, l) => s + l.taxableAmount);
  double get _discountTotal => _lines.fold(0, (s, l) => s + l.discountAmount);
  double get _taxTotal => _lines.fold(0, (s, l) => s + l.taxAmount);
  double get _grandTotal => _lines.fold(0, (s, l) => s + l.finalAmount);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _searchCtrl.dispose();
    _collectedCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final shiftRes = await DioClient.instance.get('/rih_pos_shifts', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'terminal_id': 'eq.${session.posTerminalId}', 'status': 'eq.OPEN', 'is_deleted': 'eq.false',
        'select': 'id,shift_no', 'limit': '1',
      });
      final shifts = List<Map<String, dynamic>>.from(shiftRes.data as List);
      _shift = shifts.isEmpty ? null : shifts.first;

      final companyRes = await DioClient.instance.get('/ric_companies', queryParameters: {
        'id': 'eq.${session.companyId}', 'select': 'base_currency,local_currency',
      });
      final company = ((companyRes.data as List).first as Map<String, dynamic>);
      _baseCcy = company['base_currency'] as String? ?? '';
      _localCcy = company['local_currency'] as String? ?? '';

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

      await _applyCashCustomerCurrency(session);

      if (mounted) setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    } catch (e, st) {
      AppLogger.error('PosNewSaleInit', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load the till'); });
    }
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
    final ds = ref.read(salesInvoiceRepositoryProvider);
    return ds.getExchangeRate(companyId: session.companyId, locationId: session.locationId ?? '', fromCurrency: from, toCurrency: to, rateDate: _fmtDate(DateTime.now()));
  }

  void _onSaleTypeChanged(String type) {
    setState(() => _saleType = type);
    final session = ref.read(sessionProvider)!;
    if (type == 'CASH') {
      _applyCashCustomerCurrency(session);
    } else {
      _customerId = null;
      _customerDisplay = '';
    }
  }

  Future<void> _pickCustomer() async {
    final session = ref.read(sessionProvider)!;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CustomerPickerDialog(session: session),
    );
    if (result != null) {
      setState(() {
        _customerId = result['id'] as String;
        _customerDisplay = '[${result['account_code']}] ${result['account_name']}';
      });
    }
  }

  Future<void> _onSearchSubmitted(String value) async {
    final code = value.trim();
    if (code.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    try {
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

  Future<void> _addProduct(Map<String, dynamic> product, {String? uomIdOverride, double? uomFactorOverride}) async {
    final trackingType = product['tracking_type'] as String? ?? 'NONE';
    if (trackingType != 'NONE') {
      _showMsg('${product['product_name']} is batch/serial tracked — not yet supported in POS New Sale. Use the back-office Sales Invoice screen for this item.', color: AppColors.secondary);
      return;
    }
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final uomId = uomIdOverride ?? product['base_uom_id'] as String;
    final uomLabel = (product['uom'] as Map<String, dynamic>?)?['description'] as String? ?? '';

    double rate = 0;
    if (_customerId != null && _invoiceCurrencyId != null) {
      try {
        final price = await ds.getActivePrice(
          clientId: session.clientId, companyId: session.companyId, locationId: session.locationId ?? '',
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

    final existing = _lines.where((l) => l.productId == product['id'] && l.uomId == uomId).toList();
    if (existing.isNotEmpty) {
      final qty = double.tryParse(existing.first.qtyCtrl.text) ?? 0;
      existing.first.qtyCtrl.text = (qty + 1).toString();
      _recompute();
      return;
    }

    setState(() {
      _lines.add(_PosLineRow(
        productId: product['id'] as String,
        productCode: product['product_code'] as String,
        productName: product['product_name'] as String,
        uomId: uomId,
        uomLabel: uomLabel,
        uomConversionFactor: uomFactorOverride ?? 1,
        taxGroupId: product['sales_tax_group_id'] as String?,
        rate: rate,
      ));
      _recompute();
    });
  }

  void _removeLine(_PosLineRow row) {
    setState(() {
      _lines.remove(row);
      row.dispose();
      _recompute();
    });
  }

  void _recompute() {
    for (final l in _lines) {
      final qty = double.tryParse(l.qtyCtrl.text) ?? 0;
      final rate = double.tryParse(l.rateCtrl.text) ?? 0;
      final discountPct = double.tryParse(l.discountPctCtrl.text) ?? 0;
      l.baseQty = qty * l.uomConversionFactor;
      l.grossAmount = l.baseQty * rate;
      l.discountAmount = l.grossAmount * discountPct / 100;
      l.taxableAmount = l.grossAmount - l.discountAmount;
      final ratePct = l.taxGroupId != null ? (_taxGroupRatePct[l.taxGroupId] ?? 0) : 0;
      l.taxAmount = l.taxableAmount * ratePct / 100;
      l.finalAmount = l.taxableAmount + l.taxAmount;
    }
    setState(() {});
  }

  Future<void> _onDiscountChanged(_PosLineRow row, String value) async {
    final pct = double.tryParse(value) ?? 0;
    final withinCap = _canGiveDiscount && (_maxDiscountPercent == null || pct <= _maxDiscountPercent!);
    final session = ref.read(sessionProvider)!;
    if (pct <= 0) {
      row.discountGivenBy = null;
    } else if (withinCap) {
      row.discountGivenBy = session.userId;
    } else {
      final approverId = await _showDiscountOverrideDialog(pct);
      if (approverId == null) {
        row.discountPctCtrl.text = '0';
      } else {
        row.discountGivenBy = approverId;
      }
    }
    _recompute();
  }

  Future<String?> _showDiscountOverrideDialog(double requestedPct) async {
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Supervisor Approval Needed'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$requestedPct% exceeds your discount limit. A supervisor must authorize it.'),
            const SizedBox(height: 12),
            TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'Supervisor Username')),
            TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: AppColors.negative, fontSize: 12))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                try {
                  final r = await ds.verifyDiscountOverride(
                    clientId: session.clientId, companyId: session.companyId,
                    username: userCtrl.text.trim(), password: passCtrl.text, requestedDiscountPercent: requestedPct,
                  );
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop(r['user_id'] as String);
                } catch (e) {
                  setDialogState(() => error = ErrorPresenter.format(e, action: 'verify this override'));
                }
              },
              child: const Text('Authorize'),
            ),
          ],
        ),
      ),
    );
    userCtrl.dispose();
    passCtrl.dispose();
    return result;
  }

  void _showMsg(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _charge() async {
    if (_lines.isEmpty) {
      _showMsg('Add at least one item.', color: AppColors.negative);
      return;
    }
    if (_customerId == null) {
      _showMsg(_saleType == 'CASH' ? 'Quick Invoice Setup is missing for this user — ask an admin.' : 'Pick a customer for this credit sale.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _actionError = null; });
    try {
      final header = {
        'client_id': session.clientId,
        'company_id': session.companyId,
        'location_id': session.locationId,
        'invoice_no': null,
        'invoice_date': _fmtDate(DateTime.now()),
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
        'collected_amount_local': _saleType == 'CASH' ? (double.tryParse(_collectedCtrl.text) ?? _grandTotal) : null,
        'collected_amount_base': null,
        'remarks': '',
        'pos_shift_id': _shift?['id'],
      };
      final lines = _lines.asMap().entries.map((e) => {
            'serial_no': e.key + 1,
            'product_id': e.value.productId,
            'item_description': e.value.productName,
            'barcode': '',
            'uom_id': e.value.uomId,
            'uom_conversion_factor': e.value.uomConversionFactor,
            'qty_pack': double.tryParse(e.value.qtyCtrl.text) ?? 0,
            'qty_loose': 0,
            'base_qty': e.value.baseQty,
            'rate': double.tryParse(e.value.rateCtrl.text) ?? 0,
            'price_override_reason': '',
            'discount_given_by': e.value.discountGivenBy,
            'gross_amount': e.value.grossAmount,
            'discount_percent': double.tryParse(e.value.discountPctCtrl.text) ?? 0,
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

      final ds = ref.read(salesInvoiceRepositoryProvider);
      final invoiceNo = await ds.save(header: header, lines: lines, charges: const [], batches: const [], serials: const [], userId: session.userId);
      await ds.approve(clientId: session.clientId, companyId: session.companyId, invoiceNo: invoiceNo, invoiceDate: _fmtDate(DateTime.now()), approvedBy: session.userId);

      if (mounted) {
        _showMsg('$invoiceNo completed.', color: AppColors.positive);
        _resetForNextSale();
      }
    } catch (e, st) {
      AppLogger.error('PosNewSaleCharge', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'complete this sale'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetForNextSale() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    _collectedCtrl.clear();
    setState(() {});
    _searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: AppColors.negative)),
                  TextButton(onPressed: _init, child: const Text('Retry')),
                ]))
              : _shift == null
                  ? _buildNoShift()
                  : _buildSaleBody(session!),
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
    return Column(children: [
      Container(
        color: AppColors.primary,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          const Text('SAKAL POS — New Sale', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(width: 12),
          _Pill(text: session.posTerminalName ?? ''),
          const SizedBox(width: 8),
          _Pill(text: session.fullName),
          const Spacer(),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'CASH', label: Text('Cash')), ButtonSegment(value: 'CREDIT', label: Text('Credit'))],
            selected: {_saleType},
            onSelectionChanged: (s) => _onSaleTypeChanged(s.first),
          ),
          const SizedBox(width: 8),
          IconButton(onPressed: () => context.go(RouteNames.posShift), icon: const Icon(Icons.point_of_sale_outlined, color: Colors.white), tooltip: 'Shift & Cash'),
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
          Expanded(
            child: TextField(
              controller: _searchCtrl, focusNode: _searchFocus, autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Scan barcode or search product…', border: OutlineInputBorder(), isDense: true),
              onSubmitted: _onSearchSubmitted,
            ),
          ),
          if (_saleType == 'CREDIT') ...[
            const SizedBox(width: 10),
            OutlinedButton.icon(onPressed: _pickCustomer, icon: const Icon(Icons.person_outline, size: 18), label: Text(_customerDisplay.isEmpty ? 'Pick Customer' : _customerDisplay, overflow: TextOverflow.ellipsis)),
          ],
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
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('${l.productCode} · ${l.uomLabel}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                ]),
              ),
              SizedBox(width: 70, child: TextField(controller: l.qtyCtrl, textAlign: TextAlign.center, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(isDense: true, labelText: 'Qty'), onChanged: (_) => _recompute())),
              const SizedBox(width: 8),
              SizedBox(width: 90, child: TextField(controller: l.rateCtrl, textAlign: TextAlign.right, enabled: _canOverridePrice, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Rate'), onChanged: (_) => _recompute())),
              const SizedBox(width: 8),
              SizedBox(width: 70, child: TextField(controller: l.discountPctCtrl, textAlign: TextAlign.right, enabled: _canGiveDiscount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Disc %'), onChanged: (v) => _onDiscountChanged(l, v))),
              const SizedBox(width: 10),
              SizedBox(width: 80, child: Text(l.finalAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800))),
              IconButton(onPressed: () => _removeLine(l), icon: const Icon(Icons.close, size: 18, color: AppColors.negative)),
            ]),
          ),
        );
      },
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
          TextField(
            controller: _collectedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Collected ($_localCcy, blank = full amount)', border: const OutlineInputBorder(), isDense: true),
          ),
        ],
        const SizedBox(height: 14),
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

class _CustomerPickerDialog extends StatefulWidget {
  final UserSession session;
  const _CustomerPickerDialog({required this.session});
  @override
  State<_CustomerPickerDialog> createState() => _CustomerPickerDialogState();
}

class _CustomerPickerDialogState extends State<_CustomerPickerDialog> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;

  Future<void> _search(String q) async {
    setState(() => _loading = true);
    try {
      final res = await DioClient.instance.get('/rim_accounts', queryParameters: {
        'client_id': 'eq.${widget.session.clientId}', 'company_id': 'eq.${widget.session.companyId}',
        'account_nature': 'eq.Customer', 'is_deleted': 'eq.false',
        'or': '(account_code.ilike.*$q*,account_name.ilike.*$q*)',
        'select': 'id,account_code,account_name', 'limit': '20',
      });
      if (mounted) setState(() { _results = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Customer'),
      content: SizedBox(
        width: 360, height: 360,
        child: Column(children: [
          TextField(controller: _ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Search name or code'), onChanged: _search),
          const SizedBox(height: 8),
          if (_loading) const CircularProgressIndicator(strokeWidth: 2),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final c = _results[i];
                return ListTile(
                  title: Text('${c['account_code']} — ${c['account_name']}'),
                  onTap: () => Navigator.of(context).pop(c),
                );
              },
            ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_invoice_providers.dart';
import '../widgets/pos_keyboard.dart';

/// Kiosk-style, read-only: scan or type a barcode/SKU/name, see the price and
/// stock on hand. Deliberately the simplest POS screen — no cart, no
/// customer, nothing that writes anything.
///
/// The on-screen keyboard is an ALWAYS-VISIBLE part of this page — never a
/// popup sheet — per direct user feedback: this screen has nothing else on
/// it, so hiding the one input method behind a tap is pure friction and
/// leaves a cashier wondering why they even had to open it. A barcode
/// scanner still needs no on-screen UI at all (it types+Enters into the
/// focused field like a keyboard-wedge); the inline keyboard is simply
/// always there as well, for the manual case.
class PosPriceCheckScreen extends ConsumerStatefulWidget {
  const PosPriceCheckScreen({super.key});

  @override
  ConsumerState<PosPriceCheckScreen> createState() => _PosPriceCheckScreenState();
}

class _PosPriceCheckScreenState extends ConsumerState<PosPriceCheckScreen> {
  // A REAL, focused TextField — not just a display box — because a
  // hardware barcode scanner emulates a keyboard: it types into whatever
  // field currently has focus and sends Enter. The inline keyboard below
  // simply types into this same controller too, so scanning and manual
  // on-screen typing both land in one place.
  final _searchCtrl = TextEditingController();
  final _focus = FocusNode();
  bool _shift = false;
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _product;
  double? _price;
  double? _stock;
  String _localCcy = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCompany();
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadCompany() async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/ric_companies', queryParameters: {
        'id': 'eq.${session.companyId}', 'select': 'local_currency',
      });
      final rows = res.data as List;
      if (mounted && rows.isNotEmpty) setState(() => _localCcy = (rows.first as Map<String, dynamic>)['local_currency'] as String? ?? '');
    } catch (_) {
      // Price/stock simply won't show a currency suffix if this fails —
      // not fatal, the lookup itself still works.
    }
  }

  Future<void> _search(String value) async {
    final code = value.trim();
    if (code.isEmpty) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    setState(() { _loading = true; _error = null; _product = null; });
    try {
      var product = await ds.getProductByCode(clientId: session.clientId, companyId: session.companyId, code: code, tryPartNumber: true);
      if (product == null) {
        final matches = await ds.getProductsForPicker(clientId: session.clientId, companyId: session.companyId, search: code);
        if (matches.isNotEmpty) product = matches.first;
      }
      if (product == null) {
        setState(() { _loading = false; _error = 'No product found for "$code".'; });
        return;
      }

      final locationId = session.locationId;
      final hasLocation = locationId != null && locationId.isNotEmpty;
      double? price;
      double? stock;
      if (hasLocation) {
        final uomId = product['matched_uom_id'] as String? ?? product['base_uom_id'] as String;
        final priceRes = await ds.getActivePrice(
          clientId: session.clientId, companyId: session.companyId, locationId: locationId,
          productId: product['id'] as String, uomId: uomId, customerId: null,
          asOfDate: _today(), currencyCode: _localCcy,
        );
        final costRes = await ds.getProductLocationCost(clientId: session.clientId, companyId: session.companyId, locationId: locationId, productId: product['id'] as String);
        price = (priceRes?['selling_price'] as num?)?.toDouble();
        stock = (costRes?['current_stock'] as num?)?.toDouble();
      }

      if (!mounted) return;
      setState(() {
        _product = product;
        _price = price;
        _stock = stock;
        // No location on this session at all (not signed in via POS) means
        // price/stock can never be resolved — say so rather than silently
        // showing a blank price as if nothing were configured.
        _error = hasLocation ? null : 'No location on this session — sign in via the POS Login screen for price/stock.';
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.error('PosPriceCheck', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'look up this product'); });
    }
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  void _type(String ch) => setState(() => _searchCtrl.text += _shift ? ch.toUpperCase() : ch);
  void _space() => setState(() => _searchCtrl.text += ' ');
  void _backspace() {
    if (_searchCtrl.text.isEmpty) return;
    setState(() => _searchCtrl.text = _searchCtrl.text.substring(0, _searchCtrl.text.length - 1));
  }
  void _clear() => setState(() => _searchCtrl.clear());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(children: [
              IconButton(onPressed: () => context.go(RouteNames.posSale), icon: const Icon(Icons.arrow_back)),
              const Text('SAKAL POS — Price Check', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.primary, fontSize: 16)),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Scan a barcode, or type a name/code below and look up its price and stock.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
                      child: Row(children: [
                        const Icon(Icons.search, color: AppColors.textSecondary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl, focusNode: _focus, autofocus: true,
                            style: const TextStyle(fontSize: 18),
                            decoration: const InputDecoration(hintText: 'Scan, or type here…', border: InputBorder.none, isDense: true),
                            onSubmitted: _search,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        if (_searchCtrl.text.isNotEmpty) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: _clear),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: FilledButton.icon(
                        onPressed: _loading || _searchCtrl.text.isEmpty ? null : () => _search(_searchCtrl.text),
                        icon: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.search),
                        label: const Text('Look Up'),
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 14), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.negative))),
                    if (_product != null) _buildResultCard(),
                    const SizedBox(height: 18),
                    // Always on the page — a barcode scanner still works with
                    // no interaction here at all; this is for manual entry.
                    PosKeyboardKeys(shift: _shift, onType: _type, onSpace: _space, onBackspace: _backspace, onToggleShift: () => setState(() => _shift = !_shift)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildResultCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(children: [
          Text(_product!['product_name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20), textAlign: TextAlign.center),
          Text('SKU ${_product!['product_code']}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 18),
          Text(
            _price != null ? '${_price!.toStringAsFixed(2)} $_localCcy' : '—',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 40, color: AppColors.primary),
          ),
          if (_price == null) const Text('No active price configured', style: TextStyle(color: AppColors.negative, fontSize: 12)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(12)),
            child: Text(
              _stock != null ? 'Stock on hand: ${_stock!.toStringAsFixed(0)}' : 'Stock: —',
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.positive),
            ),
          ),
        ]),
      ),
    );
  }
}

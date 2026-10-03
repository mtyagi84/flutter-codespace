import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../sales/presentation/providers/sales_invoice_providers.dart';

/// Kiosk-style, read-only: scan or search, see the price and stock on hand.
/// Deliberately the simplest POS screen — no cart, no customer, nothing
/// that writes anything. Reuses the same price/product lookups New Sale
/// already calls (getProductByCode/getProductsForPicker/getActivePrice/
/// getProductLocationCost) — no new backend surface at all.
class PosPriceCheckScreen extends ConsumerStatefulWidget {
  const PosPriceCheckScreen({super.key});

  @override
  ConsumerState<PosPriceCheckScreen> createState() => _PosPriceCheckScreenState();
}

class _PosPriceCheckScreenState extends ConsumerState<PosPriceCheckScreen> {
  final _searchCtrl = TextEditingController();
  final _focus = FocusNode();
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _product;
  double? _price;
  double? _stock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _focus.dispose();
    super.dispose();
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
      double? price;
      double? stock;
      if (locationId != null) {
        final uomId = product['matched_uom_id'] as String? ?? product['base_uom_id'] as String;
        final priceRes = await ds.getActivePrice(
          clientId: session.clientId, companyId: session.companyId, locationId: locationId,
          productId: product['id'] as String, uomId: uomId, customerId: '', asOfDate: _today(), currencyCode: '',
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
        _error = locationId == null ? 'No location on this session — sign in via the POS Login screen for price/stock.' : null;
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
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                      controller: _searchCtrl, focusNode: _focus, autofocus: true, textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 19),
                      decoration: const InputDecoration(hintText: 'Scan or type a barcode / SKU…', border: OutlineInputBorder()),
                      onSubmitted: _search,
                    ),
                    const SizedBox(height: 28),
                    if (_loading) const CircularProgressIndicator(),
                    if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.negative)),
                    if (_product != null) _buildResultCard(),
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
            _price != null ? _price!.toStringAsFixed(2) : '—',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 44, color: AppColors.primary),
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

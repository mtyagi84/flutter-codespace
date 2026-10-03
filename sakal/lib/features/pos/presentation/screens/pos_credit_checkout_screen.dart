import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../widgets/pos_keyboard.dart';

/// Picks the customer for a credit sale — reached ONLY from New Sale's own
/// "Credit" nav button (enabled only once the cart has at least one line,
/// per direct user instruction: "every POS invoice is cash by default,
/// credit is an explicit extra step"). Shows the cart's own totals
/// read-only at the top so the cashier can see what they're about to bill
/// before picking who it's billed to, then returns the picked customer map
/// via `Navigator.pop(context, customer)` — New Sale itself performs the
/// actual charge, reusing its own existing `_charge()` validation/posting
/// rather than duplicating it here.
class PosCreditCheckoutScreen extends ConsumerStatefulWidget {
  final double subtotal;
  final double discount;
  final double tax;
  final double total;
  final String currency;

  const PosCreditCheckoutScreen({
    super.key,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.total,
    required this.currency,
  });

  @override
  ConsumerState<PosCreditCheckoutScreen> createState() => _PosCreditCheckoutScreenState();
}

class _PosCreditCheckoutScreenState extends ConsumerState<PosCreditCheckoutScreen> {
  String _query = '';
  bool _loading = false;
  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _selected;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    setState(() { _query = q; _selected = null; });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    final session = ref.read(sessionProvider)!;
    setState(() => _loading = true);
    try {
      final res = await DioClient.instance.get('/rim_accounts', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'account_nature': 'eq.Customer', 'is_deleted': 'eq.false',
        if (q.isNotEmpty) 'or': '(account_code.ilike.*$q*,account_name.ilike.*$q*)',
        'select': 'id,account_code,account_name', 'order': 'account_name.asc', 'limit': '30',
      });
      if (mounted) setState(() { _results = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _results = []; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Credit Sale — Select Customer'),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _totalRow('Subtotal', widget.subtotal),
            _totalRow('Discount', -widget.discount),
            _totalRow('Tax (VAT)', widget.tax),
            const Divider(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Net Chargeable', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              Text('${widget.total.toStringAsFixed(2)} ${widget.currency}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: PosKeyboardField(label: 'Search customer name or code…', value: _query, onChanged: _onQueryChanged),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _results.isEmpty
                  ? const Center(child: Text('No customers found.', style: TextStyle(color: AppColors.textSecondary)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final c = _results[i];
                        final selected = _selected != null && _selected!['id'] == c['id'];
                        return Card(
                          color: selected ? AppColors.primary.withValues(alpha: 0.08) : Colors.white,
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(selected ? Icons.check_circle : Icons.person_outline, color: selected ? AppColors.primary : AppColors.textSecondary),
                            title: Text('${c['account_code']} — ${c['account_name']}'),
                            onTap: () => setState(() => _selected = c),
                          ),
                        );
                      },
                    ),
        ),
        SafeArea(
          minimum: const EdgeInsets.all(16),
          child: SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _selected == null ? null : () => Navigator.of(context).pop(_selected),
              child: Text(_selected == null ? 'Select a customer' : 'Save Credit Sale to ${_selected!['account_name']}'),
            ),
          ),
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

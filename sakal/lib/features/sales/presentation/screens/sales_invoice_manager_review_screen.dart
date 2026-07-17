import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../providers/sales_invoice_providers.dart';

/// Sales Invoice — Manager Review. Online-only (per docs/screens/sales_invoice.md):
/// lists status=DRAFT invoices for a location — offline-synced Direct-mode
/// sales awaiting posting, and the rare online race-condition failure —
/// shows each line's live stock position as a read-only preview, and posts
/// via the exact same fn_approve_sales_invoice every other path uses. No
/// new stock-check logic here; fn_post_stock_movement's existing negative-
/// stock rules are the real, authoritative check.
class SalesInvoiceManagerReviewScreen extends ConsumerStatefulWidget {
  const SalesInvoiceManagerReviewScreen({super.key});

  @override
  ConsumerState<SalesInvoiceManagerReviewScreen> createState() => _SalesInvoiceManagerReviewScreenState();
}

class _SalesInvoiceManagerReviewScreenState extends ConsumerState<SalesInvoiceManagerReviewScreen>
    with ScreenPermissionMixin<SalesInvoiceManagerReviewScreen> {
  @override
  String get screenName => '/sales/invoice-manager-review';

  String? _locationId;
  List<Map<String, dynamic>> _invoices = [];
  final Map<String, List<Map<String, dynamic>>> _linesByInvoice = {};
  final Map<String, Map<String, num>> _stockByInvoiceProduct = {};
  final Set<String> _posting = {};
  final Map<String, String> _rowErrors = {};
  bool _loading = false;
  String? _error;

  Future<void> _onLocationChanged(String? locationId) async {
    setState(() { _locationId = locationId; _invoices = []; _linesByInvoice.clear(); _stockByInvoiceProduct.clear(); _rowErrors.clear(); });
    if (locationId != null) await _load();
  }

  Future<void> _load() async {
    if (_locationId == null) return;
    final session = ref.read(sessionProvider)!;
    final ds = ref.read(salesInvoiceRepositoryProvider);
    setState(() { _loading = true; _error = null; });
    try {
      final invoices = await ds.listDraftInvoicesForReview(
        clientId: session.clientId, companyId: session.companyId, locationId: _locationId!,
      );
      for (final inv in invoices) {
        final invoiceNo = inv['invoice_no'] as String;
        final lines = await ds.getLines(
          clientId: session.clientId, companyId: session.companyId,
          invoiceNo: invoiceNo, invoiceDate: inv['invoice_date'] as String,
        );
        _linesByInvoice[invoiceNo] = lines;
        for (final l in lines) {
          final productId = l['product_id'] as String;
          final key = '$invoiceNo|$productId';
          final stock = await ds.getStockPreview(
            clientId: session.clientId, companyId: session.companyId,
            locationId: _locationId!, productId: productId,
          );
          _stockByInvoiceProduct[key] = {'current_stock': (stock?['current_stock'] as num?) ?? 0};
        }
      }
      if (mounted) setState(() { _invoices = invoices; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load invoices for review: $e'; });
    }
  }

  Future<void> _postInvoice(Map<String, dynamic> invoice) async {
    final invoiceNo = invoice['invoice_no'] as String;
    final session = ref.read(sessionProvider)!;
    setState(() { _posting.add(invoiceNo); _rowErrors.remove(invoiceNo); });
    try {
      await ref.read(salesInvoiceRepositoryProvider).approve(
        clientId: session.clientId, companyId: session.companyId,
        invoiceNo: invoiceNo, invoiceDate: invoice['invoice_date'] as String, approvedBy: session.userId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$invoiceNo posted.'), backgroundColor: AppColors.positive),
        );
        setState(() { _invoices.removeWhere((i) => i['invoice_no'] == invoiceNo); _posting.remove(invoiceNo); });
      }
    } on DioException catch (e) {
      if (mounted) setState(() { _posting.remove(invoiceNo); _rowErrors[invoiceNo] = e.response?.data?['message'] ?? 'Post failed.'; });
    } catch (e) {
      if (mounted) setState(() { _posting.remove(invoiceNo); _rowErrors[invoiceNo] = 'Unexpected error: $e'; });
    }
  }

  Future<void> _postAllEligible() async {
    for (final inv in List<Map<String, dynamic>>.from(_invoices)) {
      final invoiceNo = inv['invoice_no'] as String;
      if (_posting.contains(invoiceNo)) continue;
      await _postInvoice(inv);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locationsAsync = ref.watch(locationsProvider);
    final isMobile = Responsive.isMobile(context);
    const title = Text('Sales Invoice — Manager Review',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary));
    final postAllButton = (_invoices.isNotEmpty && canApprove)
        ? FilledButton.icon(icon: const Icon(Icons.playlist_add_check, size: 16), label: const Text('Post All Eligible'), onPressed: _postAllEligible)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  title,
                  if (postAllButton != null) ...[const SizedBox(height: 10), postAllButton],
                ])
              : Row(children: [const Expanded(child: title), if (postAllButton != null) postAllButton]),
        ),
        const Divider(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: locationsAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, __) => const Text('Could not load locations.', style: TextStyle(color: AppColors.negative)),
            data: (locations) => SizedBox(
              width: isMobile ? double.infinity : 320,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Location', border: OutlineInputBorder(), isDense: true),
                isExpanded: true, isDense: true, itemHeight: null,
                initialValue: _locationId,
                items: locations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: _onLocationChanged,
              ),
            ),
          ),
        ),
        Expanded(
          child: _locationId == null
              ? const Center(child: Text('Pick a location to review its pending invoices.', style: TextStyle(color: AppColors.textSecondary)))
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.negative)))
                      : _invoices.isEmpty
                          ? const Center(child: Text('No invoices pending review at this location.', style: TextStyle(color: AppColors.textSecondary)))
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                              itemCount: _invoices.length,
                              itemBuilder: (context, i) => _buildInvoiceCard(_invoices[i], isMobile),
                            ),
        ),
      ],
    );
  }

  Widget _buildInvoiceCard(Map<String, dynamic> invoice, bool isMobile) {
    final invoiceNo = invoice['invoice_no'] as String;
    final customer = invoice['customer'] as Map<String, dynamic>?;
    final currency = invoice['currency'] as Map<String, dynamic>?;
    final lines = _linesByInvoice[invoiceNo] ?? [];
    final isPosting = _posting.contains(invoiceNo);
    final rowError = _rowErrors[invoiceNo];

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: ExpansionTile(
        title: isMobile
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$invoiceNo — ${customer?['account_name'] ?? invoice['party_name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                Text('${currency?['currency_id'] ?? ''} ${((invoice['grand_total'] as num?) ?? 0).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
              ])
            : Row(children: [
                Expanded(child: Text('$invoiceNo — ${customer?['account_name'] ?? invoice['party_name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
                Text('${currency?['currency_id'] ?? ''} ${((invoice['grand_total'] as num?) ?? 0).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
              ]),
        subtitle: Text('${invoice['sale_type']} · ${invoice['invoice_mode']} · ${invoice['invoice_date']}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ...lines.map((l) {
                final product = l['product'] as Map<String, dynamic>?;
                final key = '$invoiceNo|${l['product_id']}';
                final currentStock = (_stockByInvoiceProduct[key]?['current_stock'] ?? 0);
                final requested = (l['base_qty'] as num?) ?? 0;
                final insufficient = currentStock < requested;
                final productLabel = Text(product == null ? '—' : '[${product['product_code']}] ${product['product_name']}', style: const TextStyle(fontSize: 13));
                final reqLabel = Text('Req: $requested', style: const TextStyle(fontSize: 12));
                final onHandLabel = Text(
                  'On hand: $currentStock',
                  style: TextStyle(fontSize: 12, color: insufficient ? AppColors.negative : AppColors.textSecondary, fontWeight: insufficient ? FontWeight.w700 : FontWeight.normal),
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: isMobile
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          productLabel,
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [reqLabel, onHandLabel]),
                        ])
                      : Row(children: [
                          Expanded(flex: 3, child: productLabel),
                          Expanded(flex: 1, child: reqLabel),
                          Expanded(flex: 2, child: onHandLabel),
                        ]),
                );
              }),
              if (rowError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(rowError, style: const TextStyle(fontSize: 12, color: AppColors.negative))),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: (!canApprove || isPosting) ? null : () => _postInvoice(invoice),
                  child: isPosting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Post'),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

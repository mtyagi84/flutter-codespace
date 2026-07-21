import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/app_number_format.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_field_card.dart';
import '../providers/sales_invoice_providers.dart';
import '../providers/sales_return_providers.dart';
import '../providers/sales_delivery_providers.dart';

/// One DRAFT document awaiting online approval, tagged by which module it
/// came from. Replaces the old Sales-Invoice-only Manager Review screen —
/// same purpose (offline-synced Direct-mode/Save drafts awaiting posting,
/// plus the rare online race-condition failure), now shared across every
/// module that queues an offline Save but never an offline Approve.
class _ReviewItem {
  final String documentType; // 'SALES_INVOICE' | 'SALES_RETURN' | 'SALES_DELIVERY'
  final Map<String, dynamic> doc;
  final String docNo;
  final String docDate;
  List<Map<String, dynamic>> lines = [];
  _ReviewItem({required this.documentType, required this.doc, required this.docNo, required this.docDate});

  String get key => '$documentType|$docNo';
}

/// Sales — Pending Approvals. Online-only, remote/PostgREST-only (never
/// reads a device's own not-yet-synced local queue — that stays visible
/// only to its own device via each list screen's "Pending sync" badge, a
/// deliberately different concern). Shows each line's live stock position
/// as a read-only preview for outward-moving documents (Invoice, Delivery);
/// Sales Return's own lines are inward and carry no such warning. No new
/// stock-check logic anywhere here — fn_post_stock_movement's existing
/// negative-stock rules are the real, authoritative check at Approve.
class SalesPendingApprovalsScreen extends ConsumerStatefulWidget {
  const SalesPendingApprovalsScreen({super.key});

  @override
  ConsumerState<SalesPendingApprovalsScreen> createState() => _SalesPendingApprovalsScreenState();
}

class _SalesPendingApprovalsScreenState extends ConsumerState<SalesPendingApprovalsScreen>
    with ScreenPermissionMixin<SalesPendingApprovalsScreen> {
  @override
  String get screenName => '/sales/pending-approvals';

  String? _locationId;
  List<_ReviewItem> _items = [];
  final Map<String, num> _stockByKey = {}; // '$documentType|$docNo|$productId' -> current_stock
  final Set<String> _posting = {};
  final Map<String, String> _rowErrors = {};
  bool _loading = false;
  String? _error;

  Future<void> _onLocationChanged(String? locationId) async {
    setState(() { _locationId = locationId; _items = []; _stockByKey.clear(); _rowErrors.clear(); });
    if (locationId != null) await _load();
  }

  Future<void> _load() async {
    if (_locationId == null) return;
    final session = ref.read(sessionProvider)!;
    final invoiceDs  = ref.read(salesInvoiceRepositoryProvider);
    final returnDs   = ref.read(salesReturnRepositoryProvider);
    final deliveryDs = ref.read(salesDeliveryRepositoryProvider);
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        invoiceDs.listDraftInvoicesForReview(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!),
        returnDs.listDraftReturnsForReview(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!),
        deliveryDs.listDraftDeliveriesForReview(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!),
      ]);
      final invoices  = results[0];
      final returns   = results[1];
      final deliveries = results[2];

      final items = <_ReviewItem>[
        ...invoices.map((d) => _ReviewItem(documentType: 'SALES_INVOICE', doc: d, docNo: d['invoice_no'] as String, docDate: d['invoice_date'] as String)),
        ...returns.map((d) => _ReviewItem(documentType: 'SALES_RETURN', doc: d, docNo: d['return_no'] as String, docDate: d['return_date'] as String)),
        ...deliveries.map((d) => _ReviewItem(documentType: 'SALES_DELIVERY', doc: d, docNo: d['delivery_no'] as String, docDate: d['delivery_date'] as String)),
      ]..sort((a, b) => a.docDate.compareTo(b.docDate));

      for (final item in items) {
        switch (item.documentType) {
          case 'SALES_INVOICE':
            item.lines = await invoiceDs.getLines(clientId: session.clientId, companyId: session.companyId, invoiceNo: item.docNo, invoiceDate: item.docDate);
            for (final l in item.lines) {
              final stock = await invoiceDs.getStockPreview(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: l['product_id'] as String);
              _stockByKey['${item.key}|${l['product_id']}'] = (stock?['current_stock'] as num?) ?? 0;
            }
            break;
          case 'SALES_RETURN':
            item.lines = await returnDs.getLines(clientId: session.clientId, companyId: session.companyId, returnNo: item.docNo, returnDate: item.docDate);
            break;
          case 'SALES_DELIVERY':
            item.lines = await deliveryDs.getLines(clientId: session.clientId, companyId: session.companyId, deliveryNo: item.docNo, deliveryDate: item.docDate);
            for (final l in item.lines) {
              final stock = await deliveryDs.getStockPreview(clientId: session.clientId, companyId: session.companyId, locationId: _locationId!, productId: l['product_id'] as String);
              _stockByKey['${item.key}|${l['product_id']}'] = (stock?['current_stock'] as num?) ?? 0;
            }
            break;
        }
      }
      if (mounted) setState(() { _items = items; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load pending approvals: $e'; });
    }
  }

  Future<void> _postItem(_ReviewItem item) async {
    final session = ref.read(sessionProvider)!;
    setState(() { _posting.add(item.key); _rowErrors.remove(item.key); });
    try {
      switch (item.documentType) {
        case 'SALES_INVOICE':
          await ref.read(salesInvoiceRepositoryProvider).approve(
            clientId: session.clientId, companyId: session.companyId,
            invoiceNo: item.docNo, invoiceDate: item.docDate, approvedBy: session.userId,
          );
          break;
        case 'SALES_RETURN':
          await ref.read(salesReturnRepositoryProvider).approve(
            clientId: session.clientId, companyId: session.companyId,
            returnNo: item.docNo, returnDate: item.docDate, approvedBy: session.userId,
          );
          break;
        case 'SALES_DELIVERY':
          await ref.read(salesDeliveryRepositoryProvider).approve(
            clientId: session.clientId, companyId: session.companyId,
            deliveryNo: item.docNo, deliveryDate: item.docDate, approvedBy: session.userId,
          );
          break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${item.docNo} posted.'), backgroundColor: AppColors.positive),
        );
        setState(() { _items.removeWhere((i) => i.key == item.key); _posting.remove(item.key); });
      }
    } on DioException catch (e) {
      if (mounted) setState(() { _posting.remove(item.key); _rowErrors[item.key] = e.response?.data?['message'] ?? 'Post failed.'; });
    } catch (e) {
      if (mounted) setState(() { _posting.remove(item.key); _rowErrors[item.key] = 'Unexpected error: $e'; });
    }
  }

  Future<void> _postAllEligible() async {
    for (final item in List<_ReviewItem>.from(_items)) {
      if (_posting.contains(item.key)) continue;
      await _postItem(item);
    }
  }

  String _typeLabel(String t) => switch (t) {
    'SALES_INVOICE' => 'Sales Invoice',
    'SALES_RETURN' => 'Sales Return',
    'SALES_DELIVERY' => 'Sales Delivery',
    _ => t,
  };

  @override
  Widget build(BuildContext context) {
    final locationsAsync = ref.watch(locationsProvider);
    final isMobile = Responsive.isMobile(context);
    const title = Text('Pending Approvals',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary));
    final postAllButton = (_items.isNotEmpty && canApprove)
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
                  const SizedBox(height: 4),
                  const Text('DRAFT Invoices, Returns, and Deliveries awaiting online approval.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  if (postAllButton != null) ...[const SizedBox(height: 10), postAllButton],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    title,
                    SizedBox(height: 4),
                    Text('DRAFT Invoices, Returns, and Deliveries awaiting online approval.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ])),
                  if (postAllButton != null) postAllButton,
                ]),
        ),
        const Divider(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: locationsAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, __) => const Text('Could not load locations.', style: TextStyle(color: AppColors.negative)),
            data: (locations) => SizedBox(
              width: isMobile ? double.infinity : 320,
              child: SakalFieldCard(
                label: 'Location',
                editable: true,
                child: DropdownButtonFormField<String>(
                  decoration: SakalFieldCard.bareDecoration,
                  isExpanded: true, isDense: true, itemHeight: null,
                  initialValue: _locationId,
                  style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                  items: locations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: _onLocationChanged,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: _locationId == null
              ? const Center(child: Text('Pick a location to review its pending documents.', style: TextStyle(color: AppColors.textSecondary)))
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.negative)))
                      : _items.isEmpty
                          ? const Center(child: Text('No documents pending approval at this location.', style: TextStyle(color: AppColors.textSecondary)))
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                              itemCount: _items.length,
                              itemBuilder: (context, i) => _buildItemCard(_items[i], isMobile),
                            ),
        ),
      ],
    );
  }

  Widget _buildItemCard(_ReviewItem item, bool isMobile) {
    final isPosting = _posting.contains(item.key);
    final rowError = _rowErrors[item.key];
    final numberFormat = ref.read(sessionProvider)?.numberFormat ?? 'INTERNATIONAL';
    final isOutward = item.documentType != 'SALES_RETURN';

    Widget titleText;
    Widget subtitleText;
    switch (item.documentType) {
      case 'SALES_INVOICE':
        final customer = item.doc['customer'] as Map<String, dynamic>?;
        final currency = item.doc['currency'] as Map<String, dynamic>?;
        titleText = Text('${item.docNo} — ${customer?['account_name'] ?? item.doc['party_name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14));
        subtitleText = Text('${_typeLabel(item.documentType)} · ${item.doc['sale_type']} · ${item.doc['invoice_mode']} · ${item.docDate}'
            ' · ${currency?['currency_id'] ?? ''} ${AppNumberFormat.amount((item.doc['grand_total'] as num?) ?? 0, numberFormat)}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary));
        break;
      case 'SALES_RETURN':
        final customer = item.doc['customer'] as Map<String, dynamic>?;
        titleText = Text('${item.docNo} — ${customer?['account_name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14));
        subtitleText = Text('${_typeLabel(item.documentType)} · Against ${item.doc['invoice_no']} · ${item.docDate}'
            ' · Total ${AppNumberFormat.amount((item.doc['return_total'] as num?) ?? 0, numberFormat)}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary));
        break;
      case 'SALES_DELIVERY':
      default:
        final customer = item.doc['customer'] as Map<String, dynamic>?;
        titleText = Text('${item.docNo} — ${customer?['account_name'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14));
        subtitleText = Text('${_typeLabel(item.documentType)} · Against ${item.doc['invoice_no']} · ${item.docDate}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary));
        break;
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: AppColors.border)),
      child: ExpansionTile(
        title: titleText,
        subtitle: subtitleText,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ...item.lines.map((l) {
                final product = l['product'] as Map<String, dynamic>?;
                final productLabel = Text(product == null ? '—' : '[${product['product_code']}] ${product['product_name']}', style: const TextStyle(fontSize: 13));
                final qty = (l['base_qty'] as num?) ?? 0;
                final qtyLabel = Text('Qty: ${AppNumberFormat.amount(qty, numberFormat)}', style: const TextStyle(fontSize: 12), textAlign: TextAlign.right);

                if (!isOutward) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: isMobile
                        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [productLabel, qtyLabel])
                        : Row(children: [Expanded(flex: 3, child: productLabel), Expanded(flex: 1, child: qtyLabel)]),
                  );
                }

                final currentStock = _stockByKey['${item.key}|${l['product_id']}'] ?? 0;
                final insufficient = currentStock < qty;
                final onHandLabel = Text(
                  'On hand: ${AppNumberFormat.amount(currentStock, numberFormat)}',
                  style: TextStyle(fontSize: 12, color: insufficient ? AppColors.negative : AppColors.textSecondary, fontWeight: insufficient ? FontWeight.w700 : FontWeight.normal),
                  textAlign: TextAlign.right,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: isMobile
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          productLabel,
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [qtyLabel, onHandLabel]),
                        ])
                      : Row(children: [
                          Expanded(flex: 3, child: productLabel),
                          Expanded(flex: 1, child: qtyLabel),
                          Expanded(flex: 2, child: onHandLabel),
                        ]),
                );
              }),
              if (rowError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(rowError, style: const TextStyle(fontSize: 12, color: AppColors.negative))),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: (!canApprove || isPosting) ? null : () => _postItem(item),
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/dio_client.dart';
import '../providers/session_provider.dart';
import 'default_templates/sales_quotation_default_template.dart';
import 'default_templates/sales_order_default_template.dart';
import 'default_templates/purchase_order_default_template.dart';
import 'default_templates/grn_default_template.dart';
import 'default_templates/purchase_invoice_default_template.dart';
import 'default_templates/purchase_return_default_template.dart';
import 'default_templates/voucher_default_template.dart';
import 'default_templates/material_requisition_default_template.dart';
import 'default_templates/material_issue_default_template.dart';
import 'default_templates/stock_transfer_request_default_template.dart';
import 'default_templates/stock_transfer_default_template.dart';
import 'default_templates/stock_receipt_default_template.dart';
import 'default_templates/stock_adjustment_default_template.dart';
import 'default_templates/opening_stock_default_template.dart';
import 'default_templates/stock_count_default_template.dart';
import 'default_templates/stock_count_review_default_template.dart';
import 'default_templates/price_master_default_template.dart';
import 'default_templates/sales_invoice_default_template.dart';
import 'default_templates/sales_return_default_template.dart';
import 'default_templates/sales_delivery_default_template.dart';
import 'print_models.dart';

/// Fetches the company's active default template for a document type, or
/// falls back to a hardcoded Dart default — printing always works, even
/// for a brand-new company that has never touched the (not-yet-built)
/// template designer screen, and even if the fetch fails for any reason
/// (offline, RLS, network blip).
final printTemplateProvider = FutureProvider.family<PrintTemplate, String>((ref, documentType) async {
  final session = ref.watch(sessionProvider);
  if (session != null) {
    try {
      final res = await DioClient.instance.get('/ric_print_templates', queryParameters: {
        'client_id':     'eq.${session.clientId}',
        'company_id':    'eq.${session.companyId}',
        'document_type': 'eq.$documentType',
        'is_default':    'eq.true',
        'is_active':     'eq.true',
        'is_deleted':    'eq.false',
        'select':        '*',
        'limit':         '1',
      });
      final list = res.data as List;
      if (list.isNotEmpty) return PrintTemplate.fromJson(list.first as Map<String, dynamic>);
    } catch (_) {
      // Fall through to the hardcoded default on any error.
    }
  }
  return defaultTemplateFor(documentType);
});

/// The hardcoded Dart fallback template for a document type — also used by
/// the designer screen (print_template_designer_screen.dart) as the starting
/// point for a brand-new template, so an admin edits a proven-good layout
/// instead of a blank page.
PrintTemplate defaultTemplateFor(String documentType) => switch (documentType) {
  'SALES_QUOTATION'         => salesQuotationDefaultTemplate,
  'SALES_ORDER'             => salesOrderDefaultTemplate,
  'PURCHASE_ORDER'          => purchaseOrderDefaultTemplate,
  'GRN'                     => grnDefaultTemplate,
  'PURCHASE_INVOICE'        => purchaseInvoiceDefaultTemplate,
  'PURCHASE_RETURN'         => purchaseReturnDefaultTemplate,
  'VOUCHER'                 => voucherDefaultTemplate,
  'MATERIAL_REQUISITION'    => materialRequisitionDefaultTemplate,
  'MATERIAL_ISSUE'          => materialIssueDefaultTemplate,
  'STOCK_TRANSFER_REQUEST'  => stockTransferRequestDefaultTemplate,
  'STOCK_TRANSFER'          => stockTransferDefaultTemplate,
  'STOCK_RECEIPT'           => stockReceiptDefaultTemplate,
  'STOCK_ADJUSTMENT'        => stockAdjustmentDefaultTemplate,
  'OPENING_STOCK'           => openingStockDefaultTemplate,
  'STOCK_COUNT'             => stockCountDefaultTemplate,
  'STOCK_COUNT_REVIEW'      => stockCountReviewDefaultTemplate,
  'PRICE_MASTER'            => priceMasterDefaultTemplate,
  'SALES_INVOICE'           => salesInvoiceDefaultTemplate,
  'SALES_RETURN'            => salesReturnDefaultTemplate,
  'SALES_DELIVERY'          => salesDeliveryDefaultTemplate,
  _ => throw ArgumentError('No default print template registered for document type "$documentType".'),
};

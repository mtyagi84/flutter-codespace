import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tables/pending_sync_queue.dart';
import 'tables/exchange_rate_cache_table.dart';
import 'tables/accounts_cache_table.dart';
import 'tables/finance_voucher_cache_tables.dart';
import 'tables/common_masters_cache_table.dart';
import 'tables/products_cache_table.dart';
import 'tables/purchase_order_cache_tables.dart';
import 'tables/generic_lookup_cache_table.dart';
import 'tables/grn_cache_tables.dart';
import 'tables/material_requisition_cache_tables.dart';
import 'tables/material_issue_cache_tables.dart';
import 'tables/purchase_return_cache_tables.dart';
import 'tables/stock_transfer_request_cache_tables.dart';
import 'tables/stock_transfer_cache_tables.dart';
import 'tables/stock_receipt_cache_tables.dart';
import 'tables/stock_adjustment_cache_tables.dart';
import 'tables/opening_stock_cache_tables.dart';
import 'tables/stock_count_cache_tables.dart';
import 'tables/sales_quotation_cache_tables.dart';
import 'tables/price_master_cache_tables.dart';
import 'tables/sales_order_cache_tables.dart';
import 'tables/sales_invoice_cache_tables.dart';
import 'tables/product_uom_cache_table.dart';
import 'tables/tax_group_members_cache_table.dart';
import 'tables/tax_rates_cache_table.dart';
import 'tables/module_sync_status_cache_table.dart';
import 'tables/sales_return_cache_tables.dart';
import 'tables/sales_delivery_cache_tables.dart';
import 'tables/cash_receipt_cache_tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  PendingSyncQueue,
  ExchangeRateCache,
  AccountsCache,
  FinanceVoucherHeadersCache,
  FinanceVoucherLinesCache,
  CommonMasterTypesCache,
  CommonMastersCache,
  ProductsCache,
  PurchaseOrdersCache,
  PurchaseOrderLinesCache,
  PoChargeLinesCache,
  PoPaymentTermsCache,
  GenericLookupCache,
  GrnHeadersCache,
  GrnLinesCache,
  GrnChargeLinesCache,
  MaterialRequisitionHeadersCache,
  MaterialRequisitionLinesCache,
  MaterialIssueHeadersCache,
  MaterialIssueLinesCache,
  PurchaseReturnHeadersCache,
  PurchaseReturnLinesCache,
  PurchaseReturnChargeLinesCache,
  StockTransferRequestHeadersCache,
  StockTransferRequestLinesCache,
  StockTransferHeadersCache,
  StockTransferLinesCache,
  StockTransferChargeLinesCache,
  StockReceiptHeadersCache,
  StockReceiptLinesCache,
  StockAdjustmentHeadersCache,
  StockAdjustmentLinesCache,
  OpeningStockHeadersCache,
  OpeningStockLinesCache,
  StockCountHeadersCache,
  StockCountLinesCache,
  SalesQuotationsCache,
  SalesQuotationLinesCache,
  SalesQuotationChargeLinesCache,
  PriceMasterHeadersCache,
  PriceMasterLinesCache,
  SalesOrdersCache,
  SalesOrderLinesCache,
  SalesOrderChargeLinesCache,
  SalesInvoicesCache,
  SalesInvoiceLinesCache,
  ProductUomCache,
  TaxGroupMembersCache,
  TaxRatesCache,
  ModuleSyncStatusCache,
  SalesReturnHeadersCache,
  SalesReturnLinesCache,
  SalesDeliveriesCache,
  SalesDeliveryLinesCache,
  CashReceiptHeadersCache,
  CashReceiptLinesCache,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sakal_local'));

  /// Test-only constructor — points at a caller-supplied executor (typically
  /// `NativeDatabase.memory()`) instead of the real on-disk/web-worker
  /// database `driftDatabase()` creates. Standard Drift testing idiom; never
  /// used by production code.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 24;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(exchangeRateCache);
          if (from < 3) await m.createTable(accountsCache);
          if (from < 4) {
            await m.createTable(financeVoucherHeadersCache);
            await m.createTable(financeVoucherLinesCache);
          }
          if (from < 5) {
            await m.createTable(commonMasterTypesCache);
            await m.createTable(commonMastersCache);
          }
          if (from < 6) await m.createTable(productsCache);
          if (from < 7) {
            await m.createTable(purchaseOrdersCache);
            await m.createTable(purchaseOrderLinesCache);
            await m.createTable(poChargeLinesCache);
          }
          if (from < 8) await m.createTable(genericLookupCache);
          // v9 drops PurchaseOrdersCache.paymentTerms (superseded by
          // PoPaymentTermsCache, mirroring PoChargeLinesCache) — the column
          // is simply left as an unused orphan in the underlying SQLite file
          // on upgrade rather than migrated, since this is a device-local
          // cache rebuilt from the server, not a data store of record.
          if (from < 9) await m.createTable(poPaymentTermsCache);
          if (from < 10) {
            await m.createTable(grnHeadersCache);
            await m.createTable(grnLinesCache);
            await m.createTable(grnChargeLinesCache);
          }
          if (from < 11) {
            await m.createTable(materialRequisitionHeadersCache);
            await m.createTable(materialRequisitionLinesCache);
            await m.createTable(materialIssueHeadersCache);
            await m.createTable(materialIssueLinesCache);
            await m.createTable(purchaseReturnHeadersCache);
            await m.createTable(purchaseReturnLinesCache);
            await m.createTable(purchaseReturnChargeLinesCache);
            await m.createTable(stockTransferRequestHeadersCache);
            await m.createTable(stockTransferRequestLinesCache);
            await m.createTable(stockTransferHeadersCache);
            await m.createTable(stockTransferLinesCache);
            await m.createTable(stockTransferChargeLinesCache);
            await m.createTable(stockReceiptHeadersCache);
            await m.createTable(stockReceiptLinesCache);
          }
          if (from < 12) {
            await m.createTable(stockAdjustmentHeadersCache);
            await m.createTable(stockAdjustmentLinesCache);
          }
          if (from < 13) {
            await m.createTable(openingStockHeadersCache);
            await m.createTable(openingStockLinesCache);
          }
          if (from < 14) {
            await m.createTable(stockCountHeadersCache);
            await m.createTable(stockCountLinesCache);
          }
          // v15: manufacturing_date alongside expiry_date (migration 080,
          // regulatory/traceability). Only Opening Stock's cache is
          // normalized per-column — every other module stores its batch
          // children as a batchesJson blob, so the new field rides inside
          // that existing JSON with no schema change needed there.
          if (from < 15) await m.addColumn(openingStockLinesCache, openingStockLinesCache.manufacturingDate);
          if (from < 16) {
            await m.createTable(salesQuotationsCache);
            await m.createTable(salesQuotationLinesCache);
            await m.createTable(salesQuotationChargeLinesCache);
          }
          if (from < 17) {
            await m.createTable(priceMasterHeadersCache);
            await m.createTable(priceMasterLinesCache);
          }
          // v18: Price Master's backend contract was revised from
          // company-wide to LOCATION-WISE (docs/screens/sales_price_master.md)
          // before the v17 tables above ever shipped to a real device —
          // adding the location/currency/rate columns onto the header and
          // the cost/margin/below-cost-reason/barcode columns onto the
          // lines, same table classes, no new tables.
          if (from < 18) {
            await m.addColumn(priceMasterHeadersCache, priceMasterHeadersCache.locationId);
            await m.addColumn(priceMasterHeadersCache, priceMasterHeadersCache.locationName);
            await m.addColumn(priceMasterHeadersCache, priceMasterHeadersCache.priceCurrencyId);
            await m.addColumn(priceMasterHeadersCache, priceMasterHeadersCache.currencyCode);
            await m.addColumn(priceMasterHeadersCache, priceMasterHeadersCache.rateToBase);
            await m.addColumn(priceMasterHeadersCache, priceMasterHeadersCache.rateToLocal);
            await m.addColumn(priceMasterLinesCache, priceMasterLinesCache.barcode);
            await m.addColumn(priceMasterLinesCache, priceMasterLinesCache.costPrice);
            await m.addColumn(priceMasterLinesCache, priceMasterLinesCache.marginPercent);
            await m.addColumn(priceMasterLinesCache, priceMasterLinesCache.belowCostReasonId);
            await m.addColumn(priceMasterLinesCache, priceMasterLinesCache.belowCostReasonName);
          }
          if (from < 19) {
            await m.createTable(salesOrdersCache);
            await m.createTable(salesOrderLinesCache);
            await m.createTable(salesOrderChargeLinesCache);
          }
          // v20: Sales Order's own pre-launch revision (before the v19
          // tables above ever shipped to a real device) — payment_terms/
          // delivery_terms TEXT columns replaced with structured
          // payment_term_id/incoterm_id references (086_payment_terms),
          // plus ship_to/bill_to/expected_delivery_date/cancellation_reason
          // and the line's price_source_entry_no traceability column.
          if (from < 20) {
            await m.addColumn(salesOrdersCache, salesOrdersCache.shipTo);
            await m.addColumn(salesOrdersCache, salesOrdersCache.billTo);
            await m.addColumn(salesOrdersCache, salesOrdersCache.expectedDeliveryDate);
            await m.addColumn(salesOrdersCache, salesOrdersCache.paymentTermId);
            await m.addColumn(salesOrdersCache, salesOrdersCache.paymentTermName);
            await m.addColumn(salesOrdersCache, salesOrdersCache.incotermId);
            await m.addColumn(salesOrdersCache, salesOrdersCache.incotermLabel);
            await m.addColumn(salesOrdersCache, salesOrdersCache.deliveryInstructions);
            await m.addColumn(salesOrdersCache, salesOrdersCache.cancellationReason);
            await m.addColumn(salesOrderLinesCache, salesOrderLinesCache.priceSourceEntryNo);
          }
          // v21: Sales Invoice ("Quick Invoice") — first Sales module
          // screen with real GL/stock impact (089_sales_invoice.sql).
          if (from < 21) {
            await m.createTable(salesInvoicesCache);
            await m.createTable(salesInvoiceLinesCache);
          }
          // v22: shared app-wide Master-Data Sync facility — closes the
          // gap where Sales Invoice (and several other offline-capable
          // modules) had no offline fallback at all for their product/
          // customer/UOM/tax pickers. New tables for the master-data
          // types with no existing cache shape (relational/date-window
          // lookups a GenericLookupCache blob can't serve), plus extra
          // nullable Customer-detail columns on the existing AccountsCache.
          if (from < 22) {
            await m.createTable(productUomCache);
            await m.createTable(taxGroupMembersCache);
            await m.createTable(taxRatesCache);
            await m.createTable(moduleSyncStatusCache);
            await m.addColumn(accountsCache, accountsCache.creditLimit);
            await m.addColumn(accountsCache, accountsCache.creditDays);
            await m.addColumn(accountsCache, accountsCache.isCreditBlocked);
            await m.addColumn(accountsCache, accountsCache.phone);
            await m.addColumn(accountsCache, accountsCache.email);
            await m.addColumn(accountsCache, accountsCache.addressLine1);
            await m.addColumn(accountsCache, accountsCache.addressLine2);
          }
          // v23: offline-first pass on Sales Return (retrofit — it had no
          // offline support at all before this) and Sales Delivery (new
          // module, built with offline SAVE from day one). Both mirror
          // Sales Invoice's own DIRECT-mode offline-Save shape; Approve
          // stays online-only for both, same as every offline-capable
          // module in this schema. See docs/screens/sales_delivery.md.
          if (from < 23) {
            await m.createTable(salesReturnHeadersCache);
            await m.createTable(salesReturnLinesCache);
            await m.createTable(salesDeliveriesCache);
            await m.createTable(salesDeliveryLinesCache);
          }
          // v24: Cash Receipt (Cash Collection) — new module, built with
          // offline SAVE from day one, same shape as Sales Delivery.
          // Approve stays online-only, surfaced via the unified Pending
          // Approvals screen. See docs/screens/cash_receipt.md.
          if (from < 24) {
            await m.createTable(cashReceiptHeadersCache);
            await m.createTable(cashReceiptLinesCache);
          }
        },
      );
}

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

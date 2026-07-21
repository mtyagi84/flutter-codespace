import 'dart:async';
import '../../domain/repositories/sales_invoice_repository.dart';
import '../datasources/sales_invoice_remote_ds.dart';
import '../datasources/sales_invoice_local_ds.dart';

class SalesInvoiceRepositoryImpl implements SalesInvoiceRepository {
  final SalesInvoiceRemoteDs _remote;
  final SalesInvoiceLocalDs? _local; // null on Flutter Web (no Drift)
  final bool _isOffline;

  SalesInvoiceRepositoryImpl(this._remote, this._local, this._isOffline);

  @override
  Future<List<Map<String, dynamic>>> listInvoices({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    String? saleType,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listInvoices(
        clientId: clientId, companyId: companyId, search: search, status: status,
        saleType: saleType, limit: limit, offset: offset,
      );
    }
    return _remote.listInvoices(
      clientId: clientId, companyId: companyId, search: search, status: status,
      saleType: saleType, limit: limit, offset: offset,
    );
  }

  @override
  Future<Map<String, dynamic>?> getHeader({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    String? invoiceDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, invoiceNo, invoiceDate, lines));
    return lines;
  }

  // Online-only, like Manager Review's own reads below — an offline-created
  // DRAFT's batch/serial allocations aren't cached locally (only header/
  // lines are, via SalesInvoiceLocalDs), so reopening a not-yet-synced
  // offline invoice after navigating away loses this specific detail; a
  // known, narrow limitation rather than a full local-cache buildout.
  @override
  Future<List<Map<String, dynamic>>> getCharges({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getCharges(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getAdditionalCharges(clientId: clientId, companyId: companyId);
    }
    final rows = await _remote.getAdditionalCharges(clientId: clientId, companyId: companyId);
    if (_local != null) unawaited(_local.cacheAdditionalCharges(clientId: clientId, companyId: companyId, rows: rows));
    return rows;
  }

  @override
  Future<List<Map<String, dynamic>>> getQuotationCharges({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) => _remote.getQuotationCharges(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);

  @override
  Future<List<Map<String, dynamic>>> getOrderCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) => _remote.getOrderCharges(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);

  @override
  Future<List<Map<String, dynamic>>> getLineBatchAllocations({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getLineBatchAllocations(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getLineSerialAllocations({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
  }) => _remote.getLineSerialAllocations(clientId: clientId, companyId: companyId, invoiceNo: invoiceNo, invoiceDate: invoiceDate);

  @override
  Future<List<Map<String, dynamic>>> getPostedVoucherLines({
    required String clientId,
    required String companyId,
    required String voucherNo,
    required String voucherDate,
  }) => _remote.getPostedVoucherLines(clientId: clientId, companyId: companyId, voucherNo: voucherNo, voucherDate: voucherDate);

  // ── Manager Review — online-only, no local fallback ───────────────────────

  @override
  Future<List<Map<String, dynamic>>> listDraftInvoicesForReview({
    required String clientId,
    required String companyId,
    required String locationId,
  }) => _remote.listDraftInvoicesForReview(clientId: clientId, companyId: companyId, locationId: locationId);

  @override
  Future<Map<String, dynamic>?> getStockPreview({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getStockPreview(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getBatchStockBalance({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getBatchStockBalance(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<List<Map<String, dynamic>>> getSerialStockStatus({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getSerialStockStatus(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  // ── Against-Quotation / Against-Order — online-only ───────────────────────

  @override
  Future<List<Map<String, dynamic>>> getInvoiceableQuotations({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getInvoiceableQuotations(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<List<Map<String, dynamic>>> getInvoiceableOrders({
    required String clientId,
    required String companyId,
    String? search,
  }) => _remote.getInvoiceableOrders(clientId: clientId, companyId: companyId, search: search);

  @override
  Future<Map<String, dynamic>?> getQuotationHeader({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) => _remote.getQuotationHeader(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);

  @override
  Future<List<Map<String, dynamic>>> getQuotationLines({
    required String clientId,
    required String companyId,
    required String quotationNo,
    required String quotationDate,
  }) => _remote.getQuotationLines(clientId: clientId, companyId: companyId, quotationNo: quotationNo, quotationDate: quotationDate);

  @override
  Future<Map<String, dynamic>?> getOrderHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) => _remote.getOrderHeader(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);

  @override
  Future<List<Map<String, dynamic>>> getOrderLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) => _remote.getOrderLines(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);

  // ── Direct mode: price/discount governance ───────────────────────────────

  @override
  Future<Map<String, dynamic>?> getActivePrice({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
    required String uomId,
    required String customerId,
    required String asOfDate,
    required String currencyCode,
  }) => _remote.getActivePrice(
        clientId: clientId, companyId: companyId, locationId: locationId,
        productId: productId, uomId: uomId, customerId: customerId, asOfDate: asOfDate,
        currencyCode: currencyCode,
      );

  @override
  Future<Map<String, dynamic>?> getUserSalesControls({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getUserSalesControls(clientId: clientId, companyId: companyId, userId: userId);
    }
    final row = await _remote.getUserSalesControls(clientId: clientId, companyId: companyId, userId: userId);
    if (row != null && _local != null) {
      unawaited(_local.cacheUserSalesControls(clientId: clientId, companyId: companyId, userId: userId, row: row));
    }
    return row;
  }

  @override
  Future<Map<String, dynamic>?> getQuickInvoiceSetup({
    required String clientId,
    required String companyId,
    required String userId,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getQuickInvoiceSetup(clientId: clientId, companyId: companyId, userId: userId);
    }
    final row = await _remote.getQuickInvoiceSetup(clientId: clientId, companyId: companyId, userId: userId);
    if (row != null && _local != null) {
      unawaited(_local.cacheQuickInvoiceSetup(clientId: clientId, companyId: companyId, userId: userId, row: row));
    }
    return row;
  }

  @override
  Future<Map<String, dynamic>?> getProductLocationCost({
    required String clientId,
    required String companyId,
    required String locationId,
    required String productId,
  }) => _remote.getProductLocationCost(clientId: clientId, companyId: companyId, locationId: locationId, productId: productId);

  @override
  Future<Map<String, dynamic>> verifyDiscountOverride({
    required String clientId,
    required String companyId,
    required String username,
    required String password,
    required double requestedDiscountPercent,
  }) => _remote.verifyDiscountOverride(
        clientId: clientId, companyId: companyId, username: username,
        password: password, requestedDiscountPercent: requestedDiscountPercent,
      );

  // ── Shared pickers ────────────────────────────────────────────────────────

  // getCustomerDetails: offline read falls back to AccountsCache (via the
  // shared Master-Data Sync facility's Customers & Suppliers module). No
  // defensive write-through here — this method's own signature has no
  // clientId/companyId to scope a cache write with, unlike every other
  // method here; AccountsCache is kept warm by accountsProvider's own
  // write-through (core/providers/master_cache_providers.dart) and the
  // bulk sync, so this is a read-only fallback.
  @override
  Future<Map<String, dynamic>?> getCustomerDetails({required String customerId}) async {
    if (_isOffline && _local != null) {
      return _local.getCustomerDetails(customerId: customerId);
    }
    return _remote.getCustomerDetails(customerId: customerId);
  }

  @override
  Future<List<Map<String, dynamic>>> getUsersForAutocomplete({
    required String clientId,
    required String companyId,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getUsersForAutocomplete(clientId: clientId, companyId: companyId);
    }
    final rows = await _remote.getUsersForAutocomplete(clientId: clientId, companyId: companyId);
    if (_local != null) unawaited(_local.cacheUsersForAutocomplete(clientId: clientId, companyId: companyId, rows: rows));
    return rows;
  }

  @override
  Future<List<Map<String, dynamic>>> getSalesExecutivesForPicker({
    required String clientId,
    required String companyId,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getSalesExecutivesForPicker(clientId: clientId, companyId: companyId);
    }
    final rows = await _remote.getSalesExecutivesForPicker(clientId: clientId, companyId: companyId);
    if (_local != null) unawaited(_local.cacheSalesExecutivesForPicker(clientId: clientId, companyId: companyId, rows: rows));
    return rows;
  }

  // getProductsForPicker/getProductByCode: offline reads fall back to the
  // shared ProductsCache/ProductUomCache (populated by the bulk Master-Data
  // Sync facility). No defensive write-through here — the remote picker's
  // own select list deliberately omits client_id/company_id (a search
  // result, not a full row), so there's nothing to scope a partial cache
  // write with safely; the bulk sync is this data's authoritative source.
  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) {
    if (_isOffline && _local != null) {
      return _local.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);
    }
    return _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);
  }

  @override
  Future<Map<String, dynamic>?> getProductByCode({
    required String clientId,
    required String companyId,
    required String code,
    required bool tryPartNumber,
  }) {
    if (_isOffline && _local != null) {
      return _local.getProductByCode(clientId: clientId, companyId: companyId, code: code, tryPartNumber: tryPartNumber);
    }
    return _remote.getProductByCode(clientId: clientId, companyId: companyId, code: code, tryPartNumber: tryPartNumber);
  }

  @override
  Future<List<Map<String, dynamic>>> getProductUoms(String productId) async {
    if (_isOffline && _local != null) {
      return _local.getProductUoms(productId);
    }
    final rows = await _remote.getProductUoms(productId);
    if (_local != null) unawaited(_local.cacheProductUoms(productId: productId, rows: rows));
    return rows;
  }

  @override
  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getTaxGroups(clientId: clientId, companyId: companyId);
    }
    final rows = await _remote.getTaxGroups(clientId: clientId, companyId: companyId);
    if (_local != null) unawaited(_local.cacheTaxGroups(clientId: clientId, companyId: companyId, rows: rows));
    return rows;
  }

  // getTaxGroupMemberTaxIds/getTaxRatesByIds: offline reads fall back to
  // TaxGroupMembersCache/TaxRatesCache (populated by the bulk Master-Data
  // Sync facility). No defensive write-through — the remote methods here
  // return an already-transformed Map, not raw rows, so there's nothing to
  // upsert without re-flattening; the bulk sync is this data's
  // authoritative source (same reasoning as Products above).
  @override
  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) {
    if (_isOffline && _local != null) {
      return _local.getTaxGroupMemberTaxIds(groupIds);
    }
    return _remote.getTaxGroupMemberTaxIds(groupIds);
  }

  @override
  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) {
    if (_isOffline && _local != null) {
      return _local.getTaxRatesByIds(taxIds: taxIds, asOfDate: asOfDate);
    }
    return _remote.getTaxRatesByIds(taxIds: taxIds, asOfDate: asOfDate);
  }

  @override
  Future<double?> getExchangeRate({
    required String companyId,
    required String locationId,
    required String fromCurrency,
    required String toCurrency,
    required String rateDate,
  }) => _remote.getExchangeRate(
        companyId: companyId, locationId: locationId,
        fromCurrency: fromCurrency, toCurrency: toCurrency, rateDate: rateDate,
      );

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> serials,
    required String userId,
  }) => _remote.save(header: header, lines: lines, charges: charges, batches: batches, serials: serials, userId: userId);

  @override
  Future<void> cacheInvoiceLocally({
    required String effectiveInvoiceNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) => _local?.cacheFromMaps(effectiveInvoiceNo, header, lines) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId, invoiceNo: invoiceNo,
        invoiceDate: invoiceDate, approvedBy: approvedBy,
      );

  @override
  Future<void> cancel({
    required String clientId,
    required String companyId,
    required String invoiceNo,
    required String invoiceDate,
    required String reason,
    required String userId,
  }) => _remote.cancel(
        clientId: clientId, companyId: companyId, invoiceNo: invoiceNo,
        invoiceDate: invoiceDate, reason: reason, userId: userId,
      );
}

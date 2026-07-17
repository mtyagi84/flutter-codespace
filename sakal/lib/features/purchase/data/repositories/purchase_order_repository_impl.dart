import 'dart:async';
import '../../../../core/database/datasources/generic_lookup_local_ds.dart';
import '../../../../core/database/datasources/tax_group_members_local_ds.dart';
import '../../../../core/database/datasources/tax_rates_local_ds.dart';
import '../../domain/repositories/purchase_order_repository.dart';
import '../datasources/purchase_order_remote_ds.dart';
import '../datasources/purchase_order_local_ds.dart';
import '../models/po_charge_line_model.dart';
import '../models/po_payment_term_model.dart';
import '../models/purchase_order_line_model.dart';
import '../models/purchase_order_model.dart';

class PurchaseOrderRepositoryImpl implements PurchaseOrderRepository {
  final PurchaseOrderRemoteDs   _remote;
  final PurchaseOrderLocalDs?   _local;       // null on Flutter Web (no Drift)
  final GenericLookupLocalDs?   _lookupLocal; // null on Flutter Web (no Drift)
  final TaxGroupMembersLocalDs? _taxGroupMembersLocal; // null on Flutter Web (no Drift)
  final TaxRatesLocalDs?        _taxRatesLocal;        // null on Flutter Web (no Drift)
  final bool                    _isOffline;
  final String                  _clientId;
  final String                  _companyId;

  PurchaseOrderRepositoryImpl(
    this._remote,
    this._local,
    this._lookupLocal,
    this._isOffline,
    this._clientId,
    this._companyId, {
    TaxGroupMembersLocalDs? taxGroupMembersLocal,
    TaxRatesLocalDs? taxRatesLocal,
  })  : _taxGroupMembersLocal = taxGroupMembersLocal,
        _taxRatesLocal = taxRatesLocal;

  // Small helper for the reference-data getters below: try the cache first
  // when offline, otherwise fetch remote and cache for next time.
  Future<List<Map<String, dynamic>>> _cachedLookup({
    required String cacheKey,
    required Future<List<Map<String, dynamic>>> Function() fetchRemote,
  }) async {
    if (_isOffline && _lookupLocal != null) {
      return _lookupLocal.getLookups(cacheKey: cacheKey, clientId: _clientId, companyId: _companyId);
    }
    final rows = await fetchRemote();
    if (_lookupLocal != null) {
      unawaited(_lookupLocal.upsertLookups(
        cacheKey: cacheKey,
        rows: rows,
        idOf: (r) => r['id'] as String,
        clientId: _clientId,
        companyId: _companyId,
      ));
    }
    return rows;
  }

  @override
  Future<List<PurchaseOrderModel>> listOrders({
    required String clientId,
    required String companyId,
    String? search,
    String? status,
    int     limit  = 50,
    int     offset = 0,
  }) {
    if (_isOffline && _local != null) {
      return _local.listOrders(
        clientId: clientId, companyId: companyId,
        search: search, status: status, limit: limit, offset: offset,
      );
    }
    // Online: remote is the source of truth for browsing history. Offline-created
    // (not-yet-synced) orders are already cached via cacheOrderLocally and don't
    // need caching again here — transaction history browsing isn't guaranteed
    // offline, only newly-created docs are (same rationale as Finance Voucher).
    return _remote.listOrders(
      clientId: clientId, companyId: companyId,
      search: search, status: status, limit: limit, offset: offset,
    );
  }

  @override
  Future<PurchaseOrderModel?> getHeader({
    required String clientId,
    required String companyId,
    required String orderNo,
    String? orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getHeader(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final header = await _remote.getHeader(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (header != null && _local != null) unawaited(_local.cacheHeader(header));
    return header;
  }

  @override
  Future<List<PurchaseOrderLineModel>> getLines({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getLines(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final lines = await _remote.getLines(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (_local != null) unawaited(_local.cacheLines(clientId, companyId, orderNo, orderDate, lines));
    return lines;
  }

  @override
  Future<List<PoChargeLineModel>> getCharges({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getCharges(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final charges = await _remote.getCharges(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (_local != null) unawaited(_local.cacheCharges(clientId, companyId, orderNo, orderDate, charges));
    return charges;
  }

  @override
  Future<List<PoPaymentTermModel>> getPaymentTerms({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
  }) async {
    if (_isOffline && _local != null) {
      return _local.getPaymentTerms(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    }
    final terms = await _remote.getPaymentTerms(clientId: clientId, companyId: companyId, orderNo: orderNo, orderDate: orderDate);
    if (_local != null) unawaited(_local.cachePaymentTerms(clientId, companyId, orderNo, orderDate, terms));
    return terms;
  }

  @override
  Future<String> save({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required List<Map<String, dynamic>> paymentTerms,
    required String userId,
  }) => _remote.save(header: header, lines: lines, charges: charges, paymentTerms: paymentTerms, userId: userId);

  @override
  Future<void> cacheOrderLocally({
    required String effectiveOrderNo,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> charges,
    required List<Map<String, dynamic>> paymentTerms,
  }) => _local?.cacheFromMaps(effectiveOrderNo, header, lines, charges, paymentTerms) ?? Future.value();

  @override
  Future<void> approve({
    required String clientId,
    required String companyId,
    required String orderNo,
    required String orderDate,
    required String approvedBy,
  }) => _remote.approve(
        clientId: clientId, companyId: companyId,
        orderNo: orderNo, orderDate: orderDate, approvedBy: approvedBy,
      );

  @override
  Future<List<Map<String, dynamic>>> getAdditionalCharges({
    required String clientId,
    required String companyId,
  }) => _cachedLookup(
        cacheKey: 'PO_ADDITIONAL_CHARGES',
        fetchRemote: () => _remote.getAdditionalCharges(clientId: clientId, companyId: companyId),
      );

  @override
  Future<List<Map<String, dynamic>>> getProductsForPicker({
    required String clientId,
    required String companyId,
    String? search,
  }) async {
    if (_isOffline && _lookupLocal != null) {
      final all = await _lookupLocal.getLookups(cacheKey: 'PO_PRODUCT_PICKER', clientId: clientId, companyId: companyId);
      if (search == null || search.isEmpty) return all;
      final s = search.toLowerCase();
      return all.where((p) =>
          (p['product_code'] as String? ?? '').toLowerCase().contains(s) ||
          (p['product_name'] as String? ?? '').toLowerCase().contains(s)).toList();
    }
    final rows = await _remote.getProductsForPicker(clientId: clientId, companyId: companyId, search: search);
    // Only cache the unfiltered page — caching every search term's result
    // separately isn't worth it, and this still gives offline sessions the
    // most commonly needed (unfiltered) picker list.
    if (_lookupLocal != null && (search == null || search.isEmpty)) {
      unawaited(_lookupLocal.upsertLookups(
        cacheKey: 'PO_PRODUCT_PICKER', rows: rows, idOf: (r) => r['id'] as String,
        clientId: clientId, companyId: companyId,
      ));
    }
    return rows;
  }

  @override
  Future<Map<String, dynamic>?> getProductByBarcode({
    required String clientId,
    required String companyId,
    required String barcode,
  }) {
    // Always online — barcode lookup needs the live rim_product_uom table;
    // not worth a dedicated offline cache for a feature this narrow.
    return _remote.getProductByBarcode(clientId: clientId, companyId: companyId, barcode: barcode);
  }

  @override
  Future<List<Map<String, dynamic>>> getCommonMastersByType({
    required String clientId,
    required String companyId,
    required String typeKey,
  }) => _cachedLookup(
        cacheKey: 'PO_COMMON_MASTERS_$typeKey',
        fetchRemote: () => _remote.getCommonMastersByType(clientId: clientId, companyId: companyId, typeKey: typeKey),
      );

  @override
  Future<List<Map<String, dynamic>>> getTaxGroups({
    required String clientId,
    required String companyId,
  }) => _cachedLookup(
        cacheKey: 'PO_TAX_GROUPS',
        fetchRemote: () => _remote.getTaxGroups(clientId: clientId, companyId: companyId),
      );

  // Genuine offline gap (same class of bug found in Sales Invoice, migration
  // 088/089 session) — these two were remote-only with no cache branch at
  // all, unlike this repository's other lookups, which already go through
  // _cachedLookup. Now served from the shared TaxGroupMembersCache/
  // TaxRatesCache (core/sync/master_data_modules.dart's Products & Pricing
  // module) when the new local-ds instances are supplied.
  @override
  Future<Map<String, List<String>>> getTaxGroupMemberTaxIds(List<String> groupIds) async {
    if (_isOffline && _taxGroupMembersLocal != null) {
      return _taxGroupMembersLocal.getMemberTaxIds(groupIds);
    }
    return _remote.getTaxGroupMemberTaxIds(groupIds);
  }

  @override
  Future<Map<String, double>> getTaxRatesByIds({
    required List<String> taxIds,
    required String asOfDate,
  }) async {
    if (_isOffline && _taxRatesLocal != null) {
      return _taxRatesLocal.getRatesByIds(taxIds: taxIds, asOfDate: asOfDate);
    }
    return _remote.getTaxRatesByIds(taxIds: taxIds, asOfDate: asOfDate);
  }

  @override
  Future<Map<String, double>> getProductStockSnapshot({
    required String productId,
    required String locationId,
  }) => _remote.getProductStockSnapshot(productId: productId, locationId: locationId);

  @override
  Future<List<Map<String, dynamic>>> getUsers({
    required String clientId,
    required String companyId,
  }) => _cachedLookup(
        cacheKey: 'PO_USERS',
        fetchRemote: () => _remote.getUsers(clientId: clientId, companyId: companyId),
      );

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
}

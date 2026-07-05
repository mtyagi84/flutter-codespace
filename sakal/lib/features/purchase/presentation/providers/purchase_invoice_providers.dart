import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/purchase_invoice_remote_ds.dart';
import '../../data/repositories/purchase_invoice_repository_impl.dart';
import '../../domain/repositories/purchase_invoice_repository.dart';

final _purchaseInvoiceRemoteDsProvider = Provider<PurchaseInvoiceRemoteDs>(
  (_) => PurchaseInvoiceRemoteDs(),
);

final purchaseInvoiceRepositoryProvider = Provider<PurchaseInvoiceRepository>(
  (ref) => PurchaseInvoiceRepositoryImpl(ref.watch(_purchaseInvoiceRemoteDsProvider)),
);

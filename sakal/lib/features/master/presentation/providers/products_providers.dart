import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/products_remote_ds.dart';
import '../../data/repositories/products_repository_impl.dart';
import '../../domain/repositories/products_repository.dart';

final productsRepositoryProvider = Provider.autoDispose<ProductsRepository>(
  (ref) => ProductsRepositoryImpl(ProductsRemoteDs()),
);

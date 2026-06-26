import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/item_categories_remote_ds.dart';
import '../../data/repositories/item_categories_repository_impl.dart';
import '../../domain/repositories/item_categories_repository.dart';

final itemCategoriesRepositoryProvider = Provider<ItemCategoriesRepository>(
  (ref) => ItemCategoriesRepositoryImpl(ItemCategoriesRemoteDs()),
);

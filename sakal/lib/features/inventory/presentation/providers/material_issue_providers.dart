import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/material_issue_remote_ds.dart';
import '../../data/repositories/material_issue_repository_impl.dart';
import '../../domain/repositories/material_issue_repository.dart';

final _materialIssueRemoteDsProvider = Provider<MaterialIssueRemoteDs>(
  (_) => MaterialIssueRemoteDs(),
);

final materialIssueRepositoryProvider = Provider<MaterialIssueRepository>(
  (ref) => MaterialIssueRepositoryImpl(ref.watch(_materialIssueRemoteDsProvider)),
);

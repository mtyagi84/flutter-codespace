import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/session_provider.dart';
import 'core/router/app_router.dart';
import 'core/services/local_storage.dart';
import 'core/services/offline_session_cache.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStorage.init();

  // Restore session from secure storage so page refresh doesn't log the user out.
  // tryRestoreSession() returns null if the user previously called logout (deactivate).
  final restored = await OfflineSessionCache.tryRestoreSession();
  if (restored != null) {
    sessionNotifier.value = restored.session;
    // Ensure client_no is in SharedPreferences so the router's hasClient check passes.
    if (LocalStorage.clientNo == null) {
      await LocalStorage.saveClientSession(
        clientNo: restored.session.clientNo,
        clientId: restored.session.clientId,
      );
    }
  }

  runApp(ProviderScope(
    overrides: restored != null
        ? [
            sessionProvider.overrideWith((ref) => restored.session),
            menuProvider.overrideWith((ref) => restored.menu),
          ]
        : const [],
    child: const SakalApp(),
  ));
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/network/dio_client.dart';
import 'core/providers/session_provider.dart';
import 'core/router/app_router.dart';
import 'core/services/local_storage.dart';
import 'core/services/offline_session_cache.dart';
import 'core/utils/app_logger.dart';
import 'app.dart';

void main() {
  // Wrapping startup in a guarded zone plus the two framework-level hooks
  // below is the only way to see an otherwise-silent crash on a device with
  // no crash-reporting SDK configured (none is set up in this app — see
  // CLAUDE.md's "Crash visibility" mandatory pattern). Every path funnels
  // into AppLogger so a field-reported crash isn't a total black box.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      AppLogger.error('Flutter', details.exception, details.stack);
      FlutterError.presentError(details); // keep the existing dev red-screen behavior
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      AppLogger.error('Platform', error, stack);
      return true;
    };

    await LocalStorage.init();

    // When any API call returns 401 (JWT expired), clear the active session flag
    // and signal GoRouter — it sees sessionNotifier → null and redirects to login.
    DioClient.onSessionExpired = () {
      sessionNotifier.value = null;
      OfflineSessionCache.deactivate(); // fire-and-forget; prevents stale session restore on next page refresh
    };

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
  }, (error, stack) => AppLogger.error('Zone', error, stack));
}

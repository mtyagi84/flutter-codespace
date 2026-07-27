import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'app_logger_file_stub.dart'
    if (dart.library.io) 'app_logger_file_io.dart' as file_persist;

enum AppLogLevel { info, warn, error }

class AppLogEntry {
  final DateTime time;
  final AppLogLevel level;
  final String tag;
  final String message;
  final String? stackTrace;

  const AppLogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.stackTrace,
  });

  String get _levelLabel => switch (level) {
        AppLogLevel.info => 'INFO',
        AppLogLevel.warn => 'WARN',
        AppLogLevel.error => 'ERROR',
      };

  String toLine() => '${time.toIso8601String()} [$_levelLabel] $tag: $message'
      '${stackTrace != null ? '\n$stackTrace' : ''}';

  String toJsonLine() => jsonEncode({
        'time': time.toIso8601String(),
        'level': _levelLabel,
        'tag': tag,
        'message': message,
        if (stackTrace != null) 'stack': stackTrace,
      });
}

/// App-wide crash/error visibility. Not a business-data log — a local,
/// diagnostic trail so a field-reported crash isn't a total black box on a
/// device with no live crash-reporting SDK (none is configured; see
/// CLAUDE.md's "Crash visibility" mandatory pattern). Every catch block
/// that used to interpolate a raw exception into user-facing text now logs
/// the real detail here instead (see [ErrorPresenter] in
/// `lib/core/errors/error_presenter.dart`), and uncaught
/// framework/zone/platform errors are wired in via `main.dart`.
///
/// Persists to a small rotating file on native platforms (skipped on web —
/// no writable filesystem, the in-memory ring buffer alone covers that
/// session). Never throws — a logging failure must never crash the thing
/// it was trying to observe.
class AppLogger {
  AppLogger._();

  static const int _maxEntries = 200;
  static const int _maxFileBytes = 2 * 1024 * 1024; // 2MB per file, 2 files kept
  static final List<AppLogEntry> _entries = [];

  static void error(String tag, Object error, StackTrace? st, {Map<String, dynamic>? context}) =>
      _log(AppLogLevel.error, tag, error, st, context);

  static void warn(String tag, Object message, {StackTrace? st, Map<String, dynamic>? context}) =>
      _log(AppLogLevel.warn, tag, message, st, context);

  static void info(String tag, Object message, {Map<String, dynamic>? context}) =>
      _log(AppLogLevel.info, tag, message, null, context);

  static void _log(AppLogLevel level, String tag, Object message, StackTrace? st,
      Map<String, dynamic>? context) {
    try {
      final text = context == null || context.isEmpty ? '$message' : '$message | $context';
      final entry = AppLogEntry(
        time: DateTime.now(),
        level: level,
        tag: tag,
        message: text,
        stackTrace: st?.toString(),
      );
      _entries.add(entry);
      if (_entries.length > _maxEntries) _entries.removeAt(0);
      debugPrint(entry.toLine());
      unawaited(_persist(entry));
    } catch (_) {
      // Logging must never itself throw.
    }
  }

  static Future<void> _persist(AppLogEntry entry) async {
    if (kIsWeb) return;
    try {
      await file_persist.persistLogLine(entry.toJsonLine(), maxFileBytes: _maxFileBytes);
    } catch (_) {
      // Best-effort only — a logging failure must never crash the thing it was observing.
    }
  }

  /// Last ~200 entries, most-recent-last — for the in-app log viewer.
  static List<AppLogEntry> get recentEntries => List.unmodifiable(_entries);

  /// Plain-text dump of the in-memory buffer for a "Copy to Clipboard" action.
  static String exportAsText() {
    if (_entries.isEmpty) return 'No log entries yet.';
    return _entries.map((e) => e.toLine()).join('\n\n');
  }
}

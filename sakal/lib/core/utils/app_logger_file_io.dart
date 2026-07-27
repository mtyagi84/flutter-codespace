import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Native (Android/iOS/Desktop) implementation — selected via conditional
/// import in `app_logger.dart` when `dart.library.io` is available. Never
/// imported on web; see `app_logger_file_stub.dart`.
File? _logFile;
bool _initStarted = false;

Future<void> persistLogLine(String jsonLine, {required int maxFileBytes}) async {
  try {
    final file = await _ensureLogFile();
    if (file == null) return;
    if (await file.exists() && (await file.length()) > maxFileBytes) {
      final rotated = File('${file.path}.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
    }
    await file.writeAsString('$jsonLine\n', mode: FileMode.append, flush: false);
  } catch (_) {
    // Best-effort only — a full disk or sandbox restriction shouldn't matter here.
  }
}

Future<File?> _ensureLogFile() async {
  if (_logFile != null) return _logFile;
  if (_initStarted) return null; // another call already racing to init; skip this one
  _initStarted = true;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final logsDir = Directory('${dir.path}/logs');
    if (!await logsDir.exists()) await logsDir.create(recursive: true);
    _logFile = File('${logsDir.path}/app.log');
    return _logFile;
  } catch (_) {
    return null;
  }
}

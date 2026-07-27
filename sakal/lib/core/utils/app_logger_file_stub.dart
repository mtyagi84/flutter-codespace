/// Web stub — no writable filesystem, so persistence is a no-op there.
/// Selected via conditional import in `app_logger.dart` (`dart.library.io`
/// is unavailable on web, so this file is used instead of
/// `app_logger_file_io.dart`, which imports `dart:io` — importing that
/// directly and unconditionally would break the web build).
Future<void> persistLogLine(String jsonLine, {required int maxFileBytes}) async {}

/// Conditional-import entry point — resolves to the real dart:html
/// implementation when compiled for web, and to a never-called stub on
/// every other platform (Android/iOS/Desktop keep using
/// FilePicker.platform.saveFile(), unaffected by this file).
export 'web_download_stub.dart' if (dart.library.html) 'web_download_web.dart';

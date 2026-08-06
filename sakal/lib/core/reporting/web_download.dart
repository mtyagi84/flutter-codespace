/// Conditional-import entry point — resolves to the real package:web
/// implementation when compiled for web, and to a never-called stub on
/// every other platform (Android/iOS/Desktop keep using
/// FilePicker.platform.saveFile(), unaffected by this file).
library;

export 'web_download_stub.dart' if (dart.library.js_interop) 'web_download_web.dart';

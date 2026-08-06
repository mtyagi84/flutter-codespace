import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// The real web implementation, selected by the conditional import in
/// web_download.dart. Blob + a hidden <a download> anchor's own .click()
/// — the classic, universally-supported browser download technique.
/// Deliberately NOT FilePicker.platform.saveFile() on web: that goes
/// through Chrome's File System Access API (showSaveFilePicker), which
/// requires a still-valid "user activation" at the moment it's called —
/// report_excel_export.dart always awaits a network fetch first (to know
/// what to write), and by the time that resolves the activation window
/// from the original button click may already have expired, silently
/// failing. A Blob+anchor click has no such timing requirement.
///
/// Uses package:web + dart:js_interop (not the deprecated dart:html) —
/// every member here (Blob's positional constructor, BlobPart = JSAny,
/// URL.createObjectURL/revokeObjectURL, document.createElement('a') as
/// HTMLAnchorElement, appendChild, style.display, click, remove) was
/// verified directly against the pinned web package's own binding source
/// rather than assumed, since this API surface can't be compiled/checked
/// locally in this environment.
void downloadBytesOnWeb(List<int> bytes, String filename) {
  final blobParts = <JSAny>[Uint8List.fromList(bytes).toJS].toJS;
  final blob = web.Blob(blobParts, web.BlobPropertyBag(type: 'application/octet-stream'));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

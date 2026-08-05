import 'dart:html' as html;

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
void downloadBytesOnWeb(List<int> bytes, String filename) {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}

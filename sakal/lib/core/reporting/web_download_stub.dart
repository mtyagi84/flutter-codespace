/// Non-web fallback for the conditional import in web_download.dart —
/// Android/iOS/Desktop never call this (report_excel_export.dart only
/// calls it when kIsWeb is true; FilePicker.platform.saveFile() handles
/// every other platform, same as before this file existed).
void downloadBytesOnWeb(List<int> bytes, String filename) {
  throw UnsupportedError('downloadBytesOnWeb is web-only');
}

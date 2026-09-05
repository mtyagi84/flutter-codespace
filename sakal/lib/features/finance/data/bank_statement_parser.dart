import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xls;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// One row extracted from an uploaded bank statement, before it's saved as
/// a real rid_bank_statement_lines row. `isReviewed` starts false for
/// PDF-sourced rows (mandatory human review before they can be trusted —
/// a PDF has no real "column" concept, so table reconstruction is a
/// heuristic that can silently misplace a value) and true for CSV/EXCEL
/// rows (already real structured table data).
class ParsedStatementLine {
  String txnNo;
  DateTime? txnDate;
  String remarks;
  double debitAmount;
  double creditAmount;
  double? runningBalance;
  bool isReviewed;

  ParsedStatementLine({
    this.txnNo = '',
    this.txnDate,
    this.remarks = '',
    this.debitAmount = 0,
    this.creditAmount = 0,
    this.runningBalance,
    required this.isReviewed,
  });
}

/// Parses an uploaded bank statement file (CSV/EXCEL/PDF) into
/// [ParsedStatementLine] rows, using a Bank Statement Format Master's own
/// `column_mapping`/`header_skip_rows`/`date_format`. Runs entirely
/// client-side, on-device — no network call, consistent with the app's
/// offline-first rule. The backend only ever receives already-parsed JSON
/// via fn_save_bank_statement, never a raw file.
class BankStatementParser {
  /// [headerSkipRows] rows are skipped, then the NEXT row is treated as
  /// the column-header row (for CSV/EXCEL — used to resolve
  /// [columnMapping]'s header-name values to column indexes), and every
  /// row after that is real data.
  static List<ParsedStatementLine> parseCsv({
    required String csvContent,
    required int headerSkipRows,
    required Map<String, dynamic> columnMapping,
    required String dateFormat,
  }) {
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csvContent);
    if (rows.length <= headerSkipRows) return [];

    final headerRow = rows[headerSkipRows].map((c) => c.toString().trim()).toList();
    final dataRows = rows.sublist(headerSkipRows + 1);

    final colIndex = _resolveHeaderIndexes(headerRow, columnMapping);
    return _rowsToLines(dataRows.map((r) => r.map((c) => c.toString()).toList()).toList(), colIndex, dateFormat);
  }

  static List<ParsedStatementLine> parseExcel({
    required Uint8List bytes,
    required int headerSkipRows,
    required Map<String, dynamic> columnMapping,
    required String dateFormat,
  }) {
    final workbook = xls.Excel.decodeBytes(bytes);
    final sheet = workbook.tables[workbook.tables.keys.first];
    if (sheet == null || sheet.maxRows <= headerSkipRows) return [];

    final allRows = sheet.rows
        .map((row) => row.map((cell) => cell?.value?.toString() ?? '').toList())
        .toList();
    if (allRows.length <= headerSkipRows) return [];

    final headerRow = allRows[headerSkipRows].map((c) => c.trim()).toList();
    final dataRows = allRows.sublist(headerSkipRows + 1);

    final colIndex = _resolveHeaderIndexes(headerRow, columnMapping);
    return _rowsToLines(dataRows, colIndex, dateFormat);
  }

  /// PDF has no real "column" concept — text is just positioned glyphs.
  /// This extracts text LINE BY LINE (Syncfusion groups glyphs into visual
  /// lines already), then splits each line into "columns" by clustering
  /// text fragments on significant horizontal gaps, sorted left-to-right.
  /// [columnMapping] values here are the COLUMN ORDER (1-based) since
  /// there's no reliable header text to key off. Every resulting row is
  /// flagged isReviewed=false — this is a best-effort extraction, not a
  /// trusted read, by design (see the class doc comment).
  ///
  /// A real bank statement's Remarks column often WRAPS onto its own extra
  /// PDF text line (a physical line with no date/amount at all — just the
  /// tail of the previous row's description). A textLine whose own
  /// txn_date-mapped column does NOT parse as a valid date is treated as a
  /// continuation of the previous row (its text is appended to that row's
  /// `remarks`) rather than a spurious new row — never emitted as its own
  /// line, and never occurring before any real row has been seen.
  static List<ParsedStatementLine> parsePdf({
    required Uint8List bytes,
    required int headerSkipRows,
    required Map<String, dynamic> columnMapping,
    required String dateFormat,
  }) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(document);
      final textLines = extractor.extractTextLines(startPageIndex: 0, endPageIndex: document.pages.count - 1);

      if (textLines.length <= headerSkipRows) return [];
      final dataLines = textLines.sublist(headerSkipRows);

      final orderIndex = _resolveOrderIndexes(columnMapping);
      final dateColIdx = orderIndex['txn_date'];

      final lines = <ParsedStatementLine>[];
      ParsedStatementLine? lastLine;

      for (final textLine in dataLines) {
        // Sort word fragments left-to-right, then cluster into columns on
        // a horizontal-gap threshold — a plain heuristic, not a real
        // table-structure reader.
        final words = List.of(textLine.wordCollection)..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
        if (words.isEmpty) continue;

        final columns = <String>[];
        var current = StringBuffer(words.first.text);
        var lastRight = words.first.bounds.right;
        const gapThreshold = 12.0;

        for (final w in words.skip(1)) {
          if (w.bounds.left - lastRight > gapThreshold) {
            columns.add(current.toString().trim());
            current = StringBuffer(w.text);
          } else {
            current.write(' ${w.text}');
          }
          lastRight = w.bounds.right;
        }
        columns.add(current.toString().trim());

        if (columns.every((c) => c.isEmpty)) continue;

        final dateCell = (dateColIdx != null && dateColIdx < columns.length) ? columns[dateColIdx] : '';
        final isNewRow = _parseDate(dateCell, dateFormat) != null;

        if (isNewRow || lastLine == null) {
          final line = _rowToLine(columns, orderIndex, dateFormat, isReviewed: false);
          lines.add(line);
          lastLine = line;
        } else {
          final wrapped = columns.where((c) => c.isNotEmpty).join(' ');
          if (wrapped.isNotEmpty) {
            lastLine.remarks = lastLine.remarks.isEmpty ? wrapped : '${lastLine.remarks} $wrapped';
          }
        }
      }
      return lines;
    } finally {
      document.dispose();
    }
  }

  /// Collapses any run of whitespace (including embedded newlines from a
  /// header cell that wraps onto two visual lines, e.g. "Withdrawal\nAmount
  /// (INR)") into a single space, then trims/lowercases. A bare trim only
  /// strips the ends — it would still fail to match "Withdrawal  Amount
  /// (INR)" (double space/newline in the middle) against a Format Master
  /// mapping value typed as "Withdrawal Amount (INR)", silently leaving
  /// that one column unmapped with no error, indistinguishable on screen
  /// from "nothing extracted."
  static String _normalizeHeader(String raw) => raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static Map<String, int> _resolveHeaderIndexes(List<String> headerRow, Map<String, dynamic> mapping) {
    final result = <String, int>{};
    final normalizedHeaderRow = headerRow.map(_normalizeHeader).toList();
    mapping.forEach((key, value) {
      final headerName = value?.toString();
      if (headerName == null || headerName.trim().isEmpty) return;
      final idx = normalizedHeaderRow.indexOf(_normalizeHeader(headerName));
      if (idx >= 0) result[key] = idx;
    });
    return result;
  }

  static Map<String, int> _resolveOrderIndexes(Map<String, dynamic> mapping) {
    final result = <String, int>{};
    mapping.forEach((key, value) {
      final order = int.tryParse(value?.toString() ?? '');
      if (order != null && order >= 1) result[key] = order - 1;
    });
    return result;
  }

  static List<ParsedStatementLine> _rowsToLines(List<List<String>> rows, Map<String, int> colIndex, String dateFormat) {
    final lines = <ParsedStatementLine>[];
    for (final row in rows) {
      if (row.every((c) => c.trim().isEmpty)) continue;
      lines.add(_rowToLine(row, colIndex, dateFormat, isReviewed: true));
    }
    return lines;
  }

  static ParsedStatementLine _rowToLine(List<String> row, Map<String, int> colIndex, String dateFormat, {required bool isReviewed}) {
    String cell(String key) {
      final idx = colIndex[key];
      if (idx == null || idx >= row.length) return '';
      return row[idx].trim();
    }

    double parseAmount(String raw) {
      final cleaned = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
      return double.tryParse(cleaned) ?? 0;
    }

    return ParsedStatementLine(
      txnNo: cell('txn_no'),
      txnDate: _parseDate(cell('txn_date'), dateFormat),
      remarks: cell('remarks'),
      debitAmount: parseAmount(cell('debit')),
      creditAmount: parseAmount(cell('credit')),
      runningBalance: cell('running_balance').isEmpty ? null : parseAmount(cell('running_balance')),
      isReviewed: isReviewed,
    );
  }

  static DateTime? _parseDate(String raw, String format) {
    if (raw.isEmpty) return null;
    final parts = raw.split(RegExp(r'[/\-.]'));
    if (parts.length != 3) return null;
    try {
      switch (format) {
        case 'MM/DD/YYYY':
          return DateTime(int.parse(parts[2]), int.parse(parts[0]), int.parse(parts[1]));
        case 'YYYY-MM-DD':
          return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        case 'DD/MM/YYYY':
        default:
          return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
      }
    } catch (_) {
      return null;
    }
  }
}

/// Bundled single-argument param objects for [compute] — heavy parsing
/// (especially PDF text extraction) is synchronous and CPU-bound, so
/// running it on the main isolate blocks UI repaint entirely (the caller's
/// own "parsing…" spinner would never actually render). `compute()`
/// requires exactly one argument and a top-level/static function
/// reference — these three pairs exist purely for that isolate boundary,
/// not because the parsing logic itself changed.
class CsvOrExcelParseParams {
  final Uint8List? bytes;
  final String? csvContent;
  final int headerSkipRows;
  final Map<String, dynamic> columnMapping;
  final String dateFormat;
  const CsvOrExcelParseParams({
    this.bytes,
    this.csvContent,
    required this.headerSkipRows,
    required this.columnMapping,
    required this.dateFormat,
  });
}

List<ParsedStatementLine> parseCsvIsolate(CsvOrExcelParseParams p) => BankStatementParser.parseCsv(
      csvContent: p.csvContent!,
      headerSkipRows: p.headerSkipRows,
      columnMapping: p.columnMapping,
      dateFormat: p.dateFormat,
    );

List<ParsedStatementLine> parseExcelIsolate(CsvOrExcelParseParams p) => BankStatementParser.parseExcel(
      bytes: p.bytes!,
      headerSkipRows: p.headerSkipRows,
      columnMapping: p.columnMapping,
      dateFormat: p.dateFormat,
    );

List<ParsedStatementLine> parsePdfIsolate(CsvOrExcelParseParams p) => BankStatementParser.parsePdf(
      bytes: p.bytes!,
      headerSkipRows: p.headerSkipRows,
      columnMapping: p.columnMapping,
      dateFormat: p.dateFormat,
    );

/// Generic print-template engine — shared data model.
///
/// One template shape serves every document type (Purchase Order, Finance
/// Voucher today; GRN/Quotation/Invoice/POS Receipt later) and both paper
/// families (A4/Letter canvas documents, 58mm/80mm receipt rolls). See
/// backend/migrations/043_print_templates.sql for the persisted shape this
/// mirrors, and print_engine.dart for how a template + a document map
/// become PDF bytes.
///
/// A "document" fed into the engine is a plain `Map<String, dynamic>` with
/// this contract (every screen's print handler builds this shape):
///   {
///     'company':  {...companyDetailsProvider fields, e.g. company_name, logo...},
///     'header':   {...flat doc-type-specific fields, e.g. order_no, status...},
///     'lines':    [ {...one flat map per row...}, ... ],
///     'charges':  [ {...}, ... ]        // optional, doc-type-specific
///     'paymentTerms': [ {...}, ... ]    // optional, doc-type-specific
///     'totals':   {...},
///     'signatures': {...},              // optional
///   }
library print_models;

enum PaperProfile { a4, letter, receipt58mm, receipt80mm }

extension PaperProfileCodec on PaperProfile {
  static PaperProfile fromDb(String s) => switch (s) {
    'LETTER'       => PaperProfile.letter,
    'RECEIPT_58MM' => PaperProfile.receipt58mm,
    'RECEIPT_80MM' => PaperProfile.receipt80mm,
    _              => PaperProfile.a4,
  };

  String toDb() => switch (this) {
    PaperProfile.a4          => 'A4',
    PaperProfile.letter      => 'LETTER',
    PaperProfile.receipt58mm => 'RECEIPT_58MM',
    PaperProfile.receipt80mm => 'RECEIPT_80MM',
  };

  bool get isReceipt => this == PaperProfile.receipt58mm || this == PaperProfile.receipt80mm;

  /// Physical page width in millimetres — the receipt profiles have no
  /// meaningful height (continuous roll), only width.
  double get widthMm => switch (this) {
    PaperProfile.a4          => 210,
    PaperProfile.letter      => 215.9,
    PaperProfile.receipt58mm => 58,
    PaperProfile.receipt80mm => 80,
  };
}

enum PrintElementType { text, field, image, table, line, rect, barcode, watermark }

enum PrintAlign { left, center, right }

enum PrintDataFormat { text, number, currency, date }

enum PrintBarcodeFormat { code128, qr }

PrintAlign _alignFromJson(String? s) => switch (s) {
  'center' => PrintAlign.center,
  'right'  => PrintAlign.right,
  _        => PrintAlign.left,
};

PrintDataFormat _formatFromJson(String? s) => switch (s) {
  'number'   => PrintDataFormat.number,
  'currency' => PrintDataFormat.currency,
  'date'     => PrintDataFormat.date,
  _          => PrintDataFormat.text,
};

class PrintFont {
  final double size;
  final bool bold;
  final bool italic;
  final PrintAlign align;
  final String colorHex;

  const PrintFont({
    this.size = 10,
    this.bold = false,
    this.italic = false,
    this.align = PrintAlign.left,
    this.colorHex = '#000000',
  });

  factory PrintFont.fromJson(Map<String, dynamic> j) => PrintFont(
    size:     (j['size'] as num?)?.toDouble() ?? 10,
    bold:     j['bold'] as bool? ?? false,
    italic:   j['italic'] as bool? ?? false,
    align:    _alignFromJson(j['align'] as String?),
    colorHex: j['color'] as String? ?? '#000000',
  );

  Map<String, dynamic> toJson() => {
    'size': size, 'bold': bold, 'italic': italic, 'align': align.name, 'color': colorHex,
  };
}

/// One column of a [PrintElementType.table] element. `bind` is resolved
/// against each row map in the bound list (not a dotted path against the
/// whole document — rows are already the row map).
class PrintTableColumn {
  final String bind;
  final String label;
  final double width; // mm on canvas profiles; ignored (auto) on receipt profiles
  final PrintAlign align;
  final PrintDataFormat format;

  const PrintTableColumn({
    required this.bind,
    required this.label,
    this.width = 30,
    this.align = PrintAlign.left,
    this.format = PrintDataFormat.text,
  });

  factory PrintTableColumn.fromJson(Map<String, dynamic> j) => PrintTableColumn(
    bind:   j['bind'] as String,
    label:  j['label'] as String? ?? '',
    width:  (j['width'] as num?)?.toDouble() ?? 30,
    align:  _alignFromJson(j['align'] as String?),
    format: _formatFromJson(j['format'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'bind': bind, 'label': label, 'width': width, 'align': align.name, 'format': format.name,
  };
}

/// Show/hide an element based on one field in the document — e.g. the DRAFT
/// watermark only when `header.status` isn't APPROVED. Deliberately simple
/// (one field, equals/notEquals) rather than a general expression language;
/// extend later if a real template needs more than this.
class PrintCondition {
  final String field;
  final String? equals;
  final String? notEquals;

  const PrintCondition({required this.field, this.equals, this.notEquals});

  factory PrintCondition.fromJson(Map<String, dynamic> j) => PrintCondition(
    field:     j['field'] as String,
    equals:    j['equals'] as String?,
    notEquals: j['notEquals'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'field': field,
    if (equals != null) 'equals': equals,
    if (notEquals != null) 'notEquals': notEquals,
  };

  bool evaluate(Map<String, dynamic> document) {
    final value = resolveScalar(document, field)?.toString();
    if (equals != null) return value == equals;
    if (notEquals != null) return value != notEquals;
    return true;
  }
}

/// One positioned (canvas) or stacked (flow) item on the page.
class PrintElement {
  final String id;
  final PrintElementType type;

  // Canvas positioning, millimetres from the page's top-left. Ignored by
  // the flow/receipt renderer, which stacks elements in list order instead.
  final double x, y, w, h;

  final String? text;   // literal text — type=text, or watermark caption
  final String? bind;   // data-binding path — type=field/image/barcode/table
  final String? label;  // optional prefix, e.g. "PO No: " — type=field
  final PrintFont font;

  final List<PrintTableColumn> columns; // type=table
  final bool showHeader;                // type=table

  final PrintBarcodeFormat barcodeFormat; // type=barcode

  final PrintCondition? showWhen; // any element type — most useful on watermark

  const PrintElement({
    required this.id,
    required this.type,
    this.x = 0,
    this.y = 0,
    this.w = 50,
    this.h = 10,
    this.text,
    this.bind,
    this.label,
    this.font = const PrintFont(),
    this.columns = const [],
    this.showHeader = true,
    this.barcodeFormat = PrintBarcodeFormat.code128,
    this.showWhen,
  });

  factory PrintElement.fromJson(Map<String, dynamic> j) => PrintElement(
    id:            j['id'] as String,
    type:          PrintElementType.values.byName(j['type'] as String),
    x:             (j['x'] as num?)?.toDouble() ?? 0,
    y:             (j['y'] as num?)?.toDouble() ?? 0,
    w:             (j['w'] as num?)?.toDouble() ?? 50,
    h:             (j['h'] as num?)?.toDouble() ?? 10,
    text:          j['text'] as String?,
    bind:          j['bind'] as String?,
    label:         j['label'] as String?,
    font:          j['font'] != null ? PrintFont.fromJson(j['font'] as Map<String, dynamic>) : const PrintFont(),
    columns:       (j['columns'] as List<dynamic>? ?? [])
        .map((c) => PrintTableColumn.fromJson(c as Map<String, dynamic>)).toList(),
    showHeader:    j['showHeader'] as bool? ?? true,
    barcodeFormat: j['barcodeFormat'] == 'qr' ? PrintBarcodeFormat.qr : PrintBarcodeFormat.code128,
    showWhen:      j['showWhen'] != null ? PrintCondition.fromJson(j['showWhen'] as Map<String, dynamic>) : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'type': type.name, 'x': x, 'y': y, 'w': w, 'h': h,
    if (text != null) 'text': text,
    if (bind != null) 'bind': bind,
    if (label != null) 'label': label,
    'font': font.toJson(),
    if (columns.isNotEmpty) 'columns': columns.map((c) => c.toJson()).toList(),
    'showHeader': showHeader,
    'barcodeFormat': barcodeFormat.name,
    if (showWhen != null) 'showWhen': showWhen!.toJson(),
  };
}

class PrintTemplate {
  final String? id;
  final String documentType;
  final String templateName;
  final PaperProfile paperProfile;
  final bool isDefault;
  final List<PrintElement> elements;

  const PrintTemplate({
    this.id,
    required this.documentType,
    required this.templateName,
    required this.paperProfile,
    this.isDefault = false,
    required this.elements,
  });

  factory PrintTemplate.fromJson(Map<String, dynamic> j) {
    final layout = j['layout'] as Map<String, dynamic>;
    return PrintTemplate(
      id:            j['id'] as String?,
      documentType:  j['document_type'] as String,
      templateName:  j['template_name'] as String,
      paperProfile:  PaperProfileCodec.fromDb(j['paper_profile'] as String),
      isDefault:     j['is_default'] as bool? ?? false,
      elements:      (layout['elements'] as List<dynamic>? ?? [])
          .map((e) => PrintElement.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'document_type': documentType,
    'template_name': templateName,
    'paper_profile': paperProfile.toDb(),
    'is_default': isDefault,
    'layout': {'elements': elements.map((e) => e.toJson()).toList()},
  };
}

/// Resolves a dotted path (e.g. 'header.order_no', 'company.company_name')
/// against a document map. Does not walk into lists — a `bind` on a table
/// element names the list itself (e.g. 'lines'); each row's own fields are
/// then resolved directly against that row map, not through this function.
dynamic resolveScalar(Map<String, dynamic> document, String path) {
  dynamic current = document;
  for (final segment in path.split('.')) {
    if (current is Map) {
      current = current[segment];
    } else {
      return null;
    }
  }
  return current;
}

String formatPrintValue(dynamic value, PrintDataFormat format) {
  if (value == null) return '';
  switch (format) {
    case PrintDataFormat.currency:
      final n = value is num ? value : (num.tryParse(value.toString()) ?? 0);
      return n.toStringAsFixed(2);
    case PrintDataFormat.number:
      final n = value is num ? value : (num.tryParse(value.toString()) ?? 0);
      return n.toString();
    case PrintDataFormat.date:
    case PrintDataFormat.text:
      return value.toString();
  }
}

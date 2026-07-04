import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/printing/print_engine.dart';
import '../../../../core/printing/print_field_registry.dart';
import '../../../../core/printing/print_models.dart';
import '../../../../core/printing/print_sample_data.dart';
import '../../../../core/printing/print_template_provider.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

/// Mutable working copy of a [PrintTableColumn] — the immutable model has no
/// in-place setters, and the designer edits one field at a time via setState.
class _ColumnDraft {
  String bind;
  String label;
  double width;
  PrintAlign align;
  PrintDataFormat format;

  _ColumnDraft({
    this.bind = '',
    this.label = '',
    this.width = 30,
    this.align = PrintAlign.left,
    this.format = PrintDataFormat.text,
  });

  factory _ColumnDraft.fromColumn(PrintTableColumn c) => _ColumnDraft(
        bind: c.bind, label: c.label, width: c.width, align: c.align, format: c.format,
      );

  PrintTableColumn toColumn() =>
      PrintTableColumn(bind: bind, label: label, width: width, align: align, format: format);
}

/// Mutable working copy of a [PrintElement]. `x`/`y` are deliberately not
/// tracked here — they're derived from each element's row/column position in
/// the designer's `_rows` grid at save time (see `_rowsToElements`), matching
/// the row-grouping semantics documented on [PrintElement].
class _ElementDraft {
  static int _counter = 0;

  final String id;
  PrintElementType type;
  double w;
  double h;
  String text;
  String? bind;
  String label;
  double fontSize;
  bool bold;
  bool italic;
  PrintAlign align;
  String colorHex;
  PrintDataFormat format;
  List<_ColumnDraft> columns;
  bool showHeader;
  PrintBarcodeFormat barcodeFormat;
  bool hasCondition;
  String? condField;
  bool condIsNotEquals;
  String condValue;

  _ElementDraft({
    required this.id,
    required this.type,
    this.w = 50,
    this.h = 10,
    this.text = '',
    this.bind,
    this.label = '',
    this.fontSize = 10,
    this.bold = false,
    this.italic = false,
    this.align = PrintAlign.left,
    this.colorHex = '#000000',
    this.format = PrintDataFormat.text,
    List<_ColumnDraft>? columns,
    this.showHeader = true,
    this.barcodeFormat = PrintBarcodeFormat.code128,
    this.hasCondition = false,
    this.condField,
    this.condIsNotEquals = false,
    this.condValue = '',
  }) : columns = columns ?? [];

  factory _ElementDraft.fromElement(PrintElement el) => _ElementDraft(
        id: el.id,
        type: el.type,
        w: el.w,
        h: el.h,
        text: el.text ?? '',
        bind: el.bind,
        label: el.label ?? '',
        fontSize: el.font.size,
        bold: el.font.bold,
        italic: el.font.italic,
        align: el.font.align,
        colorHex: el.font.colorHex,
        format: el.format,
        columns: el.columns.map((c) => _ColumnDraft.fromColumn(c)).toList(),
        showHeader: el.showHeader,
        barcodeFormat: el.barcodeFormat,
        hasCondition: el.showWhen != null,
        condField: el.showWhen?.field,
        condIsNotEquals: el.showWhen?.notEquals != null,
        condValue: el.showWhen?.notEquals ?? el.showWhen?.equals ?? '',
      );

  factory _ElementDraft.blank(PrintElementType type) => _ElementDraft(
        id: 'new_${DateTime.now().microsecondsSinceEpoch}_${_counter++}',
        type: type,
        text: type == PrintElementType.text
            ? 'New Text'
            : type == PrintElementType.watermark
                ? 'DRAFT — NOT APPROVED'
                : '',
      );

  PrintElement toElement(double x, double y) => PrintElement(
        id: id,
        type: type,
        x: x,
        y: y,
        w: w,
        h: h,
        text: text.isEmpty ? null : text,
        bind: bind,
        label: label.isEmpty ? null : label,
        font: PrintFont(size: fontSize, bold: bold, italic: italic, align: align, colorHex: colorHex),
        format: format,
        columns: columns.map((c) => c.toColumn()).toList(),
        showHeader: showHeader,
        barcodeFormat: barcodeFormat,
        showWhen: hasCondition && condField != null
            ? PrintCondition(
                field: condField!,
                equals: condIsNotEquals ? null : condValue,
                notEquals: condIsNotEquals ? condValue : null,
              )
            : null,
      );
}

/// Phase 2 of the generic print engine — a visual editor for
/// ric_print_templates rows. Elements are grouped into rows (mirrors
/// pdf_canvas_renderer.dart's row-grouping model exactly): a row can hold one
/// or more elements shown side by side; rows stack top to bottom. A brand-new
/// template starts from the built-in Dart default for its document type
/// (defaultTemplateFor) so an admin edits a proven-good layout, not a blank
/// page.
class PrintTemplateDesignerScreen extends ConsumerStatefulWidget {
  final String? templateId;
  final String? documentType;
  const PrintTemplateDesignerScreen({super.key, this.templateId, this.documentType});

  @override
  ConsumerState<PrintTemplateDesignerScreen> createState() => _PrintTemplateDesignerScreenState();
}

class _PrintTemplateDesignerScreenState extends ConsumerState<PrintTemplateDesignerScreen>
    with ScreenPermissionMixin<PrintTemplateDesignerScreen> {
  @override
  String get screenName => RouteNames.printTemplates;

  static const _colorChoices = {
    '#000000': 'Black',
    '#1B3A6B': 'Brand Navy',
    '#D4860B': 'Brand Amber',
    '#2E7D32': 'Green',
    '#C62828': 'Red',
    '#6B7280': 'Grey',
  };

  String? _templateId;
  late String _documentType;
  final _nameCtrl = TextEditingController();
  PaperProfile _paperProfile = PaperProfile.a4;
  bool _isDefault = false;
  List<List<_ElementDraft>> _rows = [];
  String? _selectedElementId;

  bool _loading = true;
  bool _saving = false;
  bool _printing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _templateId = widget.templateId;
    _documentType = widget.documentType ?? PrintFieldRegistry.documentTypes.first;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      PrintTemplate template;
      if (_templateId != null) {
        final res = await DioClient.instance.get('/ric_print_templates', queryParameters: {
          'id': 'eq.$_templateId', 'select': '*', 'limit': '1',
        });
        final list = res.data as List;
        if (list.isEmpty) throw Exception('Template not found.');
        template = PrintTemplate.fromJson(list.first as Map<String, dynamic>);
        _documentType = template.documentType;
      } else {
        final fallback = defaultTemplateFor(_documentType);
        template = PrintTemplate(
          documentType: fallback.documentType,
          templateName: 'New Template',
          paperProfile: fallback.paperProfile,
          isDefault: false,
          elements: fallback.elements,
        );
      }
      _nameCtrl.text = template.templateName;
      _paperProfile = template.paperProfile;
      _isDefault = template.isDefault;
      _elementsToRows(template.elements);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load template: $e'; });
    }
  }

  void _elementsToRows(List<PrintElement> elements) {
    final byY = <double, List<PrintElement>>{};
    for (final el in elements) {
      byY.putIfAbsent(el.y, () => []).add(el);
    }
    final sortedYs = byY.keys.toList()..sort();
    _rows = sortedYs.map((y) {
      final row = byY[y]!..sort((a, b) => a.x.compareTo(b.x));
      return row.map((el) => _ElementDraft.fromElement(el)).toList();
    }).toList();
  }

  List<PrintElement> _rowsToElements() {
    final result = <PrintElement>[];
    for (var y = 0; y < _rows.length; y++) {
      final row = _rows[y];
      for (var x = 0; x < row.length; x++) {
        result.add(row[x].toElement(x.toDouble(), y.toDouble()));
      }
    }
    return result;
  }

  // ---- row/element mutation ----

  void _addRow() {
    final el = _ElementDraft.blank(PrintElementType.text);
    setState(() {
      _rows.add([el]);
      _selectedElementId = el.id;
    });
  }

  void _addElementToRow(int rowIndex) {
    final el = _ElementDraft.blank(PrintElementType.text);
    setState(() {
      _rows[rowIndex].add(el);
      _selectedElementId = el.id;
    });
  }

  void _removeElement(int rowIndex, _ElementDraft el) {
    setState(() {
      _rows[rowIndex].remove(el);
      if (_rows[rowIndex].isEmpty) _rows.removeAt(rowIndex);
      if (_selectedElementId == el.id) _selectedElementId = null;
    });
  }

  void _deleteRow(int rowIndex) {
    setState(() {
      final removedIds = _rows[rowIndex].map((e) => e.id).toSet();
      _rows.removeAt(rowIndex);
      if (removedIds.contains(_selectedElementId)) _selectedElementId = null;
    });
  }

  void _moveRow(int rowIndex, int delta) {
    final target = rowIndex + delta;
    if (target < 0 || target >= _rows.length) return;
    setState(() {
      final row = _rows.removeAt(rowIndex);
      _rows.insert(target, row);
    });
  }

  // ---- save / preview ----

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Template name is required.', color: AppColors.negative);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      final elements = _rowsToElements();
      if (_isDefault) {
        // Partial unique index rejects two TRUE rows for the same document
        // type at once — clear any existing default first, as a separate
        // request (mirrors print_template_list_screen.dart's _setDefault).
        await DioClient.instance.patch('/ric_print_templates',
            queryParameters: {
              'client_id': 'eq.${session.clientId}',
              'company_id': 'eq.${session.companyId}',
              'document_type': 'eq.$_documentType',
              'is_default': 'eq.true',
              if (_templateId != null) 'id': 'neq.$_templateId',
            },
            data: {'is_default': false, 'updated_by': session.userId},
            options: Options(headers: {'Prefer': 'return=minimal'}));
      }
      if (_templateId == null) {
        final newId = const Uuid().v4();
        await DioClient.instance.post('/ric_print_templates',
            data: {
              'id': newId,
              'client_id': session.clientId,
              'company_id': session.companyId,
              'document_type': _documentType,
              'template_name': name,
              'paper_profile': _paperProfile.toDb(),
              'is_default': _isDefault,
              'layout': {'elements': elements.map((e) => e.toJson()).toList()},
              'created_by': session.userId,
            },
            options: Options(headers: {'Prefer': 'return=minimal'}));
        _templateId = newId;
      } else {
        await DioClient.instance.patch('/ric_print_templates',
            queryParameters: {'id': 'eq.$_templateId'},
            data: {
              'template_name': name,
              'paper_profile': _paperProfile.toDb(),
              'is_default': _isDefault,
              'layout': {'elements': elements.map((e) => e.toJson()).toList()},
              'updated_by': session.userId,
            },
            options: Options(headers: {'Prefer': 'return=minimal'}));
      }
      if (mounted) {
        setState(() => _saving = false);
        _showSnack('Template saved.', color: AppColors.positive);
      }
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed.';
      if (mounted) setState(() => _saving = false);
      if (mounted) _showSnack(msg, color: AppColors.negative);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      if (mounted) _showSnack('Unexpected error: $e', color: AppColors.negative);
    }
  }

  Future<void> _preview() async {
    setState(() => _printing = true);
    try {
      final draft = PrintTemplate(
        id: _templateId,
        documentType: _documentType,
        templateName: _nameCtrl.text.trim().isEmpty ? 'Preview' : _nameCtrl.text.trim(),
        paperProfile: _paperProfile,
        isDefault: _isDefault,
        elements: _rowsToElements(),
      );
      await PrintEngine.printDocument(
        template: draft,
        document: PrintSampleData.forDocumentType(_documentType),
        filename: 'template_preview.pdf',
      );
    } catch (e) {
      if (mounted) _showSnack('Preview failed: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;

    if (_loading) {
      return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()));
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(isMobile, offline),
              const SizedBox(height: 16),
              if (offline) ...[const OfflineBanner(), const SizedBox(height: 16)],
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                ),
                const SizedBox(height: 20),
              ],
              _buildSettingsCard(isMobile),
              const SizedBox(height: 20),
              const Text('Layout',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text(
                'Each row can hold one or more elements shown side by side. Tap an element to edit it.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _rows.length; i++) _buildRowCard(i),
              OutlinedButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Row'),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isMobile, bool offline) {
    final titleBlock = const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Template Designer', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      SizedBox(height: 4),
      Text('Design a custom print layout — use Preview to see it with sample data before saving.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]);
    final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
      OutlinedButton.icon(
        onPressed: _printing ? null : _preview,
        icon: _printing
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.visibility_outlined, size: 16),
        label: const Text('Preview'),
      ),
      const SizedBox(width: 8),
      if (canAdd || canEdit)
        ElevatedButton.icon(
          onPressed: (_saving || offline) ? null : _save,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save'),
        ),
    ]);
    if (isMobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [titleBlock, const SizedBox(height: 12), buttons]);
    }
    return Row(children: [Expanded(child: titleBlock), buttons]);
  }

  Widget _buildSettingsCard(bool isMobile) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: isMobile ? double.infinity : 260,
              child: TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10), labelText: 'Template Name'),
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10), labelText: 'Document Type'),
                isExpanded: true,
                initialValue: _documentType,
                items: PrintFieldRegistry.documentTypes
                    .map((d) => DropdownMenuItem(value: d, child: Text(PrintFieldRegistry.documentTypeLabel(d))))
                    .toList(),
                onChanged: _templateId != null
                    ? null
                    : (v) { if (v != null) setState(() { _documentType = v; _selectedElementId = null; }); },
              ),
            ),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<PaperProfile>(
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10), labelText: 'Paper Profile'),
                isExpanded: true,
                initialValue: _paperProfile,
                items: PaperProfile.values
                    .map((p) => DropdownMenuItem(value: p, child: Text(_paperProfileLabel(p))))
                    .toList(),
                onChanged: (v) { if (v != null) setState(() => _paperProfile = v); },
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: _isDefault, onChanged: (v) => setState(() => _isDefault = v ?? false)),
              const Text('Set as default for this document type', style: TextStyle(fontSize: 13)),
            ]),
          ],
        ),
      ),
    );
  }

  String _paperProfileLabel(PaperProfile p) => switch (p) {
        PaperProfile.a4 => 'A4',
        PaperProfile.letter => 'Letter',
        PaperProfile.receipt58mm => 'Receipt (58mm)',
        PaperProfile.receipt80mm => 'Receipt (80mm)',
      };

  Widget _buildRowCard(int rowIndex) {
    final row = _rows[rowIndex];
    final selected = row.where((e) => e.id == _selectedElementId).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Row ${rowIndex + 1}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 16),
                tooltip: 'Move up',
                onPressed: rowIndex > 0 ? () => _moveRow(rowIndex, -1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward, size: 16),
                tooltip: 'Move down',
                onPressed: rowIndex < _rows.length - 1 ? () => _moveRow(rowIndex, 1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.add_box_outlined, size: 16),
                tooltip: 'Add element to this row',
                onPressed: () => _addElementToRow(rowIndex),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.negative),
                tooltip: 'Delete row',
                onPressed: () => _deleteRow(rowIndex),
              ),
            ]),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: row.map((el) => _buildElementChip(rowIndex, el)).toList(),
            ),
            if (selected.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildElementEditor(selected.first),
            ],
          ],
        ),
      ),
    );
  }

  IconData _iconFor(PrintElementType t) => switch (t) {
        PrintElementType.text => Icons.short_text,
        PrintElementType.field => Icons.data_object,
        PrintElementType.image => Icons.image_outlined,
        PrintElementType.table => Icons.table_chart_outlined,
        PrintElementType.line => Icons.horizontal_rule,
        PrintElementType.rect => Icons.crop_square,
        PrintElementType.barcode => Icons.qr_code_2,
        PrintElementType.watermark => Icons.water_drop_outlined,
      };

  String _chipLabel(_ElementDraft el) {
    switch (el.type) {
      case PrintElementType.text:
        return el.text.isEmpty ? 'Text' : '"${el.text}"';
      case PrintElementType.field:
        final def = PrintFieldRegistry.scalarFields(_documentType).where((f) => f.path == el.bind).firstOrNull;
        return 'Field: ${def?.label ?? el.bind ?? '(unbound)'}';
      case PrintElementType.image:
        return 'Image: ${el.bind ?? '(unbound)'}';
      case PrintElementType.table:
        return 'Table: ${el.bind ?? '(unbound)'}';
      case PrintElementType.line:
        return 'Divider';
      case PrintElementType.rect:
        return 'Box';
      case PrintElementType.barcode:
        return 'Barcode: ${el.bind ?? '(unbound)'}';
      case PrintElementType.watermark:
        return 'Watermark: ${el.text.isEmpty ? '(text)' : el.text}';
    }
  }

  Widget _buildElementChip(int rowIndex, _ElementDraft el) {
    final isSelected = _selectedElementId == el.id;
    return FilterChip(
      avatar: Icon(_iconFor(el.type), size: 16, color: isSelected ? AppColors.textOnPrimary : AppColors.textSecondary),
      label: Text(_chipLabel(el), overflow: TextOverflow.ellipsis),
      selected: isSelected,
      selectedColor: AppColors.primary,
      labelStyle: TextStyle(fontSize: 12, color: isSelected ? AppColors.textOnPrimary : AppColors.textPrimary),
      onSelected: (_) => setState(() => _selectedElementId = isSelected ? null : el.id),
      onDeleted: () => _removeElement(rowIndex, el),
      deleteIcon: Icon(Icons.close, size: 15, color: isSelected ? AppColors.textOnPrimary : AppColors.textSecondary),
    );
  }

  bool _usesFont(PrintElementType t) =>
      t == PrintElementType.text || t == PrintElementType.field || t == PrintElementType.watermark;

  Widget _buildElementEditor(_ElementDraft el) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<PrintElementType>(
                key: ValueKey('${el.id}_type'),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Element Type'),
                isExpanded: true,
                initialValue: el.type,
                items: PrintElementType.values.map((t) => DropdownMenuItem(value: t, child: Text(_typeLabel(t)))).toList(),
                onChanged: (v) { if (v != null) setState(() => el.type = v); },
              ),
            ),
            SizedBox(
              width: 100,
              child: TextFormField(
                key: ValueKey('${el.id}_w'),
                initialValue: el.w.toStringAsFixed(0),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Width'),
                onChanged: (v) => setState(() => el.w = double.tryParse(v) ?? el.w),
              ),
            ),
            if (el.type == PrintElementType.image || el.type == PrintElementType.rect || el.type == PrintElementType.barcode)
              SizedBox(
                width: 100,
                child: TextFormField(
                  key: ValueKey('${el.id}_h'),
                  initialValue: el.h.toStringAsFixed(0),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Height'),
                  onChanged: (v) => setState(() => el.h = double.tryParse(v) ?? el.h),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          ..._typeSpecificFields(el),
          if (_usesFont(el.type)) ...[
            const SizedBox(height: 10),
            _buildFontControls(el),
          ],
          const SizedBox(height: 10),
          _buildConditionEditor(el),
        ],
      ),
    );
  }

  String _typeLabel(PrintElementType t) => switch (t) {
        PrintElementType.text => 'Text (fixed)',
        PrintElementType.field => 'Field (bound)',
        PrintElementType.image => 'Image',
        PrintElementType.table => 'Table',
        PrintElementType.line => 'Divider Line',
        PrintElementType.rect => 'Box',
        PrintElementType.barcode => 'Barcode / QR',
        PrintElementType.watermark => 'Watermark',
      };

  List<Widget> _typeSpecificFields(_ElementDraft el) {
    switch (el.type) {
      case PrintElementType.text:
        return [
          TextFormField(
            key: ValueKey('${el.id}_text'),
            initialValue: el.text,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Text'),
            onChanged: (v) => setState(() => el.text = v),
          ),
        ];
      case PrintElementType.watermark:
        return [
          TextFormField(
            key: ValueKey('${el.id}_text'),
            initialValue: el.text,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Watermark Text'),
            onChanged: (v) => setState(() => el.text = v),
          ),
        ];
      case PrintElementType.field:
        return [
          Wrap(spacing: 12, runSpacing: 12, children: [
            _bindDropdown(el, PrintFieldRegistry.scalarFields(_documentType), width: 240),
            SizedBox(
              width: 200,
              child: TextFormField(
                key: ValueKey('${el.id}_label'),
                initialValue: el.label,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Prefix Label (optional)'),
                onChanged: (v) => setState(() => el.label = v),
              ),
            ),
            _formatDropdown(el),
          ]),
        ];
      case PrintElementType.image:
        return [_bindDropdown(el, PrintFieldRegistry.scalarFields(_documentType), width: 240)];
      case PrintElementType.barcode:
        return [
          Wrap(spacing: 12, runSpacing: 12, children: [
            _bindDropdown(el, PrintFieldRegistry.scalarFields(_documentType), width: 240),
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<PrintBarcodeFormat>(
                key: ValueKey('${el.id}_barcodefmt'),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Format'),
                isExpanded: true,
                initialValue: el.barcodeFormat,
                items: const [
                  DropdownMenuItem(value: PrintBarcodeFormat.code128, child: Text('Barcode (Code128)')),
                  DropdownMenuItem(value: PrintBarcodeFormat.qr, child: Text('QR Code')),
                ],
                onChanged: (v) { if (v != null) setState(() => el.barcodeFormat = v); },
              ),
            ),
          ]),
        ];
      case PrintElementType.table:
        return [_buildTableEditor(el)];
      case PrintElementType.line:
      case PrintElementType.rect:
        return const [];
    }
  }

  Widget _bindDropdown(_ElementDraft el, List<PrintFieldDef> fields, {double width = 220}) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        key: ValueKey('${el.id}_bind'),
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Bind To'),
        isExpanded: true,
        initialValue: fields.any((f) => f.path == el.bind) ? el.bind : null,
        items: fields.map((f) => DropdownMenuItem(value: f.path, child: Text(f.label))).toList(),
        onChanged: (v) => setState(() => el.bind = v),
      ),
    );
  }

  Widget _formatDropdown(_ElementDraft el) {
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<PrintDataFormat>(
        key: ValueKey('${el.id}_format'),
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Format'),
        isExpanded: true,
        initialValue: el.format,
        items: const [
          DropdownMenuItem(value: PrintDataFormat.text, child: Text('Text')),
          DropdownMenuItem(value: PrintDataFormat.number, child: Text('Number')),
          DropdownMenuItem(value: PrintDataFormat.currency, child: Text('Currency')),
          DropdownMenuItem(value: PrintDataFormat.date, child: Text('Date')),
        ],
        onChanged: (v) { if (v != null) setState(() => el.format = v); },
      ),
    );
  }

  Widget _buildTableEditor(_ElementDraft el) {
    final tableNames = PrintFieldRegistry.tableNames(_documentType);
    final rowFields = PrintFieldRegistry.rowFields(_documentType, el.bind ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String>(
              key: ValueKey('${el.id}_tablebind'),
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Bound List'),
              isExpanded: true,
              initialValue: tableNames.contains(el.bind) ? el.bind : null,
              items: tableNames.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setState(() => el.bind = v),
            ),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: el.showHeader, onChanged: (v) => setState(() => el.showHeader = v ?? true)),
            const Text('Show column headers', style: TextStyle(fontSize: 13)),
          ]),
        ]),
        const SizedBox(height: 10),
        for (var i = 0; i < el.columns.length; i++) _buildColumnRow(el, i, rowFields),
        TextButton.icon(
          onPressed: () => setState(() => el.columns.add(_ColumnDraft())),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add Column'),
        ),
      ],
    );
  }

  Widget _buildColumnRow(_ElementDraft el, int colIndex, List<PrintFieldDef> rowFields) {
    final col = el.columns[colIndex];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 190,
          child: DropdownButtonFormField<String>(
            key: ValueKey('${el.id}_col${colIndex}_bind'),
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Column'),
            isExpanded: true,
            initialValue: rowFields.any((f) => f.path == col.bind) ? col.bind : null,
            items: rowFields.map((f) => DropdownMenuItem(value: f.path, child: Text(f.label))).toList(),
            onChanged: (v) => setState(() {
              col.bind = v ?? '';
              final def = rowFields.where((f) => f.path == v).firstOrNull;
              if (def != null && col.label.isEmpty) col.label = def.label;
              if (def != null) col.format = def.suggestedFormat;
            }),
          ),
        ),
        SizedBox(
          width: 130,
          child: TextFormField(
            key: ValueKey('${el.id}_col${colIndex}_label'),
            initialValue: col.label,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Header Label'),
            onChanged: (v) => setState(() => col.label = v),
          ),
        ),
        SizedBox(
          width: 90,
          child: TextFormField(
            key: ValueKey('${el.id}_col${colIndex}_width'),
            initialValue: col.width.toStringAsFixed(0),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Width'),
            onChanged: (v) => setState(() => col.width = double.tryParse(v) ?? col.width),
          ),
        ),
        SizedBox(
          width: 120,
          child: DropdownButtonFormField<PrintAlign>(
            key: ValueKey('${el.id}_col${colIndex}_align'),
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Align'),
            isExpanded: true,
            initialValue: col.align,
            items: const [
              DropdownMenuItem(value: PrintAlign.left, child: Text('Left')),
              DropdownMenuItem(value: PrintAlign.center, child: Text('Center')),
              DropdownMenuItem(value: PrintAlign.right, child: Text('Right')),
            ],
            onChanged: (v) { if (v != null) setState(() => col.align = v); },
          ),
        ),
        SizedBox(
          width: 130,
          child: DropdownButtonFormField<PrintDataFormat>(
            key: ValueKey('${el.id}_col${colIndex}_format'),
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Format'),
            isExpanded: true,
            initialValue: col.format,
            items: const [
              DropdownMenuItem(value: PrintDataFormat.text, child: Text('Text')),
              DropdownMenuItem(value: PrintDataFormat.number, child: Text('Number')),
              DropdownMenuItem(value: PrintDataFormat.currency, child: Text('Currency')),
              DropdownMenuItem(value: PrintDataFormat.date, child: Text('Date')),
            ],
            onChanged: (v) { if (v != null) setState(() => col.format = v); },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
          onPressed: () => setState(() => el.columns.removeAt(colIndex)),
        ),
      ]),
    );
  }

  Widget _buildFontControls(_ElementDraft el) {
    return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: 90,
        child: TextFormField(
          key: ValueKey('${el.id}_fontsize'),
          initialValue: el.fontSize.toStringAsFixed(0),
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Font Size'),
          onChanged: (v) => setState(() => el.fontSize = double.tryParse(v) ?? el.fontSize),
        ),
      ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(value: el.bold, onChanged: (v) => setState(() => el.bold = v ?? false)),
        const Text('Bold', style: TextStyle(fontSize: 13)),
      ]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(value: el.italic, onChanged: (v) => setState(() => el.italic = v ?? false)),
        const Text('Italic', style: TextStyle(fontSize: 13)),
      ]),
      SizedBox(
        width: 130,
        child: DropdownButtonFormField<PrintAlign>(
          key: ValueKey('${el.id}_align'),
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Align'),
          isExpanded: true,
          initialValue: el.align,
          items: const [
            DropdownMenuItem(value: PrintAlign.left, child: Text('Left')),
            DropdownMenuItem(value: PrintAlign.center, child: Text('Center')),
            DropdownMenuItem(value: PrintAlign.right, child: Text('Right')),
          ],
          onChanged: (v) { if (v != null) setState(() => el.align = v); },
        ),
      ),
      SizedBox(
        width: 140,
        child: DropdownButtonFormField<String>(
          key: ValueKey('${el.id}_color'),
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Color'),
          isExpanded: true,
          initialValue: _colorChoices.containsKey(el.colorHex) ? el.colorHex : _colorChoices.keys.first,
          items: _colorChoices.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) { if (v != null) setState(() => el.colorHex = v); },
        ),
      ),
    ]);
  }

  Widget _buildConditionEditor(_ElementDraft el) {
    final fields = PrintFieldRegistry.scalarFields(_documentType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Checkbox(value: el.hasCondition, onChanged: (v) => setState(() => el.hasCondition = v ?? false)),
          const Text('Only show when a field matches a value', style: TextStyle(fontSize: 13)),
        ]),
        if (el.hasCondition)
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                key: ValueKey('${el.id}_condfield'),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Field'),
                isExpanded: true,
                initialValue: fields.any((f) => f.path == el.condField) ? el.condField : null,
                items: fields.map((f) => DropdownMenuItem(value: f.path, child: Text(f.label))).toList(),
                onChanged: (v) => setState(() => el.condField = v),
              ),
            ),
            SizedBox(
              width: 140,
              child: DropdownButtonFormField<bool>(
                key: ValueKey('${el.id}_condop'),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Condition'),
                isExpanded: true,
                initialValue: el.condIsNotEquals,
                items: const [
                  DropdownMenuItem(value: false, child: Text('Equals')),
                  DropdownMenuItem(value: true, child: Text('Not Equals')),
                ],
                onChanged: (v) { if (v != null) setState(() => el.condIsNotEquals = v); },
              ),
            ),
            SizedBox(
              width: 160,
              child: TextFormField(
                key: ValueKey('${el.id}_condvalue'),
                initialValue: el.condValue,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), labelText: 'Value'),
                onChanged: (v) => setState(() => el.condValue = v),
              ),
            ),
          ]),
      ],
    );
  }
}

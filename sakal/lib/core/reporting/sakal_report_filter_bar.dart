import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/dio_client.dart';
import '../providers/master_cache_providers.dart';
import '../theme/app_colors.dart';
import '../widgets/sakal_reflow_row.dart';
import '../../features/finance/presentation/widgets/finance_account_picker.dart';
import 'report_models.dart';

/// Generic filter bar, built entirely from a report's own declared
/// [ReportFilter] rows — the shared widget the reporting engine needed
/// and nothing in the app had before (see
/// sakal/docs/reporting_engine_design.md). Renders the right input per
/// [ReportFilter.filterType], collects values into a
/// `Map<String,dynamic>` keyed by `filterKey`, and calls [onApply].
///
/// TEXT filters debounce (~350ms) rather than re-running the report on
/// every keystroke; every other filter type applies immediately on
/// change — same convention noted in the design doc.
class SakalReportFilterBar extends ConsumerStatefulWidget {
  final List<ReportFilter> filters;
  final Map<String, dynamic> initialValues;
  final ValueChanged<Map<String, dynamic>> onApply;

  const SakalReportFilterBar({
    super.key,
    required this.filters,
    required this.initialValues,
    required this.onApply,
  });

  @override
  ConsumerState<SakalReportFilterBar> createState() => _SakalReportFilterBarState();
}

class _SakalReportFilterBarState extends ConsumerState<SakalReportFilterBar> {
  late Map<String, dynamic> _values;
  Timer? _debounce;
  final Map<String, List<Map<String, dynamic>>> _lookupOptionsCache = {};

  @override
  void initState() {
    super.initState();
    _values = Map<String, dynamic>.from(widget.initialValues);
    for (final f in widget.filters) {
      if (f.filterType == 'DROPDOWN_LOOKUP' || f.filterType == 'ACCOUNT_PICKER' || f.filterType == 'PRODUCT_PICKER') {
        _loadLookupOptions(f);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadLookupOptions(ReportFilter f) async {
    if (f.lookupSource == null) return;
    try {
      final res = await DioClient.instance.get('/${f.lookupSource}', queryParameters: {
        'select': 'id,${f.lookupLabelColumn ?? 'name'}',
        'order': '${f.lookupLabelColumn ?? 'name'}.asc',
      });
      if (!mounted) return;
      setState(() => _lookupOptionsCache[f.filterKey] = List<Map<String, dynamic>>.from(res.data as List));
    } catch (_) {
      // A broken lookup filter degrades to "no options" rather than
      // blocking the rest of the filter bar / the report itself.
    }
  }

  void _set(String key, dynamic value, {bool debounce = false}) {
    if (debounce) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), () {
        setState(() => _values[key] = value);
        widget.onApply(_values);
      });
      return;
    }
    setState(() => _values[key] = value);
    widget.onApply(_values);
  }

  Future<void> _pickDate(String key, {required bool isFrom}) async {
    final current = _values[key] as Map<String, DateTime>? ?? {};
    final initial = (isFrom ? current['from'] : current['to']) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final updated = {...current, if (isFrom) 'from': picked else 'to': picked};
    _set(key, updated);
  }

  String _fmtDate(DateTime? d) =>
      d == null ? 'Any' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // Relative weight within a row — DATE_RANGE is really two sub-fields
  // side by side, so it needs roughly double a plain field's width to look
  // right; everything else is treated as equal.
  double _flexFor(ReportFilter f) => f.filterType == 'DATE_RANGE' ? 2.0 : 1.0;

  @override
  Widget build(BuildContext context) {
    if (widget.filters.isEmpty) return const SizedBox.shrink();
    // Only fetched when a filter actually needs it — accountsProvider is
    // already session/offline-aware (master_cache_providers.dart), so this
    // reuses the same cached fetch every other Finance account picker uses
    // rather than hand-rolling a second one here.
    final needsAccountPicker = widget.filters.any((f) => f.filterType == 'FINANCE_ACCOUNT_PICKER');
    final postableAccounts = needsAccountPicker
        ? (ref.watch(accountsProvider).valueOrNull ?? const <Map<String, dynamic>>[])
            .where((a) => a['posting_allowed'] == true)
            .toList()
        : const <Map<String, dynamic>>[];
    return SakalReflowRow(
      flexWeights: widget.filters.map(_flexFor).toList(),
      children: widget.filters.map((f) => _buildField(f, postableAccounts)).toList(),
    );
  }

  Widget _buildField(ReportFilter f, List<Map<String, dynamic>> postableAccounts) {
    switch (f.filterType) {
      case 'DATE_RANGE':
        final range = _values[f.filterKey] as Map<String, DateTime>?;
        return Row(children: [
          Expanded(
            child: InkWell(
              onTap: () => _pickDate(f.filterKey, isFrom: true),
              child: InputDecorator(
                decoration: InputDecoration(labelText: '${f.label} From', isDense: true, border: const OutlineInputBorder()),
                child: Text(_fmtDate(range?['from'])),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: () => _pickDate(f.filterKey, isFrom: false),
              child: InputDecorator(
                decoration: InputDecoration(labelText: '${f.label} To', isDense: true, border: const OutlineInputBorder()),
                child: Text(_fmtDate(range?['to'])),
              ),
            ),
          ),
        ]);

      case 'DATE':
        final value = _values[f.filterKey] as DateTime?;
        return InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context, initialDate: value ?? DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100));
            if (picked != null) _set(f.filterKey, picked);
          },
          child: InputDecorator(
            decoration: InputDecoration(labelText: f.label, isDense: true, border: const OutlineInputBorder()),
            child: Text(_fmtDate(value)),
          ),
        );

      case 'DROPDOWN_STATIC':
        final options = f.staticOptions ?? const [];
        return DropdownButtonFormField<String?>(
          initialValue: _values[f.filterKey] as String?,
          isExpanded: true, isDense: true, itemHeight: null,
          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
          items: [
            const DropdownMenuItem(value: null, child: Text('All')),
            ...options.map((o) => DropdownMenuItem(value: o['value'] as String, child: Text(o['label'] as String))),
          ],
          onChanged: (v) => _set(f.filterKey, v),
        );

      case 'DROPDOWN_LOOKUP':
      case 'ACCOUNT_PICKER':
      case 'PRODUCT_PICKER':
        final options = _lookupOptionsCache[f.filterKey] ?? const [];
        final labelCol = f.lookupLabelColumn ?? 'name';
        return DropdownButtonFormField<String?>(
          initialValue: _values[f.filterKey] as String?,
          isExpanded: true, isDense: true, itemHeight: null,
          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
          items: [
            const DropdownMenuItem(value: null, child: Text('All')),
            ...options.map((o) => DropdownMenuItem(value: o['id'] as String, child: Text('${o[labelCol]}'))),
          ],
          onChanged: (v) => _set(f.filterKey, v),
        );

      case 'FINANCE_ACCOUNT_PICKER':
        // The real 3-column Code/Name/Parent-Group searchable picker (see
        // CLAUDE.md's "Account pickers" rule) — never DropdownButton for
        // accounts, even inside the generic reporting engine. Distinct
        // from the plain-dropdown ACCOUNT_PICKER above, which stays as-is
        // for reports (e.g. Sales Register's Customer filter) that don't
        // need Finance's Code/Name/Parent-Group disambiguation.
        //
        // lookup_source is unused by DROPDOWN_LOOKUP's own meaning for this
        // filter type (that's a table/view name) — repurposed here to hold
        // an optional account_nature restriction ('Customer'/'Supplier'),
        // so a report like Customer Ageing can scope its own Account filter
        // to just Customer accounts instead of every postable account in
        // the chart. Left NULL (as Account Ledger's own filter is) shows
        // every postable account, unrestricted, same as before.
        final natureFiltered = f.lookupSource != null
            ? postableAccounts.where((a) => a['account_nature'] == f.lookupSource).toList()
            : postableAccounts;
        final selectedId = _values[f.filterKey] as String?;
        Map<String, dynamic>? selected;
        if (selectedId != null) {
          for (final a in natureFiltered) {
            if (a['id'] == selectedId) {
              selected = a;
              break;
            }
          }
        }
        return FinanceAccountPicker(
          key: ValueKey(selectedId),
          accounts: natureFiltered,
          initialValue: selected != null ? FinanceAccountPicker.displayString(selected) : null,
          onSelected: (a) => _set(f.filterKey, a['id'] as String),
          decoration: InputDecoration(labelText: f.label, isDense: true, border: const OutlineInputBorder()),
        );

      case 'BOOLEAN':
        return DropdownButtonFormField<bool?>(
          initialValue: _values[f.filterKey] as bool?,
          isExpanded: true, isDense: true, itemHeight: null,
          decoration: InputDecoration(labelText: f.label, border: const OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: null, child: Text('All')),
            DropdownMenuItem(value: true, child: Text('Yes')),
            DropdownMenuItem(value: false, child: Text('No')),
          ],
          onChanged: (v) => _set(f.filterKey, v),
        );

      case 'TEXT':
      default:
        return TextFormField(
          initialValue: _values[f.filterKey] as String?,
          decoration: InputDecoration(
            labelText: f.label, isDense: true, border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
          ),
          onChanged: (v) => _set(f.filterKey, v.isEmpty ? null : v, debounce: true),
        );
    }
  }
}

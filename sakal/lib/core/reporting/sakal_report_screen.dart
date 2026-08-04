import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../errors/error_presenter.dart';
import '../providers/master_cache_providers.dart';
import '../providers/session_provider.dart';
import '../theme/app_colors.dart';
import '../utils/app_logger.dart';
import '../utils/screen_permission_mixin.dart';
import 'report_data_controller.dart';
import 'report_export_helpers.dart';
import 'report_models.dart';
import 'report_pdf_export.dart';
import 'report_excel_export.dart';
import 'report_repository.dart';
import 'sakal_report_filter_bar.dart';
import 'sakal_report_matrix_table.dart';
import 'sakal_report_table.dart';

/// The one generic screen every report in the app renders through — see
/// sakal/docs/reporting_engine_design.md. Reads a report's definition
/// (+columns+filters+group levels) from the DB-driven registry by
/// [reportKey], then wires SakalReportFilterBar + (SakalReportTable or
/// SakalReportMatrixTable, per report_type) to a ReportDataController.
/// Adding report #2, #3, #4... needs no new screen — a migration (VIEW/fn_
/// + registry rows) and a menu row are enough.
class ReportScreen extends ConsumerStatefulWidget {
  final String reportKey;
  const ReportScreen({super.key, required this.reportKey});

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> with ScreenPermissionMixin<ReportScreen> {
  @override
  String get screenName => '/reports/${widget.reportKey}';

  final _repository = const ReportRepository();
  ReportBundle? _bundle;
  ReportDataController? _controller;
  bool _loading = true;
  String? _loadError;
  bool _exportingPdf = false;
  bool _exportingExcel = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _loadError = null; });
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      final bundle = await _repository.fetchBundle(
        reportKey: widget.reportKey, clientId: session.clientId, companyId: session.companyId);
      final controller = ReportDataController(
          repository: _repository, bundle: bundle, clientId: session.clientId, companyId: session.companyId);
      await controller.init();
      if (!mounted) return;
      setState(() { _bundle = bundle; _controller = controller; _loading = false; });
    } catch (e, st) {
      AppLogger.error('ReportScreenLoad', e, st);
      if (!mounted) return;
      setState(() { _loadError = ErrorPresenter.format(e, action: 'load this report'); _loading = false; });
    }
  }

  Map<String, String> _buildFilterSummary() {
    final bundle = _bundle!, controller = _controller!;
    final summary = <String, String>{};
    for (final f in bundle.filters) {
      final v = controller.filterValues[f.filterKey];
      if (v == null) continue;
      if (v is Map && f.isDateRange) {
        final from = v['from'], to = v['to'];
        summary[f.label] = '${from ?? 'Any'} – ${to ?? 'Any'}';
      } else {
        summary[f.label] = '$v';
      }
    }
    return summary;
  }

  Future<void> _exportPdf() async {
    setState(() { _exportingPdf = true; _actionError = null; });
    try {
      final bundle = _bundle!, controller = _controller!;
      final rows = await _repository.fetchAllForExport(
        bundle: bundle, clientId: controller.clientId, companyId: controller.companyId,
        filterValues: controller.filterValues,
        sortColumn: controller.sortColumn, sortDir: controller.sortDir);
      if (rows == null) {
        setState(() => _actionError = 'This report has more than ${bundle.definition.maxExportRows} rows — narrow your filters and try again.');
        return;
      }
      final exportRows = prepareGroupedExportRows(bundle, rows);
      final totalsRow = bundle.isGrouped ? controller.groupedGrandTotal : controller.totals;
      final session = ref.read(sessionProvider);
      final company = await ref.read(companyDetailsProvider.future) ?? <String, dynamic>{};
      await ReportPdfExport.export(
        definition: bundle.definition, columns: bundle.columns, rows: exportRows,
        filterSummary: _buildFilterSummary(), totalsRow: totalsRow,
        company: company, printedByName: session?.fullName ?? '—', printedOn: DateTime.now());
    } catch (e, st) {
      AppLogger.error('ReportScreenExportPdf', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'export this report to PDF'));
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  Future<void> _exportExcel() async {
    setState(() { _exportingExcel = true; _actionError = null; });
    try {
      final bundle = _bundle!, controller = _controller!;
      if (bundle.isMatrix) {
        // Matrix data is already fully loaded (controller.items — no
        // pagination for MATRIX reports, see ReportDataController) — no
        // extra fetch needed, just pivot + write the wide shape.
        final session = ref.read(sessionProvider);
        await ReportExcelExport.exportMatrix(
          definition: bundle.definition, columns: bundle.columns, rows: controller.items,
          numberFormat: session?.numberFormat ?? 'INTERNATIONAL');
        return;
      }
      final rows = await _repository.fetchAllForExport(
        bundle: bundle, clientId: controller.clientId, companyId: controller.companyId,
        filterValues: controller.filterValues,
        sortColumn: controller.sortColumn, sortDir: controller.sortDir);
      if (rows == null) {
        setState(() => _actionError = 'This report has more than ${bundle.definition.maxExportRows} rows — narrow your filters and try again.');
        return;
      }
      final exportRows = prepareGroupedExportRows(bundle, rows);
      final totalsRow = bundle.isGrouped ? controller.groupedGrandTotal : controller.totals;
      await ReportExcelExport.export(
        definition: bundle.definition, columns: bundle.columns, rows: exportRows, totalsRow: totalsRow);
    } catch (e, st) {
      AppLogger.error('ReportScreenExportExcel', e, st);
      if (mounted) setState(() => _actionError = ErrorPresenter.format(e, action: 'export this report to Excel'));
    } finally {
      if (mounted) setState(() => _exportingExcel = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_loadError!, style: const TextStyle(color: AppColors.negative))));
    }
    final bundle = _bundle!, controller = _controller!;
    final session = ref.watch(sessionProvider);
    final numberFormat = session?.numberFormat ?? 'INTERNATIONAL';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
        child: Row(children: [
          Expanded(
            child: Text(bundle.definition.reportName,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary)),
          ),
          IconButton(
            icon: _exportingPdf
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Download PDF',
            color: AppColors.negative,
            onPressed: _exportingPdf ? null : _exportPdf,
          ),
          IconButton(
            icon: _exportingExcel
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.grid_on_outlined),
            tooltip: 'Download Excel',
            color: AppColors.positive,
            onPressed: _exportingExcel ? null : _exportExcel,
          ),
        ]),
      ),
      if (_actionError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(_actionError!, style: const TextStyle(color: AppColors.negative, fontSize: 12)),
        ),
      const Divider(height: 20),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: SakalReportFilterBar(
          filters: bundle.filters,
          initialValues: controller.filterValues,
          onApply: (values) async {
            await controller.applyFilters(values);
            if (mounted) setState(() {});
          },
        ),
      ),
      if (controller.isLoading)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else
        Expanded(
          child: bundle.isMatrix
              ? SakalReportMatrixTable(bundle: bundle, rows: controller.items, numberFormat: numberFormat)
              : SakalReportTable(
                  bundle: bundle,
                  controller: controller,
                  numberFormat: numberFormat,
                  onChanged: () => setState(() {}),
                ),
        ),
    ]);
  }
}

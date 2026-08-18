import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_colors.dart';
import '../utils/app_number_format.dart';
import '../utils/responsive.dart';
import 'report_data_controller.dart';
import 'report_models.dart';
import 'report_repository.dart';

/// One flattened row to hand to `ListView.builder` — a group header, a
/// detail row, or a "load more detail" trigger, each at a given tree
/// indent. Flattening the (recursive) group tree into a single list is
/// what keeps rendering lazy (`ListView.builder` — a hard rule, see
/// sakal/docs/reporting_engine_design.md's Performance section) even
/// though the underlying data is a tree, not a flat list.
class _RenderItem {
  final ReportGroupNode? groupNode;
  final ReportRow? detailRow;
  final ReportGroupNode? loadMoreNode; // non-null => render a "load more" row for this node
  final int indent;
  const _RenderItem.group(this.groupNode, this.indent) : detailRow = null, loadMoreNode = null;
  const _RenderItem.detail(this.detailRow, this.indent) : groupNode = null, loadMoreNode = null;
  const _RenderItem.loadMore(this.loadMoreNode, this.indent) : groupNode = null, detailRow = null;
}

/// The reporting engine's own desktop-oriented data grid — deliberately
/// not a `SakalAdaptiveList` reuse (reports are wide/desktop-first by
/// nature). Click-to-sort headers, drag-to-resize columns, a "Columns"
/// show/hide checklist, and (when the report is grouped) collapsible
/// group-header rows with a sticky Grand Total footer. Mobile falls back
/// to a simple stacked-card list, matching the same card-rendering idea
/// `SakalAdaptiveList` already uses — resize/hide is a desktop-table
/// concept.
class SakalReportTable extends StatefulWidget {
  final ReportBundle bundle;
  final ReportDataController controller;
  final String numberFormat;
  final VoidCallback onChanged; // caller setState()s after any controller mutation

  const SakalReportTable({
    super.key,
    required this.bundle,
    required this.controller,
    required this.numberFormat,
    required this.onChanged,
  });

  @override
  State<SakalReportTable> createState() => _SakalReportTableState();
}

class _SakalReportTableState extends State<SakalReportTable> {
  late Map<String, double> _widths;
  late Set<String> _hiddenColumns;
  final ScrollController _hHeaderController = ScrollController();
  final ScrollController _hBodyController = ScrollController();
  final ScrollController _vBodyController = ScrollController();
  bool _syncingScroll = false;

  static const double _minColumnWidth = 70;
  static const double _defaultColumnWidth = 140;

  // Vertical gridline between columns — one shared decoration so header
  // (dark background, needs a light line) and body/group/totals rows
  // (light background, needs AppColors.border) both go through one place.
  static BoxDecoration _colDivider({required bool onDark}) => BoxDecoration(
        border: Border(right: BorderSide(color: onDark ? Colors.white24 : AppColors.border, width: 1)),
      );

  @override
  void initState() {
    super.initState();
    _widths = {for (final c in widget.bundle.columns) c.columnKey: c.defaultWidth ?? _defaultColumnWidth};
    _hiddenColumns = widget.bundle.columns.where((c) => !c.defaultVisible).map((c) => c.columnKey).toSet();
    _hHeaderController.addListener(() => _syncScroll(_hHeaderController, _hBodyController));
    _hBodyController.addListener(() => _syncScroll(_hBodyController, _hHeaderController));
  }

  void _syncScroll(ScrollController from, ScrollController to) {
    if (_syncingScroll || !to.hasClients) return;
    _syncingScroll = true;
    to.jumpTo(from.offset.clamp(0, to.position.maxScrollExtent));
    _syncingScroll = false;
  }

  @override
  void dispose() {
    _hHeaderController.dispose();
    _hBodyController.dispose();
    _vBodyController.dispose();
    super.dispose();
  }

  List<ReportColumn> get _visibleColumns =>
      widget.bundle.columns.where((c) => !_hiddenColumns.contains(c.columnKey)).toList();

  double get _totalWidth =>
      _visibleColumns.fold(0.0, (sum, c) => sum + (_widths[c.columnKey] ?? _defaultColumnWidth)) + _extraGroupPrefixWidth;

  // Group-header rows (_buildGroupHeaderRow) prepend content that a plain
  // header/data row never has: an indent SizedBox per nesting depth, and —
  // whenever a level's own group_label_column isn't one of the visible
  // columns (e.g. this report hides party_currency at the detail-row level
  // because it's already shown via the group header) — a fallback
  // icon+label cell sized from that column's own configured width. Neither
  // is part of _visibleColumns, so leaving it out of _totalWidth understates
  // how wide a group row can actually get, and the horizontal scroll region
  // (sized to _totalWidth everywhere else in this file) then overflows by
  // exactly the missing amount — caught live (a real, not hypothetical,
  // overflow) once the group-header row itself was fixed to have a bounded
  // width instead of crashing outright. Using the deepest indent and the
  // widest applicable fallback label across all levels is a safe, if
  // slightly generous, upper bound — the extra reads as blank trailing
  // space on header/data/totals rows, never a wrongly-narrow column.
  double get _extraGroupPrefixWidth {
    if (!widget.bundle.isGrouped) return 0.0;
    final maxIndent = widget.bundle.groupLevels.length * 20.0;
    var maxFallbackLabel = 0.0;
    for (final level in widget.bundle.groupLevels) {
      final labelColVisible = _visibleColumns.any((c) => c.columnKey == level.groupLabelColumn);
      if (labelColVisible) continue;
      final w = _widths[level.groupLabelColumn] ?? _defaultColumnWidth;
      if (w > maxFallbackLabel) maxFallbackLabel = w;
    }
    return maxIndent + maxFallbackLabel;
  }

  @override
  Widget build(BuildContext context) {
    if (Responsive.isMobile(context)) return _buildMobileCards();

    final totalsRow = widget.bundle.isGrouped ? widget.controller.groupedGrandTotal : widget.controller.totals;

    return Column(children: [
      _buildColumnsToggleBar(),
      const Divider(height: 1, color: AppColors.border),
      SingleChildScrollView(
        controller: _hHeaderController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(width: _totalWidth, child: _buildHeaderRow()),
      ),
      const Divider(height: 1, color: AppColors.border),
      Expanded(
        child: Scrollbar(
          controller: _hBodyController,
          thumbVisibility: true,
          notificationPredicate: (n) => n.depth == 0,
          child: SingleChildScrollView(
            controller: _hBodyController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: _totalWidth, child: _buildBody()),
          ),
        ),
      ),
      if (totalsRow != null) ...[
        const Divider(height: 1, color: AppColors.border),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(width: _totalWidth, child: _buildTotalsFooter(totalsRow)),
        ),
      ],
    ]);
  }

  // ---- Columns show/hide ------------------------------------------------

  Widget _buildColumnsToggleBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Align(
          alignment: Alignment.centerRight,
          child: PopupMenuButton<String>(
            icon: const Icon(Icons.view_column_outlined, size: 20, color: AppColors.primary),
            tooltip: 'Columns',
            itemBuilder: (context) => widget.bundle.columns
                .map((c) => CheckedPopupMenuItem<String>(
                      value: c.columnKey,
                      checked: !_hiddenColumns.contains(c.columnKey),
                      child: Text(c.label),
                    ))
                .toList(),
            onSelected: (key) => setState(() {
              if (_hiddenColumns.contains(key)) {
                _hiddenColumns.remove(key);
              } else {
                _hiddenColumns.add(key);
              }
            }),
          ),
        ),
      );

  // ---- Header row: sort + resize -----------------------------------------

  Widget _buildHeaderRow() => Container(
        color: AppColors.primary,
        child: Row(children: _visibleColumns.map(_buildHeaderCell).toList()),
      );

  Widget _buildHeaderCell(ReportColumn col) {
    final width = _widths[col.columnKey] ?? _defaultColumnWidth;
    final isSorted = widget.controller.sortColumn == col.columnKey;
    return Container(
      width: width,
      decoration: _colDivider(onDark: true),
      child: Stack(children: [
        InkWell(
          onTap: col.sortable
              ? () async {
                  await widget.controller.setSort(col.columnKey);
                  widget.onChanged();
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            // SizedBox(width: double.infinity) forces this Row to the cell's
            // FULL width regardless of the enclosing Stack's own StackFit
            // (default StackFit.loose loosens the incoming width constraint
            // for non-positioned children) — without it, mainAxisAlignment
            // has no guaranteed extra space to push the label into, so a
            // numeric header's label can end up sitting left-of-center
            // instead of flush with the right-aligned values beneath it.
            // Caught live: user reported header labels not lining up with
            // the numeric columns' own right-aligned values.
            child: SizedBox(
              width: double.infinity,
              child: Row(
                mainAxisAlignment: col.isNumeric ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      col.label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10.5, letterSpacing: 0.4),
                    ),
                  ),
                  if (isSorted) ...[
                    const SizedBox(width: 2),
                    Icon(widget.controller.sortDir == 'DESC' ? Icons.arrow_downward : Icons.arrow_upward,
                        size: 12, color: Colors.white),
                  ],
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) => setState(() {
                final next = width + details.delta.dx;
                _widths[col.columnKey] = next < _minColumnWidth ? _minColumnWidth : next;
              }),
              child: const SizedBox(width: 8),
            ),
          ),
        ),
      ]),
    );
  }

  // ---- Body: ungrouped (paginated) or grouped (tree, flattened) --------

  Widget _buildBody() {
    if (widget.bundle.isGrouped) return _buildGroupedBody();
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (widget.controller.hasMore &&
            !widget.controller.isLoadingMore &&
            n.metrics.maxScrollExtent - n.metrics.pixels < 300) {
          widget.controller.loadMore().then((_) => widget.onChanged());
        }
        return false;
      },
      child: Scrollbar(
        controller: _vBodyController,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _vBodyController,
          itemCount: widget.controller.items.length + (widget.controller.isLoadingMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= widget.controller.items.length) return _loadingRow();
            return _buildDataRow(widget.controller.items[i], indent: 0);
          },
        ),
      ),
    );
  }

  // Shared by the desktop table body and the mobile card list — flattens
  // the (recursive, lazily-expanded) group tree into one render-order list.
  // A collapsed node just doesn't recurse into its children; expanding it
  // (controller.expandNode) triggers the same lazy per-group fetch on
  // mobile as it already does on desktop, not a bulk "load everything" pass.
  List<_RenderItem> _flattenGroups() {
    final items = <_RenderItem>[];
    void walk(List<ReportGroupNode> nodes, int indent) {
      for (final node in nodes) {
        items.add(_RenderItem.group(node, indent));
        if (!node.expanded) continue;
        if (node.childGroups != null) {
          walk(node.childGroups!, indent + 1);
        } else if (node.childDetailRows != null) {
          for (final row in node.childDetailRows!) {
            items.add(_RenderItem.detail(row, indent + 1));
          }
          if (node.childDetailHasMore) items.add(_RenderItem.loadMore(node, indent + 1));
        }
      }
    }

    walk(widget.controller.rootGroups, 0);
    return items;
  }

  Widget _buildGroupedBody() {
    final items = _flattenGroups();

    return Scrollbar(
      controller: _vBodyController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _vBodyController,
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          if (item.groupNode != null) return _buildGroupHeaderRow(item.groupNode!, item.indent);
          if (item.loadMoreNode != null) return _buildLoadMoreDetailRow(item.loadMoreNode!, item.indent);
          return _buildDataRow(item.detailRow!, indent: item.indent);
        },
      ),
    );
  }

  // Renders in the SAME column order/widths as _buildDataRow (just
  // special-casing the group-label column's own cell to show the expand
  // icon + label instead of a plain value) so group-header rows line up
  // pixel-for-pixel with both the header row and the detail rows beneath
  // them — an earlier draft built this as "icon+label, THEN every other
  // column", which only lines up when the label column happens to be
  // first in _visibleColumns; caught on review before this ever ran.
  Widget _buildGroupHeaderRow(ReportGroupNode node, int indent) {
    final level = widget.bundle.groupLevels[node.levelNo - 1];
    final labelColVisible = _visibleColumns.any((c) => c.columnKey == level.groupLabelColumn);

    Widget iconAndLabel() => Row(children: [
          Icon(node.loading
                  ? Icons.hourglass_empty
                  : (node.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right),
              size: 16, color: AppColors.primary),
          const SizedBox(width: 2),
          Flexible(
            child: Text('${node.summaryRow[level.groupLabelColumn] ?? '—'}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ]);

    return InkWell(
      onTap: () async {
        if (!node.expanded) {
          await widget.controller.expandNode(node);
        } else {
          node.expanded = false;
        }
        widget.onChanged();
      },
      child: Container(
        color: AppColors.surfaceVariant,
        child: Row(children: [
          if (indent > 0) SizedBox(width: indent * 20.0),
          // Fallback for a level whose group_label_column was never also
          // declared as a ric_report_columns row — degrades gracefully
          // (icon+label prepended, not aligned to any column) rather than
          // silently never rendering.
          if (!labelColVisible)
            Container(
              width: _widths[level.groupLabelColumn] ?? _defaultColumnWidth,
              decoration: _colDivider(onDark: false),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: iconAndLabel()),
            ),
          ..._visibleColumns.map((c) {
            final width = _widths[c.columnKey] ?? _defaultColumnWidth;
            final isLabelCol = c.columnKey == level.groupLabelColumn;
            return Container(
              width: width,
              decoration: _colDivider(onDark: false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: isLabelCol ? iconAndLabel() : _buildCellValue(c, node.summaryRow, node.summaryRow[c.columnKey], bold: true),
              ),
            );
          }),
        ]),
      ),
    );
  }

  Widget _buildLoadMoreDetailRow(ReportGroupNode node, int indent) => Padding(
        padding: EdgeInsets.only(left: indent * 20.0, top: 4, bottom: 4),
        child: node.childDetailLoadingMore
            ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : TextButton(
                onPressed: () async {
                  await widget.controller.loadMoreDetailForNode(node);
                  widget.onChanged();
                },
                child: const Text('Load more'),
              ),
      );

  Widget _buildDataRow(ReportRow row, {required int indent}) => Container(
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
        child: Row(children: [
          if (indent > 0) SizedBox(width: indent * 20.0),
          ..._visibleColumns.map((c) {
            final width = _widths[c.columnKey] ?? _defaultColumnWidth;
            return Container(width: width, decoration: _colDivider(onDark: false), child: _cellContent(c, row));
          }),
        ]),
      );

  Widget _cellContent(ReportColumn col, ReportRow row, {bool bold = false}) {
    final value = row[col.columnKey];
    Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: _buildCellValue(col, row, value, bold: bold),
    );
    if (col.hasDrilldown && value != null) {
      content = InkWell(
        onTap: () => context.push(col.drilldownRoute!.replaceAll('{key}', '$value')),
        child: content,
      );
    }
    return content;
  }

  Widget _buildCellValue(ReportColumn col, ReportRow row, dynamic value, {bool bold = false}) {
    final style = TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w400);
    if (value == null) return const Text('—', style: TextStyle(fontSize: 13, color: AppColors.textDisabled));

    switch (col.dataType) {
      case 'NUMBER':
        final numText = AppNumberFormat.amount((value as num), widget.numberFormat);
        final currencyCode = col.currencyCodeColumn != null ? row[col.currencyCodeColumn]?.toString() : null;
        return Text(
          currencyCode != null ? '$currencyCode $numText' : numText,
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      case 'BOOLEAN':
        return Icon(value == true ? Icons.check_circle : Icons.cancel,
            size: 16, color: value == true ? AppColors.positive : AppColors.textDisabled);
      case 'BADGE':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(4)),
          child: Text('$value', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        );
      case 'DATE':
      case 'TEXT':
      default:
        return Text('$value', maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
  }

  Widget _loadingRow() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );

  // ---- Totals / grand-total footer --------------------------------------

  Widget _buildTotalsFooter(ReportRow totalsRow) => Container(
        color: AppColors.primaryLight.withValues(alpha: 0.12),
        child: Row(children: _visibleColumns.map((c) {
          final width = _widths[c.columnKey] ?? _defaultColumnWidth;
          final isFirst = c == _visibleColumns.first;
          return Container(
            width: width,
            decoration: _colDivider(onDark: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: isFirst
                  ? const Text('Total', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13))
                  : (c.aggregateFn != null
                      ? _buildCellValue(c, totalsRow, totalsRow[c.columnKey], bold: true)
                      : const SizedBox.shrink()),
            ),
          );
        }).toList()),
      );

  // ---- Mobile card fallback ----------------------------------------------

  Widget _buildMobileCards() {
    final rows = widget.bundle.isGrouped ? const <ReportRow>[] : widget.controller.items;
    final totalsRow = widget.bundle.isGrouped ? widget.controller.groupedGrandTotal : widget.controller.totals;
    return Column(children: [
      if (totalsRow != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 16,
            children: widget.bundle.aggregateColumns
                .map((c) => Text('${c.label}: ${AppNumberFormat.amount((totalsRow[c.columnKey] as num? ?? 0), widget.numberFormat)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)))
                .toList(),
          ),
        ),
      Expanded(
        child: widget.bundle.isGrouped ? _buildMobileGroupedList() : _buildMobileDetailList(rows),
      ),
    ]);
  }

  // Same flattened group tree the desktop table renders as table rows
  // (_flattenGroups) — rendered here as a tappable group-summary card
  // (expand/collapse drives the same lazy controller.expandNode() fetch as
  // desktop) followed by an account card per detail row, indented to show
  // nesting. Replaces an earlier placeholder ("best viewed on a wider
  // screen") that left grouped reports — both new Ageing reports and the
  // existing Pending Bills by Customer — entirely unusable on mobile: no
  // account, no amount, nothing but the grand-total bar above.
  Widget _buildMobileGroupedList() {
    final items = _flattenGroups();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final indent = item.indent * 12.0;

        if (item.loadMoreNode != null) {
          return Padding(
            padding: EdgeInsets.only(left: indent, bottom: 8),
            child: _buildLoadMoreDetailRow(item.loadMoreNode!, 0),
          );
        }

        if (item.groupNode != null) {
          final node = item.groupNode!;
          final level = widget.bundle.groupLevels[node.levelNo - 1];
          return Padding(
            padding: EdgeInsets.only(left: indent, bottom: 8),
            child: Card(
              color: AppColors.surfaceVariant,
              child: InkWell(
                onTap: () async {
                  if (!node.expanded) {
                    await widget.controller.expandNode(node);
                  } else {
                    node.expanded = false;
                  }
                  widget.onChanged();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Icon(node.loading
                            ? Icons.hourglass_empty
                            : (node.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right),
                        size: 18, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('${node.summaryRow[level.groupLabelColumn] ?? '—'}',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                    Wrap(
                      spacing: 12,
                      alignment: WrapAlignment.end,
                      children: widget.bundle.aggregateColumns
                          .map((c) => Text(
                              AppNumberFormat.amount((node.summaryRow[c.columnKey] as num? ?? 0), widget.numberFormat),
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)))
                          .toList(),
                    ),
                  ]),
                ),
              ),
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.only(left: indent, bottom: 8),
          child: _mobileDetailCard(item.detailRow!),
        );
      },
    );
  }

  Widget _buildMobileDetailList(List<ReportRow> rows) => ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: rows.length + (widget.controller.isLoadingMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= rows.length) return _loadingRow();
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: _mobileDetailCard(rows[i]));
        },
      );

  Widget _mobileDetailCard(ReportRow row) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: widget.bundle.visibleColumns
                .map((c) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        SizedBox(width: 110, child: Text(c.label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                        Expanded(child: _buildCellValue(c, row, row[c.columnKey])),
                      ]),
                    ))
                .toList(),
          ),
        ),
      );
}

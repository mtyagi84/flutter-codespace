import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/printing/print_field_registry.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';

/// Browse/manage print templates (Phase 2 of the generic print engine —
/// see backend/migrations/043_print_templates.sql and
/// lib/core/printing/). No delete_allowed concept per project convention;
/// templates are deactivated (is_active toggle), never removed, and
/// "Duplicate" is copy_allowed's actual intended use here.
class PrintTemplateListScreen extends ConsumerStatefulWidget {
  const PrintTemplateListScreen({super.key});

  @override
  ConsumerState<PrintTemplateListScreen> createState() => _PrintTemplateListScreenState();
}

class _PrintTemplateListScreenState extends ConsumerState<PrintTemplateListScreen>
    with ScreenPermissionMixin<PrintTemplateListScreen> {
  @override String get screenName => RouteNames.printTemplates;

  List<Map<String, dynamic>> _templates = [];
  bool _loading = true;
  String? _error;
  String? _filterDocType; // null = all

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final params = <String, dynamic>{
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select':     'id,document_type,template_name,paper_profile,is_default,is_active',
        'order':      'document_type.asc,template_name.asc',
      };
      if (_filterDocType != null) params['document_type'] = 'eq.$_filterDocType';
      final res = await DioClient.instance.get('/ric_print_templates', queryParameters: params);
      if (!mounted) return;
      setState(() { _templates = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load print templates.'; });
    }
  }

  Future<void> _openNew() async {
    await context.push(RouteNames.printTemplateDesigner, extra: {
      'documentType': _filterDocType ?? PrintFieldRegistry.documentTypes.first,
    });
    if (mounted) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> t) async {
    await context.push(RouteNames.printTemplateDesigner, extra: {
      'templateId': t['id'] as String,
      'documentType': t['document_type'] as String,
    });
    if (mounted) _load();
  }

  Future<void> _setDefault(Map<String, dynamic> t) async {
    final session = ref.read(sessionProvider)!;
    try {
      // Clear any existing default for this document type first — the
      // partial unique index rejects two TRUE rows at once, so this must
      // happen as a separate step, not in the same request as setting the
      // new one.
      await DioClient.instance.patch('/ric_print_templates',
          queryParameters: {
            'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
            'document_type': 'eq.${t['document_type']}', 'is_default': 'eq.true',
          },
          data: {'is_default': false, 'updated_by': session.userId},
          options: Options(headers: {'Prefer': 'return=minimal'}));
      await DioClient.instance.patch('/ric_print_templates',
          queryParameters: {'id': 'eq.${t['id']}'},
          data: {'is_default': true, 'updated_by': session.userId},
          options: Options(headers: {'Prefer': 'return=minimal'}));
      _load();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Could not set default template.';
      if (mounted) _showSnack(msg, color: AppColors.negative);
    } catch (e) {
      if (mounted) _showSnack('Unexpected error: $e', color: AppColors.negative);
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> t) async {
    final session = ref.read(sessionProvider)!;
    final newActive = !(t['is_active'] as bool? ?? true);
    try {
      await DioClient.instance.patch('/ric_print_templates',
          queryParameters: {'id': 'eq.${t['id']}'},
          data: {'is_active': newActive, 'updated_by': session.userId},
          options: Options(headers: {'Prefer': 'return=minimal'}));
      _load();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Could not update template.';
      if (mounted) _showSnack(msg, color: AppColors.negative);
    }
  }

  Future<void> _duplicate(Map<String, dynamic> t) async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/ric_print_templates', queryParameters: {
        'id': 'eq.${t['id']}', 'select': 'layout', 'limit': '1',
      });
      final list = res.data as List;
      if (list.isEmpty) return;
      final layout = (list.first as Map<String, dynamic>)['layout'];
      var copyName = '${t['template_name']} (copy)';
      var suffix = 2;
      // Names are unique per (client, company, document_type) — probe and
      // bump the suffix rather than letting the INSERT fail on a repeat copy.
      while (_templates.any((x) => x['document_type'] == t['document_type'] && x['template_name'] == copyName)) {
        copyName = '${t['template_name']} (copy $suffix)';
        suffix++;
      }
      await DioClient.instance.post('/ric_print_templates', data: {
        'client_id':     session.clientId,
        'company_id':    session.companyId,
        'document_type': t['document_type'],
        'template_name': copyName,
        'paper_profile': t['paper_profile'],
        'is_default':    false,
        'layout':        layout,
        'created_by':    session.userId,
      }, options: Options(headers: {'Prefer': 'return=minimal'}));
      _load();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Could not duplicate template.';
      if (mounted) _showSnack(msg, color: AppColors.negative);
    }
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    final offline  = ref.watch(sessionProvider)?.offlineMode ?? false;
    final isMobile = Responsive.isMobile(context);
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Print Templates',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    SizedBox(height: 4),
                    Text(
                        'Customize what prints for each document type — layout, fields, and paper size '
                        '(A4/Letter or 58mm/80mm receipt).',
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ]),
                ),
                if (canAdd && !offline)
                  ElevatedButton.icon(
                    onPressed: _openNew,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Template'),
                  ),
              ]),
              const SizedBox(height: 16),

              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String?>(
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10), labelText: 'Document Type'),
                  isExpanded: true,
                  initialValue: _filterDocType,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All document types')),
                    ...PrintFieldRegistry.documentTypes.map((d) => DropdownMenuItem(
                        value: d, child: Text(PrintFieldRegistry.documentTypeLabel(d)))),
                  ],
                  onChanged: (v) { setState(() => _filterDocType = v); _load(); },
                ),
              ),
              const SizedBox(height: 20),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

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

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                    : _templates.isEmpty
                        ? const Padding(padding: EdgeInsets.all(24),
                            child: Text('No print templates yet — every document type prints using a built-in '
                                'default until you create one.'))
                        : Column(children: _templates.map((t) => _buildTile(t, offline)).toList()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTile(Map<String, dynamic> t, bool offline) {
    final isDefault = t['is_default'] as bool? ?? false;
    final isActive  = t['is_active'] as bool? ?? true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.5)))),
      child: Row(children: [
        Icon(Icons.description_outlined, size: 18,
            color: isActive ? AppColors.primary : AppColors.textDisabled),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t['template_name'] as String? ?? '',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: isActive ? AppColors.textPrimary : AppColors.textDisabled)),
            const SizedBox(height: 2),
            Text('${PrintFieldRegistry.documentTypeLabel(t['document_type'] as String? ?? '')} · '
                '${t['paper_profile']}',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          ]),
        ),
        if (isDefault)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.positive.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('DEFAULT',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.positive)),
          ),
        if (!isActive) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.textDisabled.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('INACTIVE',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          ),
        ],
        if (!offline) ...[
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'edit': _openEdit(t);
                case 'default': _setDefault(t);
                case 'duplicate': _duplicate(t);
                case 'toggle': _toggleActive(t);
              }
            },
            itemBuilder: (_) => [
              if (canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit')),
              if (canEdit && !isDefault) const PopupMenuItem(value: 'default', child: Text('Set as Default')),
              if (canCopy) const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              if (canEdit) PopupMenuItem(value: 'toggle', child: Text(isActive ? 'Deactivate' : 'Activate')),
            ],
          ),
        ],
      ]),
    );
  }
}

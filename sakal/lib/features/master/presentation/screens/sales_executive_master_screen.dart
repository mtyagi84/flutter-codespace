import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_presets.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';
import '../../../../core/widgets/sakal_field_card.dart';

// No repository/model layer exists for this screen (it calls DioClient
// directly) — this row type is defined locally rather than introducing a
// new data/models file for a single screen.
class SalesExecutive {
  final String id;
  final String employeeCode;
  final String fullName;
  final String phone;
  final String email;
  final String? linkedUserId;
  final String? linkedUserName;
  final bool   isActive;

  const SalesExecutive({
    required this.id,
    required this.employeeCode,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.linkedUserId,
    required this.linkedUserName,
    required this.isActive,
  });

  factory SalesExecutive.fromJson(Map<String, dynamic> j) {
    final linkedUser = j['linked_user'] as Map<String, dynamic>?;
    return SalesExecutive(
      id:             j['id']              as String? ?? '',
      employeeCode:   j['employee_code']   as String? ?? '',
      fullName:       j['full_name']       as String? ?? '',
      phone:          j['phone']           as String? ?? '',
      email:          j['email']           as String? ?? '',
      linkedUserId:   j['linked_user_id']  as String?,
      linkedUserName: linkedUser?['full_name'] as String?,
      isActive:       j['is_active']       as bool? ?? true,
    );
  }
}

/// Sales Executive master (migration 103) — decouples "who sold this" from
/// "who has a system login". A sales exec's linkedUserId is optional; most
/// field reps/commission agents have none. Consumed by the sales_person_id
/// picker on Sales Quotation/Order/Invoice and the default sales person on
/// Quick Invoice Setup.
class SalesExecutiveMasterScreen extends ConsumerStatefulWidget {
  const SalesExecutiveMasterScreen({super.key});

  @override
  ConsumerState<SalesExecutiveMasterScreen> createState() => _SalesExecutiveMasterScreenState();
}

class _SalesExecutiveMasterScreenState extends ConsumerState<SalesExecutiveMasterScreen>
    with ScreenPermissionMixin<SalesExecutiveMasterScreen>, ScreenHeaderMixin<SalesExecutiveMasterScreen> {
  @override String get screenName => RouteNames.salesExecutives;

  @override
  ScreenHeaderInfo buildScreenHeader() => ScreenHeaderInfo(
        title: 'Sales Executives',
        actions: canAdd
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New Sales Executive'),
                    onPressed: () => _showEntryDialog(),
                  ),
                ),
              ]
            : const [],
      );

  List<SalesExecutive> _rows  = [];
  List<Map<String, dynamic>> _users = [];
  bool    _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _searchText = _searchCtrl.text.trim().toLowerCase()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_sales_executives', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     '*,linked_user:rim_users!linked_user_id(full_name)',
          'order':      'full_name.asc',
        }),
        DioClient.instance.get('/rim_users', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_active':  'eq.true', 'is_deleted': 'eq.false',
          'select':     'id,full_name',
          'order':      'full_name.asc',
        }),
      ]);
      if (mounted) {
        setState(() {
          _rows    = (results[0].data as List)
              .map((j) => SalesExecutive.fromJson(j as Map<String, dynamic>))
              .toList();
          _users   = List<Map<String, dynamic>>.from(results[1].data as List);
          _loading = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load sales executives.'; });
    }
  }

  List<SalesExecutive> get _filtered {
    if (_searchText.isEmpty) return _rows;
    return _rows.where((r) =>
        r.employeeCode.toLowerCase().contains(_searchText) ||
        r.fullName.toLowerCase().contains(_searchText)).toList();
  }

  Future<void> _save(Map<String, dynamic> payload, {String? id}) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (id == null) {
        await DioClient.instance.post('/rim_sales_executives', data: {...payload, 'created_by': session.userId});
      } else {
        await DioClient.instance.patch('/rim_sales_executives',
            queryParameters: {'id': 'eq.$id'}, data: {...payload, 'updated_by': session.userId});
      }
      await _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] ?? 'Save failed.');
    }
  }

  Future<void> _toggleActive(SalesExecutive row) async {
    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.patch('/rim_sales_executives',
          queryParameters: {'id': 'eq.${row.id}'},
          data: {'is_active': !row.isActive, 'updated_by': session.userId});
      await _load();
    } on DioException catch (e) {
      _showError(e.response?.data?['message'] ?? 'Update failed.');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.negative));
  }

  Future<void> _showEntryDialog({SalesExecutive? existing}) async {
    final codeCtrl  = TextEditingController(text: existing?.employeeCode ?? '');
    final nameCtrl  = TextEditingController(text: existing?.fullName ?? '');
    final phoneCtrl = TextEditingController(text: existing?.phone ?? '');
    final emailCtrl = TextEditingController(text: existing?.email ?? '');
    String? linkedUserId = existing?.linkedUserId;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New Sales Executive' : 'Edit Sales Executive'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: codeCtrl, decoration: const InputDecoration(labelText: 'Employee Code *')),
              const SizedBox(height: 10),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name *')),
              const SizedBox(height: 10),
              TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone')),
              const SizedBox(height: 10),
              TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: linkedUserId,
                isExpanded: true, isDense: true, itemHeight: null,
                decoration: const InputDecoration(labelText: 'Link to System User (optional)'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— None — not a system user —')),
                  ..._users.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['full_name'] as String, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) => setDialogState(() => linkedUserId = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved == true && codeCtrl.text.trim().isNotEmpty && nameCtrl.text.trim().isNotEmpty) {
      final session = ref.read(sessionProvider)!;
      await _save({
        'client_id':      session.clientId,
        'company_id':     session.companyId,
        'employee_code':  codeCtrl.text.trim(),
        'full_name':      nameCtrl.text.trim(),
        'phone':          phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        'email':          emailCtrl.text.trim().isEmpty ? null : emailCtrl.text.trim(),
        'linked_user_id': linkedUserId,
      }, id: existing?.id);
    }
    codeCtrl.dispose();
    nameCtrl.dispose();
    phoneCtrl.dispose();
    emailCtrl.dispose();
  }

  String _linkedUserLabel(SalesExecutive r) => r.linkedUserName ?? '—';

  @override
  Widget build(BuildContext context) {
    // Title/New-Sales-Executive button live in the shared TopBar via
    // ScreenHeaderMixin — not rendered here as body content.
    refreshScreenHeader();
    final rows = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          // A Wrap here doesn't stretch a field to fill leftover row space
          // (see sakal_field_row.dart's own doc comment) — on mobile the
          // fixed-width Search field would leave a large empty gap to its
          // right. Plain Row with Expanded instead.
          child: Row(children: [
            Expanded(
              child: SakalFieldCard(
                label: 'Search', editable: true,
                child: TextField(
                  controller: _searchCtrl,
                  style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider)),
                  decoration: SakalFieldCard.bareDecoration.copyWith(
                    hintText: 'Search code / name…',
                    hintStyle: const TextStyle(fontSize: 12, color: AppColors.textDisabled, fontWeight: FontWeight.normal),
                    suffixIcon: _searchText.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear, size: 14), onPressed: _searchCtrl.clear, padding: EdgeInsets.zero, constraints: const BoxConstraints())
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Refresh', color: AppColors.primary),
          ]),
        ),
        Expanded(
          child: SakalAdaptiveList<SalesExecutive>(
            loading: _loading,
            error: _error,
            rows: rows,
            columns: const [
              SakalListColumn('Code', flex: 2),
              SakalListColumn('Name', flex: 3),
              SakalListColumn('Phone', flex: 2),
              SakalListColumn('Linked User', flex: 2),
              SakalListColumn('Status', flex: 2),
              SakalListColumn('', flex: 1),
            ],
            rowBuilder: _buildRow,
            cardBuilder: _buildCard,
            emptyState: _emptyState(),
          ),
        ),
      ],
    );
  }

  Widget _statusBadge(bool isActive) {
    final color = isActive ? AppColors.positive : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(isActive ? 'Active' : 'Inactive', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildRow(SalesExecutive r, int index) {
    final isActive = r.isActive;
    return InkWell(
      onTap: canEdit ? () => _showEntryDialog(existing: r) : null,
      child: Container(
        color: index.isEven ? Colors.white : AppColors.background,
        child: Row(children: [
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(r.employeeCode, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.primary)))),
          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.fullName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(r.phone.isNotEmpty ? r.phone : '—', style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_linkedUserLabel(r), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _statusBadge(isActive))),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (canEdit) IconButton(icon: const Icon(Icons.edit_outlined, size: 16), onPressed: () => _showEntryDialog(existing: r), tooltip: 'Edit'),
                if (canEdit) IconButton(icon: Icon(isActive ? Icons.block : Icons.check_circle_outline, size: 16, color: isActive ? AppColors.negative : AppColors.positive),
                    onPressed: () => _toggleActive(r), tooltip: isActive ? 'Deactivate' : 'Activate'),
              ]))),
        ]),
      ),
    );
  }

  Widget _buildCard(SalesExecutive r) {
    final isActive = r.isActive;
    return InkWell(
      onTap: canEdit ? () => _showEntryDialog(existing: r) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.fullName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary))),
            _statusBadge(isActive),
          ]),
          const SizedBox(height: 4),
          Text(r.employeeCode, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (r.phone.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r.phone, style: const TextStyle(fontSize: 12)),
          ],
        ]),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.badge_outlined, size: 48, color: AppColors.textDisabled),
      SizedBox(height: 16),
      Text('No sales executives found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      SizedBox(height: 8),
      Text('Add a sales executive to make them selectable on Quotations, Orders, and Invoices.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
    ]),
  );
}

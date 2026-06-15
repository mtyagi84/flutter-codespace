import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';

class MasterMenuScreen extends ConsumerStatefulWidget {
  const MasterMenuScreen({super.key});

  @override
  ConsumerState<MasterMenuScreen> createState() => _MasterMenuScreenState();
}

class _MasterMenuScreenState extends ConsumerState<MasterMenuScreen> {
  List<Map<String, dynamic>> _modules = [];
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // addPostFrameCallback avoids calling setState during initState
    // (async fns run synchronously to first await — setState before that = lifecycle violation)
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/ric_system_modules', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'order':      'serial_no',
          'select':     'id,module_code,module_name',
        }),
        DioClient.instance.get('/ric_master_menus', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'order':      'group_serial_no,serial_no',
        }),
      ]);
      if (mounted) {
        setState(() {
          _modules = (results[0].data as List).cast<Map<String, dynamic>>();
          _entries = (results[1].data as List).cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _error   = e.response?.data?['message'] as String? ?? e.message ?? 'Load failed';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save(Map<String, dynamic> data, String? id) async {
    final session = ref.read(sessionProvider)!;
    try {
      if (id == null) {
        await DioClient.instance.post('/ric_master_menus', data: {
          ...data,
          'client_id':  session.clientId,
          'company_id': session.companyId,
        });
      } else {
        await DioClient.instance.patch(
          '/ric_master_menus',
          queryParameters: {'id': 'eq.$id'},
          data: data,
        );
      }
      _load();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
        );
      }
    }
  }

  Future<void> _toggleActive(String id, bool current) async {
    try {
      await DioClient.instance.patch(
        '/ric_master_menus',
        queryParameters: {'id': 'eq.$id'},
        data: {'is_active': !current},
      );
      _load();
    } on DioException {
      // list keeps current state on failure — no action needed
    }
  }

  Map<String, String> _existingGroups() {
    final map = <String, String>{};
    for (final e in _entries) {
      final code = e['group_code'] as String?;
      final name = e['group_name'] as String?;
      if (code != null && code.isNotEmpty && name != null) map[code] = name;
    }
    return map;
  }

  String _moduleName(String? id) {
    if (id == null) return '—';
    return _modules.firstWhere(
          (m) => m['id'] == id,
          orElse: () => {'module_name': '?'},
        )['module_name'] as String? ??
        '?';
  }

  void _openDialog([Map<String, dynamic>? entry]) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EntryDialog(
        modules:        _modules,
        entry:          entry,
        existingGroups: _existingGroups(),
        onSave: (data, id) async {
          Navigator.of(context).pop();
          await _save(data, id);
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────

  // Column widths: 8 columns + 7 one-pixel dividers = 1047px total
  static const _w = [140.0, 120.0, 190.0, 250.0, 150.0, 54.0, 72.0, 64.0];
  static const _tableWidth = 1047.0;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.negative),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.negative)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // GoRouter's ShellRoute Overlay can hand down infinite width during
        // route transition frames on Flutter Web. Return empty until the
        // next frame delivers finite constraints.
        if (!constraints.hasBoundedWidth) return const SizedBox.shrink();

        // SizedBox pins the subtree to the actual viewport width so no
        // descendant (e.g. ElevatedButton inside Row+Expanded) can ever
        // receive tight-infinite constraints.
        return SizedBox(
          width: constraints.maxWidth,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Page header ──────────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Master Menu',
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary)),
                          const SizedBox(height: 4),
                          Text(
                            '${_entries.length} entries · ${_modules.length} modules',
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add Menu Entry'),
                      onPressed: () => _openDialog(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Table — horizontal scroll only ───────────────────────
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white,
                    ),
                    clipBehavior: Clip.hardEdge,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeaderRow(),
                        ..._entries.expand((e) => [
                              Container(
                                  width: _tableWidth, height: 1,
                                  color: AppColors.border),
                              _buildDataRow(e),
                            ]),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeaderRow() {
    const style = TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: AppColors.textSecondary,
        letterSpacing: 0.5);
    return ColoredBox(
      color: AppColors.surfaceVariant,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _hcell('MODULE', _w[0], style),
          _vd(), _hcell('FEATURE CODE', _w[1], style),
          _vd(), _hcell('FEATURE NAME', _w[2], style),
          _vd(), _hcell('SCREEN NAME',  _w[3], style),
          _vd(), _hcell('GROUP',        _w[4], style),
          _vd(), _hcell('SER.',         _w[5], style, center: true),
          _vd(), _hcell('ACTIVE',       _w[6], style, center: true),
          _vd(), SizedBox(width: _w[7], height: 40),
        ],
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> e) {
    final active = e['is_active'] as bool? ?? true;
    final tc  = active ? AppColors.textPrimary   : AppColors.textDisabled;
    final sc  = active ? AppColors.textSecondary : AppColors.textDisabled;
    final pc  = active ? AppColors.primary       : AppColors.textDisabled;
    const fs  = 13.0;
    const fsm = 12.0;

    return ColoredBox(
      color: active ? Colors.white : const Color(0xFFF9FAFB),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _dcell(_moduleName(e['module_id'] as String?), _w[0],
              TextStyle(fontSize: fs, color: tc)),
          _vd(),
          _dcell(e['feature_code'] as String? ?? '', _w[1],
              TextStyle(fontSize: fsm, color: pc, fontFamily: 'monospace')),
          _vd(),
          _dcell(e['feature_name'] as String? ?? '', _w[2],
              TextStyle(fontSize: fs, color: tc)),
          _vd(),
          _dcell(e['screen_name'] as String? ?? '', _w[3],
              TextStyle(fontSize: fsm, color: sc, fontFamily: 'monospace')),
          _vd(),
          _dcell(e['group_name'] as String? ?? '—', _w[4],
              TextStyle(fontSize: fsm, color: sc)),
          _vd(),
          _dcell((e['serial_no'] as int? ?? 0).toString(), _w[5],
              TextStyle(fontSize: fs, color: sc), center: true),
          _vd(),
          SizedBox(
            width: _w[6],
            height: 48,
            child: Center(
              child: Switch.adaptive(
                value: active,
                activeColor: AppColors.positive,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_) => _toggleActive(e['id'] as String, active),
              ),
            ),
          ),
          _vd(),
          SizedBox(
            width: _w[7],
            height: 48,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.edit_outlined, size: 17),
                color: AppColors.primary,
                tooltip: 'Edit',
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                onPressed: () => _openDialog(e),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _vd() => const SizedBox(
        width: 1, height: 48,
        child: ColoredBox(color: AppColors.border),
      );

  Widget _hcell(String text, double w, TextStyle style,
          {bool center = false}) =>
      SizedBox(
        width: w,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(text,
              textAlign: center ? TextAlign.center : TextAlign.left,
              style: style),
        ),
      );

  Widget _dcell(String text, double w, TextStyle style,
          {bool center = false}) =>
      SizedBox(
        width: w,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              textAlign: center ? TextAlign.center : TextAlign.left,
              style: style),
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════
// Entry Dialog — Add / Edit
// ══════════════════════════════════════════════════════════════════════

class _EntryDialog extends StatefulWidget {
  final List<Map<String, dynamic>> modules;
  final Map<String, dynamic>? entry;
  final Map<String, String> existingGroups;
  final Future<void> Function(Map<String, dynamic> data, String? id) onSave;

  const _EntryDialog({
    required this.modules,
    required this.entry,
    required this.existingGroups,
    required this.onSave,
  });

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  final _formKey = GlobalKey<FormState>();

  late String? _moduleId;
  late final TextEditingController _featureCode;
  late final TextEditingController _featureName;
  late final TextEditingController _screenName;
  late final TextEditingController _groupCode;
  late final TextEditingController _groupName;
  late final TextEditingController _groupSerial;
  late final TextEditingController _serial;
  late bool _approveAllowed;
  late bool _copyAllowed;
  late bool _excelUpload;
  late bool _isActive;
  bool _saving = false;
  String? _saveError;

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _moduleId      = e?['module_id']  as String?;
    _featureCode   = TextEditingController(text: e?['feature_code']  as String? ?? '');
    _featureName   = TextEditingController(text: e?['feature_name']  as String? ?? '');
    _screenName    = TextEditingController(text: e?['screen_name']   as String? ?? '');
    _groupCode     = TextEditingController(text: e?['group_code']    as String? ?? '');
    _groupName     = TextEditingController(text: e?['group_name']    as String? ?? '');
    _groupSerial   = TextEditingController(text: (e?['group_serial_no'] as int? ?? 0).toString());
    _serial        = TextEditingController(text: (e?['serial_no']        as int? ?? 0).toString());
    _approveAllowed = e?['approve_allowed']      as bool? ?? false;
    _copyAllowed    = e?['copy_allowed']         as bool? ?? false;
    _excelUpload    = e?['excel_upload_allowed'] as bool? ?? false;
    _isActive       = e?['is_active']            as bool? ?? true;
  }

  @override
  void dispose() {
    for (final c in [_featureCode, _featureName, _screenName, _groupCode, _groupName, _groupSerial, _serial]) {
      c.dispose();
    }
    super.dispose();
  }

  // When group code is manually typed, auto-fill group name if it matches an existing code
  void _onGroupCodeChanged(String val) {
    final name = widget.existingGroups[val.trim().toUpperCase()];
    if (name != null && _groupName.text.isEmpty) {
      setState(() => _groupName.text = name);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _saveError = null; });

    final groupCode = _groupCode.text.trim().toUpperCase();
    final groupName = _groupName.text.trim();

    final data = <String, dynamic>{
      'module_id':            _moduleId,
      'feature_code':         _featureCode.text.trim().toUpperCase(),
      'feature_name':         _featureName.text.trim(),
      'screen_name':          _screenName.text.trim(),
      'group_code':           groupCode.isEmpty ? null : groupCode,
      'group_name':           groupName.isEmpty ? null : groupName,
      'group_serial_no':      int.tryParse(_groupSerial.text.trim()) ?? 0,
      'serial_no':            int.tryParse(_serial.text.trim())  ?? 0,
      'approve_allowed':      _approveAllowed,
      'copy_allowed':         _copyAllowed,
      'excel_upload_allowed': _excelUpload,
      'is_active':            _isActive,
    };

    await widget.onSave(data, widget.entry?['id'] as String?);
  }

  @override
  Widget build(BuildContext context) {
    final existingCodes = widget.existingGroups.keys.join(', ');

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Dialog title ──────────────────────────────────────
            _DialogHeader(title: _isEdit ? 'Edit Menu Entry' : 'Add Menu Entry'),

            // ── Form body ─────────────────────────────────────────
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      // Module dropdown
                      DropdownButtonFormField<String>(
                        value: _moduleId,
                        decoration: const InputDecoration(
                          labelText: 'Module *',
                          prefixIcon: Icon(Icons.apps_outlined),
                        ),
                        items: widget.modules.map((m) => DropdownMenuItem(
                          value: m['id'] as String,
                          child: Text('${m['module_code']}  —  ${m['module_name']}'),
                        )).toList(),
                        onChanged: (v) => setState(() => _moduleId = v),
                        validator: (_) =>
                            _moduleId == null ? 'Select a module' : null,
                      ),
                      const SizedBox(height: 14),

                      // Feature Code + Feature Name
                      Row(children: [
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: _featureCode,
                            enabled: !_isEdit,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Feature Code *',
                              hintText: 'e.g. AD-MST',
                              helperText: 'Unique. Cannot change after creation.',
                              helperMaxLines: 2,
                            ),
                            validator: (v) =>
                                (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: TextFormField(
                            controller: _featureName,
                            decoration: const InputDecoration(
                              labelText: 'Feature Name *',
                              hintText: 'e.g. Master Menu',
                            ),
                            validator: (v) =>
                                (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),

                      // Screen Name
                      TextFormField(
                        controller: _screenName,
                        decoration: const InputDecoration(
                          labelText: 'Screen Route *',
                          hintText: 'e.g. /setup/master-menu',
                          prefixIcon: Icon(Icons.link_outlined),
                          helperText: 'Must match the route registered in app_router.dart',
                        ),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          if (!v.trim().startsWith('/')) return 'Must start with /';
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),

                      // Group section
                      const _SectionLabel('Group  (optional — groups the feature in the sidebar)'),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: _groupCode,
                            textCapitalization: TextCapitalization.characters,
                            onChanged: _onGroupCodeChanged,
                            decoration: InputDecoration(
                              labelText: 'Group Code',
                              hintText: 'e.g. AD-SETG',
                              helperText: existingCodes.isNotEmpty
                                  ? 'Existing: $existingCodes'
                                  : null,
                              helperMaxLines: 3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: TextFormField(
                            controller: _groupName,
                            decoration: const InputDecoration(
                              labelText: 'Group Display Name',
                              hintText: 'e.g. System Setup',
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),

                      // Sort orders
                      Row(children: [
                        Expanded(
                          child: TextFormField(
                            controller: _groupSerial,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Group Order',
                              hintText: '0',
                              helperText: 'Sort position of this group in the module',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _serial,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Feature Order',
                              hintText: '0',
                              helperText: 'Sort position within the group',
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 20),

                      // Permissions
                      const _SectionLabel('Permissions available for this screen'),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(
                          child: CheckboxListTile.adaptive(
                            dense: true,
                            title: const Text('Approve', style: TextStyle(fontSize: 13)),
                            value: _approveAllowed,
                            onChanged: (v) => setState(() => _approveAllowed = v!),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        Expanded(
                          child: CheckboxListTile.adaptive(
                            dense: true,
                            title: const Text('Copy', style: TextStyle(fontSize: 13)),
                            value: _copyAllowed,
                            onChanged: (v) => setState(() => _copyAllowed = v!),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        Expanded(
                          child: CheckboxListTile.adaptive(
                            dense: true,
                            title: const Text('Excel Upload', style: TextStyle(fontSize: 13)),
                            value: _excelUpload,
                            onChanged: (v) => setState(() => _excelUpload = v!),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 4),

                      // Active
                      SwitchListTile.adaptive(
                        dense: true,
                        title: const Text('Active',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        subtitle: const Text(
                            'Inactive entries are hidden from all users',
                            style: TextStyle(fontSize: 11)),
                        value: _isActive,
                        activeColor: AppColors.positive,
                        onChanged: (v) => setState(() => _isActive = v),
                        contentPadding: EdgeInsets.zero,
                      ),

                      if (_saveError != null) ...[
                        const SizedBox(height: 8),
                        Text(_saveError!,
                            style: const TextStyle(
                                color: AppColors.negative, fontSize: 13)),
                      ],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),

            // ── Footer ────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _saving ? null : _submit,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : Text(_isEdit ? 'Save Changes' : 'Add Entry'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  final String title;
  const _DialogHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 12, 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.5));
  }
}

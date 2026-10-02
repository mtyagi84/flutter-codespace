import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../../../core/widgets/sakal_autocomplete.dart';
import '../../data/pos_terminal_access_helper.dart';

/// Admin configuration for Terminals, Devices, and per-user terminal
/// access/PIN — the one screen that unblocks everything else in
/// docs/pos/10_phase_plan.md's build order: nobody can sign into a till
/// (PosPinLoginScreen) until a terminal exists, a device is bound to it
/// (done from PosDeviceSetupScreen, once, per device), and a user both has
/// `ric_user_pos_terminal_access` for it AND a PIN set (`fn_set_user_pin`).
///
/// Deliberately back-office density (DropdownButtonFormField/plain Cards,
/// same as every other `/setup/*` admin screen) rather than the touch-first
/// POS look the till screens use — this screen runs on an office PC, not a
/// shop-floor touchscreen. See docs/pos/09_screens_and_mockups.md's own
/// distinction between the two visual treatments.
class PosSetupScreen extends ConsumerStatefulWidget {
  const PosSetupScreen({super.key});

  @override
  ConsumerState<PosSetupScreen> createState() => _PosSetupScreenState();
}

class _PosSetupScreenState extends ConsumerState<PosSetupScreen>
    with ScreenPermissionMixin<PosSetupScreen>, ScreenHeaderMixin<PosSetupScreen>, SingleTickerProviderStateMixin {
  @override
  String get screenName => '/pos/admin';

  @override
  ScreenHeaderInfo buildScreenHeader() => const ScreenHeaderInfo(
        title: 'POS Setup',
        subtitle: 'Terminals, devices, and which users can sign into each till.',
      );

  late final TabController _tabController;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _terminals = [];
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/ric_locations', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'is_active': 'eq.true', 'select': 'id,location_name', 'order': 'location_name.asc',
        }),
        DioClient.instance.get('/ric_pos_terminals', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select': 'id,terminal_code,terminal_name,receipt_paper_profile,is_active,location_id,ric_locations(location_name)',
          'order': 'terminal_code.asc',
        }),
        DioClient.instance.get('/ric_pos_devices', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select': 'id,device_name,platform,bound_terminal_id,last_seen_at,is_blocked,ric_pos_terminals(terminal_name)',
          'order': 'last_seen_at.desc.nullslast',
        }),
        DioClient.instance.get('/rim_users', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'select': 'id,full_name', 'order': 'full_name.asc',
        }),
      ]);
      if (!mounted) return;
      setState(() {
        _locations = List<Map<String, dynamic>>.from(results[0].data as List);
        _terminals = List<Map<String, dynamic>>.from(results[1].data as List);
        _devices = List<Map<String, dynamic>>.from(results[2].data as List);
        _users = List<Map<String, dynamic>>.from(results[3].data as List);
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.error('PosSetupLoad', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load POS setup'); });
    }
  }

  void _showMsg(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    refreshScreenHeader();
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;

    return Column(
      children: [
        if (offline) const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: OfflineBanner()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: AppColors.primary,
            tabs: const [Tab(text: 'Terminals'), Tab(text: 'Devices'), Tab(text: 'User Access & PIN')],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorRetry(message: _error!, onRetry: _loadAll)
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _TerminalsTab(locations: _locations, terminals: _terminals, canEdit: canEdit && !offline, onChanged: _loadAll, showMsg: _showMsg),
                        _DevicesTab(terminals: _terminals, devices: _devices, canEdit: canEdit && !offline, onChanged: _loadAll, showMsg: _showMsg),
                        _UserAccessTab(users: _users, terminals: _terminals, canEdit: canEdit && !offline, showMsg: _showMsg),
                      ],
                    ),
        ),
      ],
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, style: const TextStyle(color: AppColors.negative)),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );
}

// ── Terminals tab ───────────────────────────────────────────────────────────

class _TerminalsTab extends StatelessWidget {
  final List<Map<String, dynamic>> locations;
  final List<Map<String, dynamic>> terminals;
  final bool canEdit;
  final VoidCallback onChanged;
  final void Function(String, {Color? color}) showMsg;

  const _TerminalsTab({required this.locations, required this.terminals, required this.canEdit, required this.onChanged, required this.showMsg});

  Future<void> _openEditor(BuildContext context, {Map<String, dynamic>? existing}) async {
    await showDialog(
      context: context,
      builder: (_) => _TerminalEditorDialog(locations: locations, existing: existing, onSaved: onChanged, showMsg: showMsg),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        itemCount: terminals.length,
        itemBuilder: (context, i) {
          final t = terminals[i];
          final locName = (t['ric_locations'] as Map<String, dynamic>?)?['location_name'] as String? ?? '—';
          final active = t['is_active'] as bool? ?? true;
          return Card(
            child: ListTile(
              leading: const Icon(Icons.point_of_sale_outlined),
              title: Text('${t['terminal_code']} — ${t['terminal_name']}'),
              subtitle: Text('$locName · ${t['receipt_paper_profile']}${active ? '' : ' · Inactive'}'),
              trailing: canEdit ? const Icon(Icons.edit_outlined, size: 18) : null,
              onTap: canEdit ? () => _openEditor(context, existing: t) : null,
            ),
          );
        },
      ),
      if (canEdit)
        Positioned(
          right: 16, bottom: 16,
          child: FloatingActionButton.extended(onPressed: () => _openEditor(context), icon: const Icon(Icons.add), label: const Text('Add Terminal')),
        ),
    ]);
  }
}

class _TerminalEditorDialog extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> locations;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  final void Function(String, {Color? color}) showMsg;

  const _TerminalEditorDialog({required this.locations, required this.existing, required this.onSaved, required this.showMsg});

  @override
  ConsumerState<_TerminalEditorDialog> createState() => _TerminalEditorDialogState();
}

class _TerminalEditorDialogState extends ConsumerState<_TerminalEditorDialog> {
  late final _codeCtrl = TextEditingController(text: widget.existing?['terminal_code'] as String? ?? '');
  late final _nameCtrl = TextEditingController(text: widget.existing?['terminal_name'] as String? ?? '');
  String? _locationId;
  String _paperProfile = 'RECEIPT_80MM';
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _locationId = widget.existing?['location_id'] as String?;
    _paperProfile = widget.existing?['receipt_paper_profile'] as String? ?? 'RECEIPT_80MM';
    _active = widget.existing?['is_active'] as bool? ?? true;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_locationId == null || _codeCtrl.text.trim().isEmpty || _nameCtrl.text.trim().isEmpty) {
      widget.showMsg('Location, code, and name are all required.', color: AppColors.negative);
      return;
    }
    setState(() => _saving = true);
    final session = ref.read(sessionProvider)!;
    try {
      if (widget.existing == null) {
        await DioClient.instance.post('/ric_pos_terminals', data: {
          'id': const Uuid().v4(),
          'client_id': session.clientId,
          'company_id': session.companyId,
          'location_id': _locationId,
          'terminal_code': _codeCtrl.text.trim(),
          'terminal_name': _nameCtrl.text.trim(),
          'receipt_paper_profile': _paperProfile,
        });
      } else {
        await DioClient.instance.patch(
          '/ric_pos_terminals',
          queryParameters: {'id': 'eq.${widget.existing!['id']}'},
          data: {
            'location_id': _locationId,
            'terminal_code': _codeCtrl.text.trim(),
            'terminal_name': _nameCtrl.text.trim(),
            'receipt_paper_profile': _paperProfile,
            'is_active': _active,
          },
        );
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved();
        widget.showMsg('Terminal saved.', color: AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('PosTerminalSave', e, st);
      widget.showMsg(ErrorPresenter.format(e, action: 'save this terminal'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Terminal' : 'Edit Terminal'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _locationId,
            isExpanded: true, isDense: true, itemHeight: null,
            decoration: const InputDecoration(labelText: 'Store / Location'),
            items: widget.locations.map((l) => DropdownMenuItem(value: l['id'] as String, child: Text(l['location_name'] as String))).toList(),
            onChanged: (v) => setState(() => _locationId = v),
          ),
          const SizedBox(height: 10),
          TextField(controller: _codeCtrl, decoration: const InputDecoration(labelText: 'Terminal Code (e.g. T1)')),
          const SizedBox(height: 10),
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Terminal Name (e.g. Front Counter)')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _paperProfile,
            isExpanded: true, isDense: true, itemHeight: null,
            decoration: const InputDecoration(labelText: 'Receipt Paper'),
            items: const [
              DropdownMenuItem(value: 'RECEIPT_58MM', child: Text('58mm')),
              DropdownMenuItem(value: 'RECEIPT_80MM', child: Text('80mm')),
            ],
            onChanged: (v) => setState(() => _paperProfile = v!),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
        ),
      ],
    );
  }
}

// ── Devices tab ─────────────────────────────────────────────────────────────

class _DevicesTab extends StatelessWidget {
  final List<Map<String, dynamic>> terminals;
  final List<Map<String, dynamic>> devices;
  final bool canEdit;
  final VoidCallback onChanged;
  final void Function(String, {Color? color}) showMsg;

  const _DevicesTab({required this.terminals, required this.devices, required this.canEdit, required this.onChanged, required this.showMsg});

  Future<void> _rebind(BuildContext context, Map<String, dynamic> device) async {
    final terminalId = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Bind to Terminal'),
        children: terminals
            .map((t) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(t['id'] as String),
                  child: Text('${t['terminal_code']} — ${t['terminal_name']}'),
                ))
            .toList(),
      ),
    );
    if (terminalId == null) return;
    try {
      await DioClient.instance.post('/rpc/fn_bind_pos_device', data: {'p_device_id': device['id'], 'p_terminal_id': terminalId});
      onChanged();
      showMsg('Device bound.', color: AppColors.positive);
    } catch (e, st) {
      AppLogger.error('PosDeviceRebind', e, st);
      showMsg(ErrorPresenter.format(e, action: 'bind this device'), color: AppColors.negative);
    }
  }

  Future<void> _toggleBlock(Map<String, dynamic> device) async {
    final blocked = device['is_blocked'] as bool? ?? false;
    try {
      await DioClient.instance.patch('/ric_pos_devices', queryParameters: {'id': 'eq.${device['id']}'}, data: {'is_blocked': !blocked});
      onChanged();
      showMsg(blocked ? 'Device unblocked.' : 'Device blocked.', color: AppColors.positive);
    } catch (e, st) {
      AppLogger.error('PosDeviceToggleBlock', e, st);
      showMsg(ErrorPresenter.format(e, action: 'update this device'), color: AppColors.negative);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Center(child: Text('No devices have registered yet.', style: TextStyle(color: AppColors.textSecondary)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: devices.length,
      itemBuilder: (context, i) {
        final d = devices[i];
        final boundName = (d['ric_pos_terminals'] as Map<String, dynamic>?)?['terminal_name'] as String?;
        final blocked = d['is_blocked'] as bool? ?? false;
        return Card(
          child: ListTile(
            leading: Icon(blocked ? Icons.block : Icons.devices_outlined, color: blocked ? AppColors.negative : null),
            title: Text(d['device_name'] as String? ?? 'Unnamed device'),
            subtitle: Text('${d['platform'] ?? '—'} · ${boundName ?? 'Not bound'}'),
            trailing: canEdit
                ? Wrap(spacing: 4, children: [
                    IconButton(icon: const Icon(Icons.swap_horiz, size: 18), tooltip: 'Rebind', onPressed: () => _rebind(context, d)),
                    IconButton(
                      icon: Icon(blocked ? Icons.lock_open : Icons.lock_outline, size: 18),
                      tooltip: blocked ? 'Unblock' : 'Block',
                      onPressed: () => _toggleBlock(d),
                    ),
                  ])
                : null,
          ),
        );
      },
    );
  }
}

// ── User Access & PIN tab ───────────────────────────────────────────────────

class _UserAccessTab extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> terminals;
  final bool canEdit;
  final void Function(String, {Color? color}) showMsg;

  const _UserAccessTab({required this.users, required this.terminals, required this.canEdit, required this.showMsg});

  @override
  ConsumerState<_UserAccessTab> createState() => _UserAccessTabState();
}

class _UserAccessTabState extends ConsumerState<_UserAccessTab> {
  String? _userId;
  Set<String> _selectedTerminalIds = {};
  bool _loadingAccess = false;
  bool _saving = false;

  String _userDisplay(Map<String, dynamic> u) => u['full_name'] as String? ?? '';

  Future<void> _selectUser(String? userId) async {
    setState(() { _userId = userId; _selectedTerminalIds = {}; });
    if (userId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingAccess = true);
    try {
      final selected = await PosTerminalAccessHelper.getForUser(clientId: session.clientId, companyId: session.companyId, userId: userId);
      if (mounted) setState(() { _selectedTerminalIds = selected; _loadingAccess = false; });
    } catch (e, st) {
      AppLogger.error('PosTerminalAccessLoad', e, st);
      if (mounted) {
        setState(() => _loadingAccess = false);
        widget.showMsg(ErrorPresenter.format(e, action: 'load terminal access'), color: AppColors.negative);
      }
    }
  }

  Future<void> _saveAccess() async {
    if (_userId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      await PosTerminalAccessHelper.save(
        clientId: session.clientId, companyId: session.companyId, userId: _userId!, selectedTerminalIds: _selectedTerminalIds,
      );
      if (mounted) widget.showMsg('Terminal access saved.', color: AppColors.positive);
    } catch (e, st) {
      AppLogger.error('PosTerminalAccessSave', e, st);
      widget.showMsg(ErrorPresenter.format(e, action: 'save terminal access'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setPin() async {
    if (_userId == null) return;
    final session = ref.read(sessionProvider)!;
    final pin = await showDialog<String>(context: context, builder: (_) => const _SetPinDialog());
    if (pin == null) return;
    try {
      await DioClient.instance.post('/rpc/fn_set_user_pin', data: {
        'p_client_id': session.clientId, 'p_company_id': session.companyId, 'p_user_id': _userId, 'p_new_pin': pin,
      });
      if (mounted) widget.showMsg('PIN set.', color: AppColors.positive);
    } catch (e, st) {
      AppLogger.error('PosSetUserPin', e, st);
      final msg = ErrorPresenter.format(e, action: 'set this PIN');
      if (mounted) widget.showMsg(msg, color: AppColors.negative);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Builder(builder: (context) {
                final selectedRows = widget.users.where((u) => u['id'] == _userId).toList();
                final selectedDisplay = selectedRows.isNotEmpty ? _userDisplay(selectedRows.first) : '';
                return SakalAutocomplete<Map<String, dynamic>>(
                  key: ValueKey(_userId),
                  initialValue: TextEditingValue(text: selectedDisplay),
                  displayStringForOption: _userDisplay,
                  optionsBuilder: (v) {
                    final q = v.text.toLowerCase().trim();
                    return q.isEmpty ? widget.users : widget.users.where((u) => _userDisplay(u).toLowerCase().contains(q));
                  },
                  onSelected: (u) => _selectUser(u['id'] as String),
                  onChanged: (v) { if (v.isEmpty && _userId != null) _selectUser(null); },
                  enabled: widget.canEdit,
                  decoration: const InputDecoration(labelText: 'Select User', prefixIcon: Icon(Icons.person_outline)),
                );
              }),
              if (_userId != null) ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Till PIN', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    OutlinedButton.icon(
                      onPressed: widget.canEdit ? _setPin : null,
                      icon: const Icon(Icons.pin_outlined, size: 16),
                      label: const Text('Set / Reset PIN'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text('Allowed Terminals', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                _loadingAccess
                    ? const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                    : Column(
                        children: widget.terminals.map((t) {
                          final id = t['id'] as String;
                          final locName = (t['ric_locations'] as Map<String, dynamic>?)?['location_name'] as String? ?? '';
                          return CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _selectedTerminalIds.contains(id),
                            title: Text('${t['terminal_code']} — ${t['terminal_name']}'),
                            subtitle: Text(locName, style: const TextStyle(fontSize: 11.5)),
                            onChanged: widget.canEdit
                                ? (checked) => setState(() {
                                      if (checked == true) {
                                        _selectedTerminalIds.add(id);
                                      } else {
                                        _selectedTerminalIds.remove(id);
                                      }
                                    })
                                : null,
                          );
                        }).toList(),
                      ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: (_saving || !widget.canEdit) ? null : _saveAccess,
                    child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save Access'),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog();
  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pinCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Enter a PIN.');
      return;
    }
    if (_pinCtrl.text != _confirmCtrl.text) {
      setState(() => _error = 'PINs don\'t match.');
      return;
    }
    Navigator.of(context).pop(_pinCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set Till PIN'),
      content: SizedBox(
        width: 300,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _pinCtrl, obscureText: true, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'New PIN'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _confirmCtrl, obscureText: true, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Confirm PIN'),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppColors.negative, fontSize: 12))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

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
  List<Map<String, dynamic>> _schemes = [];
  Map<String, dynamic>? _loyaltyProgram;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
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
        DioClient.instance.get('/rim_pos_schemes', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select': 'id,scheme_code,scheme_name,scheme_type,priority,is_stackable,is_active,'
              'rim_pos_scheme_rules(id,applies_to_product_id,applies_to_category_id,min_qty,benefit_type,benefit_value,'
              'rim_products!applies_to_product_id(product_name))',
          'order': 'priority.asc',
        }),
        DioClient.instance.get('/rim_loyalty_programs', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'order': 'created_at.asc', 'limit': '1',
        }),
      ]);
      if (!mounted) return;
      setState(() {
        _locations = List<Map<String, dynamic>>.from(results[0].data as List);
        _terminals = List<Map<String, dynamic>>.from(results[1].data as List);
        _devices = List<Map<String, dynamic>>.from(results[2].data as List);
        _users = List<Map<String, dynamic>>.from(results[3].data as List);
        _schemes = List<Map<String, dynamic>>.from(results[4].data as List);
        final loyaltyList = results[5].data as List;
        _loyaltyProgram = loyaltyList.isNotEmpty ? loyaltyList.first as Map<String, dynamic> : null;
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
            tabs: const [Tab(text: 'Terminals'), Tab(text: 'Devices'), Tab(text: 'User Access & PIN'), Tab(text: 'Schemes'), Tab(text: 'Loyalty')],
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
                        _SchemesTab(schemes: _schemes, canEdit: canEdit && !offline, onChanged: _loadAll, showMsg: _showMsg),
                        _LoyaltyTab(program: _loyaltyProgram, canEdit: canEdit && !offline, onChanged: _loadAll, showMsg: _showMsg),
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

/// Promotion/scheme engine admin (migration 212). Deliberately scoped to the
/// two most common real-world scheme types for v1's UI (PERCENT_OFF,
/// AMOUNT_OFF), single-product OR single-category scope, one rule per scheme
/// — the backend resolver (fn_resolve_pos_schemes_for_line) already supports
/// all 10 scheme_type values and multiple rule rows per scheme; this editor
/// simply doesn't expose the rest yet. A future pass can widen the form
/// without any backend change.
class _SchemesTab extends StatelessWidget {
  final List<Map<String, dynamic>> schemes;
  final bool canEdit;
  final VoidCallback onChanged;
  final void Function(String, {Color? color}) showMsg;

  const _SchemesTab({required this.schemes, required this.canEdit, required this.onChanged, required this.showMsg});

  Future<void> _openEditor(BuildContext context, {Map<String, dynamic>? existing}) async {
    await showDialog(
      context: context,
      builder: (_) => _SchemeEditorDialog(existing: existing, onSaved: onChanged, showMsg: showMsg),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (schemes.isEmpty)
        const Center(child: Text('No schemes configured yet.', style: TextStyle(color: AppColors.textSecondary)))
      else
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          itemCount: schemes.length,
          itemBuilder: (context, i) {
            final s = schemes[i];
            final rules = (s['rim_pos_scheme_rules'] as List?) ?? const [];
            final rule = rules.isNotEmpty ? rules.first as Map<String, dynamic> : null;
            final productName = (rule?['rim_products'] as Map<String, dynamic>?)?['product_name'] as String?;
            final active = s['is_active'] as bool? ?? true;
            final benefit = rule == null ? '' : '${rule['benefit_type'] == 'PERCENT' ? '${rule['benefit_value']}%' : rule['benefit_value']} off';
            return Card(
              child: ListTile(
                leading: const Icon(Icons.local_offer_outlined),
                title: Text('${s['scheme_code']} — ${s['scheme_name']}'),
                subtitle: Text('${s['scheme_type']} · $benefit${productName != null ? ' · $productName' : ''}${active ? '' : ' · Inactive'}'),
                trailing: canEdit ? const Icon(Icons.edit_outlined, size: 18) : null,
                onTap: canEdit ? () => _openEditor(context, existing: s) : null,
              ),
            );
          },
        ),
      if (canEdit)
        Positioned(
          right: 16, bottom: 16,
          child: FloatingActionButton.extended(onPressed: () => _openEditor(context), icon: const Icon(Icons.add), label: const Text('Add Scheme')),
        ),
    ]);
  }
}

class _SchemeEditorDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  final void Function(String, {Color? color}) showMsg;

  const _SchemeEditorDialog({required this.existing, required this.onSaved, required this.showMsg});

  @override
  ConsumerState<_SchemeEditorDialog> createState() => _SchemeEditorDialogState();
}

class _SchemeEditorDialogState extends ConsumerState<_SchemeEditorDialog> {
  late final _codeCtrl = TextEditingController(text: widget.existing?['scheme_code'] as String? ?? '');
  late final _nameCtrl = TextEditingController(text: widget.existing?['scheme_name'] as String? ?? '');
  late final _valueCtrl = TextEditingController(
      text: ((widget.existing?['rim_pos_scheme_rules'] as List?)?.isNotEmpty == true
              ? ((widget.existing!['rim_pos_scheme_rules'] as List).first as Map<String, dynamic>)['benefit_value']
              : null)
          ?.toString() ??
          '');
  String _benefitType = 'PERCENT';
  String _scope = 'PRODUCT';
  int _priority = 100;
  bool _stackable = false;
  bool _active = true;
  bool _saving = false;
  List<Map<String, dynamic>> _products = [];
  String? _productId;
  bool _loadingProducts = true;

  @override
  void initState() {
    super.initState();
    final existingRule = ((widget.existing?['rim_pos_scheme_rules'] as List?)?.isNotEmpty == true)
        ? ((widget.existing!['rim_pos_scheme_rules'] as List).first as Map<String, dynamic>)
        : null;
    _benefitType = existingRule?['benefit_type'] as String? ?? 'PERCENT';
    _productId = existingRule?['applies_to_product_id'] as String?;
    _priority = (widget.existing?['priority'] as num?)?.toInt() ?? 100;
    _stackable = widget.existing?['is_stackable'] as bool? ?? false;
    _active = widget.existing?['is_active'] as bool? ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProducts());
  }

  Future<void> _loadProducts() async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_products', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false', 'is_active': 'eq.true',
        'select': 'id,product_code,product_name', 'order': 'product_name.asc', 'limit': '500',
      });
      if (mounted) setState(() { _products = List<Map<String, dynamic>>.from(res.data as List); _loadingProducts = false; });
    } catch (e, st) {
      AppLogger.error('PosSchemeLoadProducts', e, st);
      if (mounted) setState(() => _loadingProducts = false);
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = double.tryParse(_valueCtrl.text.trim());
    if (_codeCtrl.text.trim().isEmpty || _nameCtrl.text.trim().isEmpty || value == null || value <= 0) {
      widget.showMsg('Code, name, and a positive discount value are all required.', color: AppColors.negative);
      return;
    }
    if (_scope == 'PRODUCT' && _productId == null) {
      widget.showMsg('Select which product this scheme applies to.', color: AppColors.negative);
      return;
    }
    setState(() => _saving = true);
    final session = ref.read(sessionProvider)!;
    try {
      String schemeId;
      if (widget.existing == null) {
        schemeId = const Uuid().v4();
        await DioClient.instance.post('/rim_pos_schemes', data: {
          'id': schemeId,
          'client_id': session.clientId,
          'company_id': session.companyId,
          'scheme_code': _codeCtrl.text.trim(),
          'scheme_name': _nameCtrl.text.trim(),
          'scheme_type': _benefitType == 'PERCENT' ? 'PERCENT_OFF' : 'AMOUNT_OFF',
          'scope': _scope,
          'priority': _priority,
          'is_stackable': _stackable,
        });
      } else {
        schemeId = widget.existing!['id'] as String;
        await DioClient.instance.patch('/rim_pos_schemes', queryParameters: {'id': 'eq.$schemeId'}, data: {
          'scheme_code': _codeCtrl.text.trim(),
          'scheme_name': _nameCtrl.text.trim(),
          'scheme_type': _benefitType == 'PERCENT' ? 'PERCENT_OFF' : 'AMOUNT_OFF',
          'scope': _scope,
          'priority': _priority,
          'is_stackable': _stackable,
          'is_active': _active,
        });
        // Full-replace the rule row, same "reseed" convention used elsewhere
        // in this app for a small child set — simpler than diffing one row.
        await DioClient.instance.patch('/rim_pos_scheme_rules', queryParameters: {'scheme_id': 'eq.$schemeId'}, data: {'is_deleted': true});
      }
      await DioClient.instance.post('/rim_pos_scheme_rules', data: {
        'id': const Uuid().v4(),
        'client_id': session.clientId,
        'company_id': session.companyId,
        'scheme_id': schemeId,
        'applies_to_product_id': _scope == 'PRODUCT' ? _productId : null,
        'min_qty': 0,
        'benefit_type': _benefitType,
        'benefit_value': value,
      });
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved();
        widget.showMsg('Scheme saved.', color: AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('PosSchemeSave', e, st);
      widget.showMsg(ErrorPresenter.format(e, action: 'save this scheme'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _productDisplay(Map<String, dynamic> p) => '[${p['product_code']}] ${p['product_name']}';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Scheme' : 'Edit Scheme'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _codeCtrl, decoration: const InputDecoration(labelText: 'Scheme Code')),
            const SizedBox(height: 10),
            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Scheme Name (e.g. Weekend 10% Off)')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _benefitType,
                  isExpanded: true, isDense: true, itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(value: 'PERCENT', child: Text('% Off')),
                    DropdownMenuItem(value: 'FIXED_AMOUNT', child: Text('Amount Off')),
                  ],
                  onChanged: (v) => setState(() => _benefitType = v!),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _valueCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Value'))),
            ]),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _scope,
              isExpanded: true, isDense: true, itemHeight: null,
              decoration: const InputDecoration(labelText: 'Applies To'),
              items: const [DropdownMenuItem(value: 'PRODUCT', child: Text('One Product'))],
              onChanged: (v) => setState(() => _scope = v!),
            ),
            const SizedBox(height: 10),
            if (_loadingProducts)
              const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else
              Builder(builder: (context) {
                final selected = _products.where((p) => p['id'] == _productId).toList();
                return SakalAutocomplete<Map<String, dynamic>>(
                  key: ValueKey(_productId),
                  initialValue: TextEditingValue(text: selected.isNotEmpty ? _productDisplay(selected.first) : ''),
                  displayStringForOption: _productDisplay,
                  optionsBuilder: (v) {
                    final q = v.text.toLowerCase().trim();
                    return q.isEmpty ? _products : _products.where((p) => _productDisplay(p).toLowerCase().contains(q));
                  },
                  onSelected: (p) => setState(() => _productId = p['id'] as String),
                  onChanged: (v) { if (v.isEmpty && _productId != null) setState(() => _productId = null); },
                  decoration: const InputDecoration(labelText: 'Product'),
                );
              }),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Priority (lower runs first)'),
                  controller: TextEditingController(text: _priority.toString()),
                  onChanged: (v) => _priority = int.tryParse(v) ?? _priority,
                ),
              ),
            ]),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Stackable with other schemes'), value: _stackable, onChanged: (v) => setState(() => _stackable = v)),
            if (widget.existing != null)
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: _active, onChanged: (v) => setState(() => _active = v)),
          ]),
        ),
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

/// Loyalty program admin (migration 214) — a single company-level
/// configuration row; the New Sale screen's own phone-capture UI is what
/// actually earns/redeems points against it.
class _LoyaltyTab extends ConsumerStatefulWidget {
  final Map<String, dynamic>? program;
  final bool canEdit;
  final VoidCallback onChanged;
  final void Function(String, {Color? color}) showMsg;

  const _LoyaltyTab({required this.program, required this.canEdit, required this.onChanged, required this.showMsg});

  @override
  ConsumerState<_LoyaltyTab> createState() => _LoyaltyTabState();
}

class _LoyaltyTabState extends ConsumerState<_LoyaltyTab> {
  late final _nameCtrl = TextEditingController(text: widget.program?['program_name'] as String? ?? 'Loyalty Rewards');
  late final _pointsPerAmountCtrl = TextEditingController(text: (widget.program?['points_per_amount'] as num?)?.toString() ?? '');
  late final _pointValueCtrl = TextEditingController(text: (widget.program?['point_value_in_base_currency'] as num?)?.toString() ?? '');
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _active = widget.program?['is_active'] as bool? ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pointsPerAmountCtrl.dispose();
    _pointValueCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pointsPerAmount = double.tryParse(_pointsPerAmountCtrl.text.trim());
    final pointValue = double.tryParse(_pointValueCtrl.text.trim());
    if (_nameCtrl.text.trim().isEmpty || pointsPerAmount == null || pointsPerAmount <= 0) {
      widget.showMsg('Program name and a positive "points per amount" are required.', color: AppColors.negative);
      return;
    }
    setState(() => _saving = true);
    final session = ref.read(sessionProvider)!;
    try {
      if (widget.program == null) {
        await DioClient.instance.post('/rim_loyalty_programs', data: {
          'id': const Uuid().v4(),
          'client_id': session.clientId,
          'company_id': session.companyId,
          'program_name': _nameCtrl.text.trim(),
          'points_per_amount': pointsPerAmount,
          'point_value_in_base_currency': pointValue ?? 0,
        });
      } else {
        await DioClient.instance.patch('/rim_loyalty_programs', queryParameters: {'id': 'eq.${widget.program!['id']}'}, data: {
          'program_name': _nameCtrl.text.trim(),
          'points_per_amount': pointsPerAmount,
          'point_value_in_base_currency': pointValue ?? 0,
          'is_active': _active,
        });
      }
      if (mounted) widget.showMsg('Loyalty program saved.', color: AppColors.positive);
      widget.onChanged();
    } catch (e, st) {
      AppLogger.error('PosLoyaltyProgramSave', e, st);
      if (mounted) widget.showMsg(ErrorPresenter.format(e, action: 'save the loyalty program'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Loyalty Program', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              const Text('Customers earn points on every cash/credit sale once a mobile number is captured at the till. Redemption is tracked but does not yet reduce the bill in this build.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              TextField(controller: _nameCtrl, enabled: widget.canEdit, decoration: const InputDecoration(labelText: 'Program Name')),
              const SizedBox(height: 10),
              TextField(controller: _pointsPerAmountCtrl, enabled: widget.canEdit, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Points earned per 1 (base currency) spent')),
              const SizedBox(height: 10),
              TextField(controller: _pointValueCtrl, enabled: widget.canEdit, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Value of 1 point (base currency, for future redemption)')),
              if (widget.program != null) ...[
                const SizedBox(height: 4),
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: _active, onChanged: widget.canEdit ? (v) => setState(() => _active = v) : null),
              ],
              const SizedBox(height: 12),
              if (widget.canEdit)
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
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
  List<Map<String, dynamic>> _bundles = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
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
          'select': 'id,terminal_code,terminal_name,receipt_paper_profile,receipt_printer_name,receipt_printer_url,is_active,location_id,ric_locations(location_name)',
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
          'select': 'id,scheme_code,scheme_name,scheme_type,scope,priority,is_stackable,is_active,'
              'rim_pos_scheme_rules(id,applies_to_product_id,applies_to_category_id,min_qty,max_qty,benefit_type,benefit_value,free_product_id,'
              'rim_products!applies_to_product_id(product_name))',
          'order': 'priority.asc',
        }),
        DioClient.instance.get('/rim_loyalty_programs', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'order': 'created_at.asc', 'limit': '1',
        }),
        DioClient.instance.get('/rim_product_bundles', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select': 'id,bundle_product_id,bundle_mode,is_active,'
              'rim_products!bundle_product_id(product_code,product_name),'
              'rim_bundle_components(id,component_product_id,component_qty,component_rate_contribution,'
              'rim_products!component_product_id(product_code,product_name))',
          'order': 'created_at.desc',
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
        _bundles = List<Map<String, dynamic>>.from(results[6].data as List);
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
            tabs: const [Tab(text: 'Terminals'), Tab(text: 'Devices'), Tab(text: 'User Access & PIN'), Tab(text: 'Schemes'), Tab(text: 'Loyalty'), Tab(text: 'Bundles')],
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
                        _BundlesTab(bundles: _bundles, canEdit: canEdit && !offline, onChanged: _loadAll, showMsg: _showMsg),
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
              subtitle: Text('$locName · ${t['receipt_paper_profile']}'
                  '${t['receipt_printer_name'] != null ? ' · Printer: ${t['receipt_printer_name']}' : ' · no printer configured'}'
                  '${active ? '' : ' · Inactive'}'),
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
  String? _printerUrl;
  String? _printerName;
  late final _printerUrlCtrl = TextEditingController(text: widget.existing?['receipt_printer_url'] as String? ?? '');
  List<Printer> _detectedPrinters = [];
  bool _detectingPrinters = false;
  // listPrinters() only works on a native desktop build, and only returns
  // THIS machine's own printers — if POS Setup is opened on the admin's own
  // PC rather than the till itself, the detected list won't be the till's
  // printers. Detection is still offered (the common case: a manager
  // configuring the printer directly on the till machine), with the manual
  // URL field underneath as the fallback for every other case.
  bool get _canDetectPrinters => !kIsWeb &&
      defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _locationId = widget.existing?['location_id'] as String?;
    _paperProfile = widget.existing?['receipt_paper_profile'] as String? ?? 'RECEIPT_80MM';
    _active = widget.existing?['is_active'] as bool? ?? true;
    _printerUrl = widget.existing?['receipt_printer_url'] as String?;
    _printerName = widget.existing?['receipt_printer_name'] as String?;
    if (_canDetectPrinters) _detectPrinters();
  }

  Future<void> _detectPrinters() async {
    setState(() => _detectingPrinters = true);
    try {
      final printers = await Printing.listPrinters();
      if (mounted) setState(() { _detectedPrinters = printers; _detectingPrinters = false; });
    } catch (_) {
      if (mounted) setState(() => _detectingPrinters = false);
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _printerUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_locationId == null || _codeCtrl.text.trim().isEmpty || _nameCtrl.text.trim().isEmpty) {
      widget.showMsg('Location, code, and name are all required.', color: AppColors.negative);
      return;
    }
    // Manual URL field (fallback when a printer wasn't picked from the
    // detected list) wins if the admin typed something into it.
    final manualUrl = _printerUrlCtrl.text.trim();
    final finalPrinterUrl = manualUrl.isNotEmpty ? manualUrl : _printerUrl;
    final finalPrinterName = manualUrl.isNotEmpty && manualUrl != _printerUrl ? manualUrl : _printerName;
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
          'receipt_printer_url': finalPrinterUrl,
          'receipt_printer_name': finalPrinterName,
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
            'receipt_printer_url': finalPrinterUrl,
            'receipt_printer_name': finalPrinterName,
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
          const SizedBox(height: 10),
          if (_canDetectPrinters) ...[
            if (_detectingPrinters)
              const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else
              DropdownButtonFormField<String>(
                // Guard against a saved printer URL that no longer appears
                // in this machine's own detected list (e.g. configured
                // from a different machine, or the printer was renamed/
                // unplugged) — DropdownButtonFormField asserts its value
                // matches exactly one item, so an unmatched value falls
                // back to "None" here rather than crashing; the manual URL
                // field below still shows/edits the real stored value.
                initialValue: _detectedPrinters.any((p) => p.url == _printerUrl) ? _printerUrl : null,
                isExpanded: true, isDense: true, itemHeight: null,
                decoration: InputDecoration(
                  labelText: 'Receipt Printer (detected on this machine)',
                  suffixIcon: IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _detectPrinters),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None — use dialog-based printing')),
                  ..._detectedPrinters.map((p) => DropdownMenuItem(value: p.url, child: Text(p.name))),
                ],
                onChanged: (v) => setState(() {
                  _printerUrl = v;
                  _printerName = v == null ? null : _detectedPrinters.firstWhere((p) => p.url == v).name;
                  _printerUrlCtrl.clear();
                }),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 4),
              child: Text('Configuring from a different machine than the till itself? Type the printer URL below instead.',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          ],
          TextField(
            controller: _printerUrlCtrl,
            decoration: const InputDecoration(labelText: 'Printer URL (manual override)', hintText: 'Leave blank to use the detected printer above'),
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

/// Promotion/scheme engine admin (migration 212).
///
/// Widened 2026-10-11 from the original 2-type/single-rule editor to cover
/// 8 of the 10 scheme_type values, PRODUCT or CATEGORY scope, and a
/// repeatable rule-row list (needed for SLAB_QUANTITY's multiple qty
/// bands) — all backed by fn_resolve_pos_schemes_for_line's EXISTING
/// resolution logic, confirmed by reading it directly: that function
/// never actually branches on scheme_type at all (it's purely a display/
/// categorization label) — the real computation is driven entirely by
/// each rule row's own benefit_type + min_qty/max_qty band + applies_to_
/// product/category. So BUY_X_GET_Y, BUY_X_GET_DISCOUNT, FIXED_PRICE_QTY,
/// MIX_AND_MATCH, SLAB_QUANTITY, and FREE_ITEM are all really just
/// different qty-band/benefit-type combinations under the hood, and this
/// editor can expose all of them with zero backend change.
///
/// BILL_THRESHOLD and COUPON are deliberately EXCLUDED from the type
/// dropdown — fn_resolve_pos_schemes_for_line explicitly filters them out
/// (`scheme_type NOT IN ('BILL_THRESHOLD','COUPON')`) because they need a
/// HEADER-level resolution pass (whole-bill total, or an explicit typed
/// code) that was never built, only ever planned as "213's own header-
/// level pass, not here" in a code comment. Offering them in the UI would
/// let an admin configure a scheme that silently never applies — a real
/// trap, not just an unfinished feature. Left as a clearly flagged future
/// item, not a silent gap.
class _SchemesTab extends StatelessWidget {
  final List<Map<String, dynamic>> schemes;
  final bool canEdit;
  final VoidCallback onChanged;
  final void Function(String, {Color? color}) showMsg;

  const _SchemesTab({required this.schemes, required this.canEdit, required this.onChanged, required this.showMsg});

  Future<void> _openEditor(BuildContext context, {Map<String, dynamic>? existing}) async {
    await showDialog(
      context: context,
      builder: (_) => _SchemeEditorDialog(
        existing: existing,
        onSaved: onChanged,
        showMsg: showMsg,
        existingCodes: schemes.map((s) => s['scheme_code'] as String).toSet(),
      ),
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
  // Every OTHER scheme's own code, used to auto-generate the next free one
  // for a brand-new scheme — a cashier/admin should never have to invent
  // or remember a code themselves (real user feedback, 2026-10-11).
  final Set<String> existingCodes;

  const _SchemeEditorDialog({required this.existing, required this.onSaved, required this.showMsg, this.existingCodes = const {}});

  @override
  ConsumerState<_SchemeEditorDialog> createState() => _SchemeEditorDialogState();
}

const _posSchemeTypes = ['PERCENT_OFF', 'AMOUNT_OFF', 'BUY_X_GET_Y', 'BUY_X_GET_DISCOUNT', 'FIXED_PRICE_QTY', 'MIX_AND_MATCH', 'SLAB_QUANTITY', 'FREE_ITEM'];
String _schemeTypeLabel(String t) => switch (t) {
      'PERCENT_OFF' => '% Off',
      'AMOUNT_OFF' => 'Amount Off',
      'BUY_X_GET_Y' => 'Buy X Get Y Free',
      'BUY_X_GET_DISCOUNT' => 'Buy X Get a Discount',
      'FIXED_PRICE_QTY' => 'Fixed Price for N Qty',
      'MIX_AND_MATCH' => 'Mix & Match',
      'SLAB_QUANTITY' => 'Slab / Tiered Quantity',
      'FREE_ITEM' => 'Free Item',
      _ => t,
    };

/// One editable rule row — a scheme can have several (e.g. SLAB_QUANTITY's
/// 1-2/3-5/6+ bands). Mirrors rim_pos_scheme_rules' own columns.
class _SchemeRuleDraft {
  double minQty;
  double? maxQty;
  String benefitType; // PERCENT | FIXED_AMOUNT | FIXED_PRICE | FREE_QTY
  double benefitValue;
  String? freeProductId;
  _SchemeRuleDraft({this.minQty = 0, this.maxQty, this.benefitType = 'PERCENT', this.benefitValue = 0, this.freeProductId});

  factory _SchemeRuleDraft.fromJson(Map<String, dynamic> j) => _SchemeRuleDraft(
        minQty: (j['min_qty'] as num?)?.toDouble() ?? 0,
        maxQty: (j['max_qty'] as num?)?.toDouble(),
        benefitType: j['benefit_type'] as String? ?? 'PERCENT',
        benefitValue: (j['benefit_value'] as num?)?.toDouble() ?? 0,
        freeProductId: j['free_product_id'] as String?,
      );
}

String _ruleBenefitTypeLabel(String t) => switch (t) {
      'PERCENT' => '% Off',
      'FIXED_AMOUNT' => 'Amount Off',
      'FIXED_PRICE' => 'Fixed Price',
      'FREE_QTY' => 'Free Qty',
      _ => t,
    };

/// Finds the lowest-numbered unused "SCH-NNN" code — not just COUNT+1, so a
/// deleted/renamed scheme in the middle of the sequence doesn't collide
/// with a code that's already taken (the same reasoning this schema
/// already requires scheme_code to be unique for).
String _nextSchemeCode(Set<String> existingCodes) {
  var n = 1;
  while (existingCodes.contains('SCH-${n.toString().padLeft(3, '0')}')) {
    n++;
  }
  return 'SCH-${n.toString().padLeft(3, '0')}';
}

class _SchemeEditorDialogState extends ConsumerState<_SchemeEditorDialog> {
  late final _codeCtrl = TextEditingController(
    text: widget.existing?['scheme_code'] as String? ?? _nextSchemeCode(widget.existingCodes),
  );
  late final _nameCtrl = TextEditingController(text: widget.existing?['scheme_name'] as String? ?? '');
  String _schemeType = 'PERCENT_OFF';
  String _scope = 'PRODUCT';
  int _priority = 100;
  bool _stackable = false;
  bool _active = true;
  bool _saving = false;
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _categories = [];
  String? _productId;
  String? _categoryId;
  bool _loadingPickers = true;
  late List<_SchemeRuleDraft> _rules;

  @override
  void initState() {
    super.initState();
    final existingRules = (widget.existing?['rim_pos_scheme_rules'] as List?) ?? const [];
    _rules = existingRules.isEmpty
        ? [_SchemeRuleDraft()]
        : existingRules.map((r) => _SchemeRuleDraft.fromJson(r as Map<String, dynamic>)).toList();
    final firstRule = existingRules.isNotEmpty ? existingRules.first as Map<String, dynamic> : null;
    _schemeType = widget.existing?['scheme_type'] as String? ?? 'PERCENT_OFF';
    _productId = firstRule?['applies_to_product_id'] as String?;
    _categoryId = firstRule?['applies_to_category_id'] as String?;
    _scope = widget.existing?['scope'] as String? ?? (_categoryId != null ? 'CATEGORY' : 'PRODUCT');
    _priority = (widget.existing?['priority'] as num?)?.toInt() ?? 100;
    _stackable = widget.existing?['is_stackable'] as bool? ?? false;
    _active = widget.existing?['is_active'] as bool? ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPickers());
  }

  Future<void> _loadPickers() async {
    final session = ref.read(sessionProvider)!;
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_products', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'is_active': 'eq.true',
          'select': 'id,product_code,product_name', 'order': 'product_name.asc', 'limit': '500',
        }),
        DioClient.instance.get('/rim_item_categories', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false', 'is_active': 'eq.true',
          'select': 'id,category_name', 'order': 'category_name.asc', 'limit': '500',
        }),
      ]);
      if (mounted) {
        setState(() {
          _products = List<Map<String, dynamic>>.from(results[0].data as List);
          _categories = List<Map<String, dynamic>>.from(results[1].data as List);
          _loadingPickers = false;
        });
      }
    } catch (e, st) {
      AppLogger.error('PosSchemeLoadPickers', e, st);
      if (mounted) setState(() => _loadingPickers = false);
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_codeCtrl.text.trim().isEmpty || _nameCtrl.text.trim().isEmpty) {
      widget.showMsg('Code and name are both required.', color: AppColors.negative);
      return;
    }
    if (_scope == 'PRODUCT' && _productId == null) {
      widget.showMsg('Select which product this scheme applies to.', color: AppColors.negative);
      return;
    }
    if (_scope == 'CATEGORY' && _categoryId == null) {
      widget.showMsg('Select which category this scheme applies to.', color: AppColors.negative);
      return;
    }
    if (_rules.any((r) => r.benefitType != 'FREE_QTY' && r.benefitValue <= 0)) {
      widget.showMsg('Every rule needs a positive value.', color: AppColors.negative);
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
          'scheme_type': _schemeType,
          'scope': _scope,
          'priority': _priority,
          'is_stackable': _stackable,
        });
      } else {
        schemeId = widget.existing!['id'] as String;
        await DioClient.instance.patch('/rim_pos_schemes', queryParameters: {'id': 'eq.$schemeId'}, data: {
          'scheme_code': _codeCtrl.text.trim(),
          'scheme_name': _nameCtrl.text.trim(),
          'scheme_type': _schemeType,
          'scope': _scope,
          'priority': _priority,
          'is_stackable': _stackable,
          'is_active': _active,
        });
        // Full-replace every rule row, same "reseed" convention used
        // elsewhere in this app for a small child set — simpler than
        // diffing N rows against whatever was there before.
        await DioClient.instance.patch('/rim_pos_scheme_rules', queryParameters: {'scheme_id': 'eq.$schemeId'}, data: {'is_deleted': true});
      }
      final ruleRows = _rules.map((r) => {
            'id': const Uuid().v4(),
            'client_id': session.clientId,
            'company_id': session.companyId,
            'scheme_id': schemeId,
            'applies_to_product_id': _scope == 'PRODUCT' ? _productId : null,
            'applies_to_category_id': _scope == 'CATEGORY' ? _categoryId : null,
            'min_qty': r.minQty,
            'max_qty': r.maxQty,
            'benefit_type': r.benefitType,
            'benefit_value': r.benefitValue,
            'free_product_id': r.benefitType == 'FREE_QTY' ? r.freeProductId : null,
          }).toList();
      await DioClient.instance.post('/rim_pos_scheme_rules', data: ruleRows);
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

  Widget _buildRuleRow(_SchemeRuleDraft r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, labelText: 'Min Qty'),
              controller: TextEditingController(text: r.minQty.toString()),
              onChanged: (v) => r.minQty = double.tryParse(v) ?? r.minQty,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, labelText: 'Max Qty (optional)'),
              controller: TextEditingController(text: r.maxQty?.toString() ?? ''),
              onChanged: (v) => r.maxQty = double.tryParse(v),
            ),
          ),
          IconButton(
            onPressed: _rules.length <= 1 ? null : () => setState(() => _rules.remove(r)),
            icon: const Icon(Icons.close, size: 18, color: AppColors.negative),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: r.benefitType,
              isExpanded: true, isDense: true, itemHeight: null,
              decoration: const InputDecoration(labelText: 'Benefit'),
              items: const ['PERCENT', 'FIXED_AMOUNT', 'FIXED_PRICE', 'FREE_QTY']
                  .map((b) => DropdownMenuItem(value: b, child: Text(_ruleBenefitTypeLabel(b))))
                  .toList(),
              onChanged: (v) => setState(() => r.benefitType = v!),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              keyboardType: TextInputType.number,
              decoration: InputDecoration(isDense: true, labelText: r.benefitType == 'FREE_QTY' ? 'Free Qty' : 'Value'),
              controller: TextEditingController(text: r.benefitValue.toString()),
              onChanged: (v) => r.benefitValue = double.tryParse(v) ?? r.benefitValue,
            ),
          ),
        ]),
        if (r.benefitType == 'FREE_QTY' && !_loadingPickers) ...[
          const SizedBox(height: 6),
          Builder(builder: (context) {
            final selected = _products.where((p) => p['id'] == r.freeProductId).toList();
            return SakalAutocomplete<Map<String, dynamic>>(
              key: ValueKey(r.freeProductId),
              initialValue: TextEditingValue(text: selected.isNotEmpty ? _productDisplay(selected.first) : ''),
              displayStringForOption: _productDisplay,
              optionsBuilder: (v) {
                final q = v.text.toLowerCase().trim();
                return q.isEmpty ? _products : _products.where((p) => _productDisplay(p).toLowerCase().contains(q));
              },
              onSelected: (p) => setState(() => r.freeProductId = p['id'] as String),
              onChanged: (v) { if (v.isEmpty) r.freeProductId = null; },
              decoration: const InputDecoration(labelText: 'Free Product (leave blank = same product free)'),
            );
          }),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Scheme' : 'Edit Scheme'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _codeCtrl,
              readOnly: true,
              decoration: const InputDecoration(labelText: 'Scheme Code', helperText: 'Assigned automatically', filled: true, fillColor: AppColors.background),
            ),
            const SizedBox(height: 10),
            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Scheme Name (e.g. Weekend 10% Off)')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _schemeType,
              isExpanded: true, isDense: true, itemHeight: null,
              decoration: const InputDecoration(labelText: 'Scheme Type'),
              items: _posSchemeTypes.map((t) => DropdownMenuItem(value: t, child: Text(_schemeTypeLabel(t)))).toList(),
              onChanged: (v) => setState(() => _schemeType = v!),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _scope,
              isExpanded: true, isDense: true, itemHeight: null,
              decoration: const InputDecoration(labelText: 'Applies To'),
              items: const [
                DropdownMenuItem(value: 'PRODUCT', child: Text('One Product')),
                DropdownMenuItem(value: 'CATEGORY', child: Text('A Category')),
              ],
              onChanged: (v) => setState(() => _scope = v!),
            ),
            const SizedBox(height: 10),
            if (_loadingPickers)
              const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else if (_scope == 'PRODUCT')
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
              })
            else
              DropdownButtonFormField<String>(
                initialValue: _categories.any((c) => c['id'] == _categoryId) ? _categoryId : null,
                isExpanded: true, isDense: true, itemHeight: null,
                decoration: const InputDecoration(labelText: 'Category'),
                items: _categories.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['category_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            const SizedBox(height: 14),
            const Text('Rules', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
            const SizedBox(height: 6),
            ..._rules.map(_buildRuleRow),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _rules.add(_SchemeRuleDraft())),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Rule (e.g. a slab band)'),
              ),
            ),
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

/// Bundle admin (migration 216) — a bundle is itself a row in rim_products
/// (its own barcode/price/tax group, scannable like any product); this tab
/// only adds the bundle-specific metadata (mode + component list).
///
/// PREASSEMBLED mode: the bundle product carries real stock, built via
/// the existing Stock Adjustment screen; a POS sale of it is just an
/// ordinary stocked-product sale. COMMERCIAL mode (auto-consume
/// components at sale time, no bundle stock of its own) is fully wired as
/// of migration 219 — fn_approve_sales_invoice explodes the bundle line
/// into one stock movement + GL pair per component, scaled by qty sold. A
/// batch/serial-tracked component is explicitly not supported (no
/// allocation UI exists for a bundle's own components) and raises a clear
/// error at approve rather than mis-posting. DYNAMIC_MIX has no admin UI
/// here at all — per the original design, it's realized entirely through
/// a MIX_AND_MATCH scheme (Schemes tab), not a bundle row.
class _BundlesTab extends StatelessWidget {
  final List<Map<String, dynamic>> bundles;
  final bool canEdit;
  final VoidCallback onChanged;
  final void Function(String, {Color? color}) showMsg;

  const _BundlesTab({required this.bundles, required this.canEdit, required this.onChanged, required this.showMsg});

  Future<void> _openEditor(BuildContext context, {Map<String, dynamic>? existing}) async {
    await showDialog(
      context: context,
      builder: (_) => _BundleEditorDialog(existing: existing, onSaved: onChanged, showMsg: showMsg),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (bundles.isEmpty)
        const Center(child: Text('No bundles configured yet.', style: TextStyle(color: AppColors.textSecondary)))
      else
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          itemCount: bundles.length,
          itemBuilder: (context, i) {
            final b = bundles[i];
            final product = b['rim_products'] as Map<String, dynamic>?;
            final components = (b['rim_bundle_components'] as List?) ?? const [];
            final active = b['is_active'] as bool? ?? true;
            return Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text('[${product?['product_code']}] ${product?['product_name']}'),
                subtitle: Text('${b['bundle_mode']} · ${components.length} component(s)${active ? '' : ' · Inactive'}'),
                trailing: canEdit ? const Icon(Icons.edit_outlined, size: 18) : null,
                onTap: canEdit ? () => _openEditor(context, existing: b) : null,
              ),
            );
          },
        ),
      if (canEdit)
        Positioned(
          right: 16, bottom: 16,
          child: FloatingActionButton.extended(onPressed: () => _openEditor(context), icon: const Icon(Icons.add), label: const Text('Add Bundle')),
        ),
    ]);
  }
}

class _BundleComponentDraft {
  String? productId;
  double qty;
  double? rateContribution;
  _BundleComponentDraft({this.productId, this.qty = 1, this.rateContribution});
}

class _BundleEditorDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  final void Function(String, {Color? color}) showMsg;

  const _BundleEditorDialog({required this.existing, required this.onSaved, required this.showMsg});

  @override
  ConsumerState<_BundleEditorDialog> createState() => _BundleEditorDialogState();
}

class _BundleEditorDialogState extends ConsumerState<_BundleEditorDialog> {
  String? _bundleProductId;
  String _bundleMode = 'PREASSEMBLED';
  bool _active = true;
  bool _saving = false;
  List<Map<String, dynamic>> _products = [];
  bool _loadingProducts = true;
  late List<_BundleComponentDraft> _components;
  String? _bundleProductDisplayFallback;

  @override
  void initState() {
    super.initState();
    final product = widget.existing?['rim_products'] as Map<String, dynamic>?;
    _bundleProductId = widget.existing?['bundle_product_id'] as String?;
    _bundleMode = widget.existing?['bundle_mode'] as String? ?? 'PREASSEMBLED';
    _active = widget.existing?['is_active'] as bool? ?? true;
    final existingComponents = (widget.existing?['rim_bundle_components'] as List?) ?? const [];
    _components = existingComponents.isEmpty
        ? [_BundleComponentDraft()]
        : existingComponents.map((c) {
            final m = c as Map<String, dynamic>;
            return _BundleComponentDraft(
              productId: m['component_product_id'] as String?,
              qty: (m['component_qty'] as num?)?.toDouble() ?? 1,
              rateContribution: (m['component_rate_contribution'] as num?)?.toDouble(),
            );
          }).toList();
    // Only used for display continuity while products load — not written back.
    if (product != null) _bundleProductDisplayFallback = '[${product['product_code']}] ${product['product_name']}';
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
      if (mounted) {
        setState(() { _products = List<Map<String, dynamic>>.from(res.data as List); _loadingProducts = false; });
      }
    } catch (e, st) {
      AppLogger.error('PosBundleLoadProducts', e, st);
      if (mounted) setState(() => _loadingProducts = false);
    }
  }

  Future<void> _save() async {
    if (_bundleProductId == null) {
      widget.showMsg('Select which product is the bundle itself.', color: AppColors.negative);
      return;
    }
    if (_components.any((c) => c.productId == null)) {
      widget.showMsg('Every component row needs a product.', color: AppColors.negative);
      return;
    }
    setState(() => _saving = true);
    final session = ref.read(sessionProvider)!;
    try {
      String bundleId;
      if (widget.existing == null) {
        bundleId = const Uuid().v4();
        await DioClient.instance.post('/rim_product_bundles', data: {
          'id': bundleId,
          'client_id': session.clientId,
          'company_id': session.companyId,
          'bundle_product_id': _bundleProductId,
          'bundle_mode': _bundleMode,
        });
      } else {
        bundleId = widget.existing!['id'] as String;
        await DioClient.instance.patch('/rim_product_bundles', queryParameters: {'id': 'eq.$bundleId'}, data: {
          'bundle_mode': _bundleMode,
          'is_active': _active,
        });
        await DioClient.instance.patch('/rim_bundle_components', queryParameters: {'bundle_id': 'eq.$bundleId'}, data: {'is_deleted': true});
      }
      final componentRows = _components.map((c) => {
            'id': const Uuid().v4(),
            'client_id': session.clientId,
            'company_id': session.companyId,
            'bundle_id': bundleId,
            'component_product_id': c.productId,
            'component_qty': c.qty,
            'component_rate_contribution': c.rateContribution,
          }).toList();
      await DioClient.instance.post('/rim_bundle_components', data: componentRows);
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved();
        widget.showMsg('Bundle saved.', color: AppColors.positive);
      }
    } catch (e, st) {
      AppLogger.error('PosBundleSave', e, st);
      widget.showMsg(ErrorPresenter.format(e, action: 'save this bundle'), color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _productDisplay(Map<String, dynamic> p) => '[${p['product_code']}] ${p['product_name']}';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Bundle' : 'Edit Bundle'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_loadingProducts)
              const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
            else if (widget.existing != null)
              // The bundle's own product identity never changes once
              // created (rim_product_bundles.bundle_product_id is UNIQUE
              // and is the join key everything else here hangs off) —
              // shown read-only rather than offered as an editable picker.
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_bundleProductDisplayFallback ?? 'Bundle Product', style: const TextStyle(fontWeight: FontWeight.w700)),
              )
            else
              Builder(builder: (context) {
                final selected = _products.where((p) => p['id'] == _bundleProductId).toList();
                return SakalAutocomplete<Map<String, dynamic>>(
                  key: ValueKey(_bundleProductId),
                  initialValue: TextEditingValue(text: selected.isNotEmpty ? _productDisplay(selected.first) : ''),
                  displayStringForOption: _productDisplay,
                  optionsBuilder: (v) {
                    final q = v.text.toLowerCase().trim();
                    return q.isEmpty ? _products : _products.where((p) => _productDisplay(p).toLowerCase().contains(q));
                  },
                  onSelected: (p) => setState(() => _bundleProductId = p['id'] as String),
                  onChanged: (v) { if (v.isEmpty && _bundleProductId != null) setState(() => _bundleProductId = null); },
                  decoration: const InputDecoration(labelText: 'Bundle Product (an existing product marked as a bundle)'),
                );
              }),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _bundleMode,
              isExpanded: true, isDense: true, itemHeight: null,
              decoration: const InputDecoration(labelText: 'Mode'),
              items: const [
                DropdownMenuItem(value: 'PREASSEMBLED', child: Text('Preassembled — carries its own stock')),
                DropdownMenuItem(value: 'COMMERCIAL', child: Text('Commercial — auto-consume components at sale time')),
              ],
              onChanged: (v) => setState(() => _bundleMode = v!),
            ),
            if (_bundleMode == 'COMMERCIAL')
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Selling this bundle will deduct every component\'s own stock, scaled by the qty sold. '
                  'A batch/serial-tracked component is not yet supported — the sale will be blocked with a clear error if one is used.',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            const SizedBox(height: 14),
            const Text('Components', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
            const SizedBox(height: 6),
            if (!_loadingProducts)
              ..._components.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Expanded(
                        child: Builder(builder: (context) {
                          final selected = _products.where((p) => p['id'] == c.productId).toList();
                          return SakalAutocomplete<Map<String, dynamic>>(
                            key: ValueKey(c.productId),
                            initialValue: TextEditingValue(text: selected.isNotEmpty ? _productDisplay(selected.first) : ''),
                            displayStringForOption: _productDisplay,
                            optionsBuilder: (v) {
                              final q = v.text.toLowerCase().trim();
                              return q.isEmpty ? _products : _products.where((p) => _productDisplay(p).toLowerCase().contains(q));
                            },
                            onSelected: (p) => c.productId = p['id'] as String,
                            onChanged: (v) { if (v.isEmpty) c.productId = null; },
                            decoration: const InputDecoration(isDense: true, labelText: 'Component Product'),
                          );
                        }),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 70,
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true, labelText: 'Qty'),
                          controller: TextEditingController(text: c.qty.toString()),
                          onChanged: (v) => c.qty = double.tryParse(v) ?? c.qty,
                        ),
                      ),
                      IconButton(
                        onPressed: _components.length <= 1 ? null : () => setState(() => _components.remove(c)),
                        icon: const Icon(Icons.close, size: 18, color: AppColors.negative),
                      ),
                    ]),
                  )),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _components.add(_BundleComponentDraft())),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Component'),
              ),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: 4),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: _active, onChanged: (v) => setState(() => _active = v)),
            ],
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

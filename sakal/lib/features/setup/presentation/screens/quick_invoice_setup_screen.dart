import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/utils/screen_permission_mixin.dart';

/// Quick Invoice Setup — per-user cash-sale defaults (088_quick_invoice_config.sql:
/// ric_user_quick_invoice_setup). Admin-facing, same "pick a user, edit their
/// own row" shape as Permissions screen's Sales Controls card, but as its
/// own dedicated screen (locked-state banner needs more room than a card).
///
/// Direct DioClient calls, no repository layer — same convention as
/// permissions_screen.dart for this class of admin/setup screen (not a
/// transactional module).
class QuickInvoiceSetupScreen extends ConsumerStatefulWidget {
  const QuickInvoiceSetupScreen({super.key});

  @override
  ConsumerState<QuickInvoiceSetupScreen> createState() => _QuickInvoiceSetupScreenState();
}

class _QuickInvoiceSetupScreenState extends ConsumerState<QuickInvoiceSetupScreen>
    with ScreenPermissionMixin<QuickInvoiceSetupScreen> {
  @override
  String get screenName => '/setup/quick-invoice-setup';

  List<Map<String, dynamic>> _users = [];
  bool _loadingUsers = true;
  String? _error;

  String? _selectedUserId;
  bool _loadingSetup = false;
  bool _saving = false;
  bool _locked = false;
  int _invoiceCount = 0;

  String? _rowId;
  String? _locationId;
  String? _cashCustomerId;
  String  _cashCustomerDisplay = '';
  String? _localCashAccountId;
  String  _localCashAccountDisplay = '';
  String? _baseCashAccountId;
  String  _baseCashAccountDisplay = '';
  String? _defaultSalesPersonId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadUsers());
  }

  Future<void> _loadUsers() async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get('/rim_users', queryParameters: {
        'client_id':  'eq.${session.clientId}',
        'company_id': 'eq.${session.companyId}',
        'is_deleted': 'eq.false',
        'select':     'id,full_name,is_active',
        'order':      'full_name.asc',
      });
      if (mounted) {
        setState(() {
          _users = List<Map<String, dynamic>>.from(res.data as List);
          _loadingUsers = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loadingUsers = false; _error = 'Could not load users.'; });
    }
  }

  Future<void> _selectUser(String userId) async {
    setState(() {
      _selectedUserId = userId;
      _loadingSetup = true;
      _rowId = null;
      _locationId = null;
      _cashCustomerId = null;
      _cashCustomerDisplay = '';
      _localCashAccountId = null;
      _localCashAccountDisplay = '';
      _baseCashAccountId = null;
      _baseCashAccountDisplay = '';
      _defaultSalesPersonId = null;
      _locked = false;
      _invoiceCount = 0;
      _error = null;
    });
    final session = ref.read(sessionProvider)!;
    try {
      final results = await Future.wait([
        DioClient.instance.get('/ric_user_quick_invoice_setup', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'user_id': 'eq.$userId', 'is_deleted': 'eq.false',
          'select': '*,cash_customer:rim_accounts!cash_customer_id(account_code,account_name),'
              'local_cash_account:rim_accounts!local_cash_account_id(account_code,account_name),'
              'base_cash_account:rim_accounts!base_cash_account_id(account_code,account_name)',
          'limit': '1',
        }),
        DioClient.instance.get('/rih_sales_invoices', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'created_by': 'eq.$userId', 'is_deleted': 'eq.false',
          'select': 'id', 'limit': '1',
        }),
      ]);
      final setupList = results[0].data as List;
      final invoiceList = results[1].data as List;
      if (mounted) {
        setState(() {
          _locked = invoiceList.isNotEmpty;
          _invoiceCount = invoiceList.length;
          if (setupList.isNotEmpty) {
            final row = setupList.first as Map<String, dynamic>;
            final cashCustomer = row['cash_customer'] as Map<String, dynamic>?;
            final localAcc = row['local_cash_account'] as Map<String, dynamic>?;
            final baseAcc = row['base_cash_account'] as Map<String, dynamic>?;
            _rowId = row['id'] as String;
            _locationId = row['location_id'] as String?;
            _cashCustomerId = row['cash_customer_id'] as String?;
            _cashCustomerDisplay = cashCustomer == null ? '' : '[${cashCustomer['account_code']}] ${cashCustomer['account_name']}';
            _localCashAccountId = row['local_cash_account_id'] as String?;
            _localCashAccountDisplay = localAcc == null ? '' : '[${localAcc['account_code']}] ${localAcc['account_name']}';
            _baseCashAccountId = row['base_cash_account_id'] as String?;
            _baseCashAccountDisplay = baseAcc == null ? '' : '[${baseAcc['account_code']}] ${baseAcc['account_name']}';
            _defaultSalesPersonId = row['default_sales_person_id'] as String?;
          }
          _loadingSetup = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loadingSetup = false; _error = 'Could not load Quick Invoice Setup.'; });
    }
  }

  Future<void> _save() async {
    if (_selectedUserId == null || _locked) return;
    if (_locationId == null || _cashCustomerId == null || _localCashAccountId == null || _baseCashAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() { _saving = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    final payload = {
      'client_id': session.clientId,
      'company_id': session.companyId,
      'user_id': _selectedUserId,
      'location_id': _locationId,
      'cash_customer_id': _cashCustomerId,
      'local_cash_account_id': _localCashAccountId,
      'base_cash_account_id': _baseCashAccountId,
      'default_sales_person_id': _defaultSalesPersonId,
      'is_active': true,
      'updated_by': session.userId,
    };
    try {
      if (_rowId == null) {
        final res = await DioClient.instance.post('/ric_user_quick_invoice_setup',
            data: {...payload, 'created_by': session.userId},
            options: Options(headers: {'Prefer': 'return=representation'}));
        final list = res.data as List;
        if (mounted && list.isNotEmpty) setState(() => _rowId = (list.first as Map<String, dynamic>)['id'] as String);
      } else {
        await DioClient.instance.patch('/ric_user_quick_invoice_setup',
            queryParameters: {'id': 'eq.$_rowId'}, data: payload);
      }
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Quick Invoice Setup saved.'), backgroundColor: AppColors.positive),
        );
      }
    } on DioException catch (e) {
      if (mounted) setState(() { _saving = false; _error = e.response?.data?['message'] ?? 'Save failed.'; });
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Unexpected error: $e'; });
    }
  }

  static Widget _req(String text) => RichText(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
          children: const [TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final showButtons = !_loadingSetup && _selectedUserId != null && !_locked && (canAdd || canEdit);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: isMobile
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildTitleBlock(),
                  if (showButtons) ...[
                    const SizedBox(height: 10),
                    Row(children: [_buildActionButtons()]),
                  ],
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildTitleBlock()),
                  if (showButtons) _buildActionButtons(),
                ]),
        ),
        const Divider(height: 20),
        Expanded(
          child: _loadingUsers
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_error != null)
                    Padding(padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!, style: const TextStyle(color: AppColors.negative))),
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'User', border: OutlineInputBorder()),
                    isExpanded: true, isDense: true, itemHeight: null,
                    initialValue: _selectedUserId,
                    items: _users.map((u) => DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text(u['full_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                    onChanged: (v) { if (v != null) unawaited(_selectUser(v)); },
                  ),
                  const SizedBox(height: 20),
                  if (_loadingSetup) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
                  if (!_loadingSetup && _selectedUserId != null) ...[
                    if (_locked)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: AppColors.secondary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.lock_outline, size: 18, color: AppColors.secondary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Locked — this user has already made $_invoiceCount Quick Invoice(s). '
                              'Setup can no longer be changed.',
                              style: const TextStyle(fontSize: 13, color: AppColors.secondary),
                            ),
                          ),
                        ]),
                      ),
                    _buildLocationField(),
                    const SizedBox(height: 16),
                    _buildAccountPicker(
                      label: 'Cash Customer',
                      required: true,
                      display: _cashCustomerDisplay,
                      natureFilter: 'Customer',
                      onSelected: (a) => setState(() {
                        _cashCustomerId = a['id'] as String;
                        _cashCustomerDisplay = '[${a['account_code']}] ${a['account_name']}';
                      }),
                    ),
                    const SizedBox(height: 16),
                    _buildAccountPicker(
                      label: 'Local Cash Account',
                      required: true,
                      display: _localCashAccountDisplay,
                      natureFilter: null,
                      onSelected: (a) => setState(() {
                        _localCashAccountId = a['id'] as String;
                        _localCashAccountDisplay = '[${a['account_code']}] ${a['account_name']}';
                      }),
                    ),
                    const SizedBox(height: 16),
                    _buildAccountPicker(
                      label: 'Base Cash Account',
                      required: true,
                      display: _baseCashAccountDisplay,
                      natureFilter: null,
                      onSelected: (a) => setState(() {
                        _baseCashAccountId = a['id'] as String;
                        _baseCashAccountDisplay = '[${a['account_code']}] ${a['account_name']}';
                      }),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(labelText: 'Default Sales Person (optional)', border: OutlineInputBorder()),
                      isExpanded: true, isDense: true, itemHeight: null,
                      initialValue: _defaultSalesPersonId,
                      items: [
                        const DropdownMenuItem(value: null, child: Text('— None —')),
                        ..._users.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['full_name'] as String, overflow: TextOverflow.ellipsis))),
                      ],
                      onChanged: _locked ? null : (v) => setState(() => _defaultSalesPersonId = v),
                    ),
                  ],
                ]),
              ),
            ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock() => const Text('Quick Invoice Setup',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.primary));

  Widget _buildActionButtons() => FilledButton.icon(
        onPressed: (_locked || _saving) ? null : _save,
        icon: _saving
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.save_outlined, size: 18),
        label: const Text('Save'),
      );

  Widget _buildLocationField() {
    final locationsAsync = ref.watch(locationsProvider);
    return locationsAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, __) => const Text('Could not load locations.', style: TextStyle(color: AppColors.negative)),
      data: (locations) => DropdownButtonFormField<String>(
        decoration: InputDecoration(label: _req('Location'), border: const OutlineInputBorder()),
        isExpanded: true, isDense: true, itemHeight: null,
        initialValue: _locationId,
        items: locations.map((l) => DropdownMenuItem(
            value: l['id'] as String,
            child: Text(l['location_name'] as String, overflow: TextOverflow.ellipsis))).toList(),
        onChanged: _locked ? null : (v) => setState(() => _locationId = v),
      ),
    );
  }

  Widget _buildAccountPicker({
    required String label,
    required bool required,
    required String display,
    required String? natureFilter,
    required ValueChanged<Map<String, dynamic>> onSelected,
  }) {
    if (_locked) {
      return InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        child: Text(display.isEmpty ? '—' : display, style: const TextStyle(fontSize: 13)),
      );
    }
    return Autocomplete<Map<String, dynamic>>(
      initialValue: TextEditingValue(text: display),
      displayStringForOption: (a) => '[${a['account_code']}] ${a['account_name']}',
      optionsBuilder: (v) async {
        final accounts = await ref.read(accountsProvider.future);
        final filtered = natureFilter == null
            ? accounts.where((a) => a['posting_allowed'] != false)
            : accounts.where((a) => a['account_nature'] == natureFilter && a['posting_allowed'] != false);
        final q = v.text.toLowerCase().trim();
        if (q.isEmpty) return filtered;
        return filtered.where((a) =>
            (a['account_code'] as String).toLowerCase().contains(q) ||
            (a['account_name'] as String).toLowerCase().contains(q));
      },
      onSelected: onSelected,
      fieldViewBuilder: (context, textCtrl, focusNode, onFieldSubmitted) => TextFormField(
        controller: textCtrl, focusNode: focusNode,
        decoration: InputDecoration(label: required ? _req(label) : Text(label), border: const OutlineInputBorder()),
        style: const TextStyle(fontSize: 13),
      ),
      optionsViewBuilder: (context, onSel, opts) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4, borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, minWidth: 280),
            child: ListView.builder(
              padding: EdgeInsets.zero, shrinkWrap: true, itemCount: opts.length,
              itemBuilder: (context, idx) {
                final a = opts.elementAt(idx);
                return InkWell(
                  onTap: () => onSel(a),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('[${a['account_code']}] ${a['account_name']}', style: const TextStyle(fontSize: 13)),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

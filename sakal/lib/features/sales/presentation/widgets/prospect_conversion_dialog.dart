import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/sales_order_providers.dart';

const _partyTypes = ['Individual', 'Company', 'Partnership', 'Government'];

/// Prospect -> Customer conversion wizard — a deliberately minimal
/// Customer Master creation form (not a full replica of
/// customer_master_screen.dart — city/country pickers are skipped since
/// this is a quick "convert what's needed to place an order" step, not a
/// full onboarding form; those can always be completed later from the
/// real Customer Master screen). Pre-filled from the source quotation's
/// own party_name/phone/email/address snapshot.
///
/// Returns `true` if the conversion succeeded (the caller should then
/// re-fetch the quotation header — customer_id/customer_type will have
/// changed), `false`/`null` if cancelled.
Future<bool?> showProspectConversionDialog(
  BuildContext context, {
  required WidgetRef ref,
  required String quotationNo,
  required String quotationDate,
  required String prefillName,
  required String prefillPhone,
  required String prefillEmail,
  required String prefillAddress,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProspectConversionDialog(
      ref: ref,
      quotationNo: quotationNo,
      quotationDate: quotationDate,
      prefillName: prefillName,
      prefillPhone: prefillPhone,
      prefillEmail: prefillEmail,
      prefillAddress: prefillAddress,
    ),
  );
}

class _ProspectConversionDialog extends ConsumerStatefulWidget {
  final WidgetRef ref;
  final String quotationNo;
  final String quotationDate;
  final String prefillName;
  final String prefillPhone;
  final String prefillEmail;
  final String prefillAddress;

  const _ProspectConversionDialog({
    required this.ref,
    required this.quotationNo,
    required this.quotationDate,
    required this.prefillName,
    required this.prefillPhone,
    required this.prefillEmail,
    required this.prefillAddress,
  });

  @override
  ConsumerState<_ProspectConversionDialog> createState() => _ProspectConversionDialogState();
}

class _ProspectConversionDialogState extends ConsumerState<_ProspectConversionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  final _contactCtrl = TextEditingController();
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _addressCtrl;
  final _taxIdCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _creditLimitCtrl = TextEditingController();
  final _creditDaysCtrl = TextEditingController(text: '30');
  final _notesCtrl = TextEditingController();

  String? _partyType;
  String? _currencyId;
  List<Map<String, dynamic>> _currencies = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl    = TextEditingController(text: widget.prefillName);
    _phoneCtrl   = TextEditingController(text: widget.prefillPhone);
    _emailCtrl   = TextEditingController(text: widget.prefillEmail);
    _addressCtrl = TextEditingController(text: widget.prefillAddress);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _taxIdCtrl.dispose();
    _categoryCtrl.dispose();
    _creditLimitCtrl.dispose();
    _creditDaysCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final currencies = await ref.read(currenciesProvider.future);
      final baseCode = await ref.read(baseCurrencyProvider.future);
      if (mounted) {
        setState(() {
          _currencies = currencies;
          final base = currencies.where((c) => c['currency_id'] == baseCode).toList();
          _currencyId = base.isNotEmpty ? base.first['id'] as String? : (currencies.isNotEmpty ? currencies.first['id'] as String? : null);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load currencies: $e'; });
    }
  }

  Future<void> _confirm() async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange),
      );
      return;
    }
    if (_currencyId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a currency.'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() { _saving = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    try {
      await ref.read(salesOrderRepositoryProvider).convertProspectToCustomer(
        clientId: session.clientId, companyId: session.companyId,
        quotationNo: widget.quotationNo, quotationDate: widget.quotationDate,
        account: {
          'account_name':        _nameCtrl.text.trim(),
          'account_currency_id': _currencyId,
          'party_type':          _partyType,
          'contact_person':      _contactCtrl.text.trim(),
          'phone':               _phoneCtrl.text.trim(),
          'email':               _emailCtrl.text.trim(),
          'address_line1':       _addressCtrl.text.trim(),
          'tax_id':              _taxIdCtrl.text.trim(),
          'party_category':      _categoryCtrl.text.trim(),
          'credit_limit':        double.tryParse(_creditLimitCtrl.text.trim()),
          'credit_days':         int.tryParse(_creditDaysCtrl.text.trim()) ?? 30,
        },
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        userId: session.userId,
      );
      // accountsProvider (shared account/customer picker cache) is fetched
      // once per app session — real bug found live: without invalidating
      // it here, a newly-converted customer didn't show up anywhere else
      // in the app (other pickers, lists) until the user logged out and
      // back in. Same fix already applied to Customer Master's own save.
      ref.invalidate(accountsProvider);
      if (mounted) Navigator.of(context, rootNavigator: true).pop(true);
    } on DioException catch (e) {
      setState(() { _saving = false; _error = e.response?.data?['message'] ?? e.message ?? '$e'; });
    } catch (e) {
      setState(() { _saving = false; _error = 'Unexpected error: $e'; });
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
    const dec = InputDecoration(border: OutlineInputBorder(), isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));

    return AlertDialog(
      title: const Text('Convert Prospect to Customer'),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text(
                      'This quotation is for a prospect with no customer account yet. '
                      'Complete the details below to create one — the order will then be raised against it.',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: AppColors.negative.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
                        child: Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _nameCtrl,
                      decoration: dec.copyWith(label: _req('Customer Name')),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      decoration: dec.copyWith(labelText: 'Party Type'),
                      isExpanded: true, isDense: true, itemHeight: null,
                      initialValue: _partyType,
                      items: _partyTypes.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
                      onChanged: (v) => setState(() => _partyType = v),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(controller: _contactCtrl, decoration: dec.copyWith(labelText: 'Contact Person')),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: TextFormField(controller: _phoneCtrl, decoration: dec.copyWith(labelText: 'Phone'))),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: dec.copyWith(labelText: 'Email'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) return 'Enter a valid email';
                          return null;
                        },
                      )),
                    ]),
                    const SizedBox(height: 10),
                    TextFormField(controller: _addressCtrl, decoration: dec.copyWith(labelText: 'Address')),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      decoration: dec.copyWith(label: _req('Currency')),
                      isExpanded: true, isDense: true, itemHeight: null,
                      initialValue: _currencyId,
                      items: _currencies.map((c) => DropdownMenuItem(value: c['id'] as String,
                          child: Text(c['currency_id'] as String, style: const TextStyle(fontSize: 13)))).toList(),
                      onChanged: (v) => setState(() => _currencyId = v),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: TextFormField(controller: _taxIdCtrl, decoration: dec.copyWith(labelText: 'Tax ID'))),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(controller: _categoryCtrl, decoration: dec.copyWith(labelText: 'Category'))),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: TextFormField(
                        controller: _creditLimitCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: dec.copyWith(labelText: 'Credit Limit'),
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(
                        controller: _creditDaysCtrl,
                        keyboardType: TextInputType.number,
                        decoration: dec.copyWith(labelText: 'Credit Days'),
                      )),
                    ]),
                    const SizedBox(height: 10),
                    TextFormField(controller: _notesCtrl, decoration: dec.copyWith(labelText: 'Conversion Notes (optional)')),
                  ]),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_loading || _saving) ? null : _confirm,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Create Customer & Continue'),
        ),
      ],
    );
  }
}

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';

class CompanyScreen extends ConsumerStatefulWidget {
  const CompanyScreen({super.key});

  @override
  ConsumerState<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends ConsumerState<CompanyScreen> {
  final _formKey = GlobalKey<FormState>();

  // Basic Info
  final _nameCtrl    = TextEditingController();
  final _aliasCtrl   = TextEditingController();
  final _tagLineCtrl = TextEditingController();

  // Address & Contact
  final _addressCtrl  = TextEditingController();
  final _countryCtrl  = TextEditingController();
  final _stateCtrl    = TextEditingController();
  final _cityCtrl     = TextEditingController();
  final _pinCtrl      = TextEditingController();
  final _websiteCtrl  = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _landlineCtrl = TextEditingController();
  final _mobileCtrl   = TextEditingController();

  // Tax (4 flexible pairs)
  final _tax1LabelCtrl = TextEditingController();
  final _tax1ValueCtrl = TextEditingController();
  final _tax2LabelCtrl = TextEditingController();
  final _tax2ValueCtrl = TextEditingController();
  final _tax3LabelCtrl = TextEditingController();
  final _tax3ValueCtrl = TextEditingController();
  final _tax4LabelCtrl = TextEditingController();
  final _tax4ValueCtrl = TextEditingController();

  // Images (base64)
  String? _logoBase64;
  String? _watermarkBase64;
  String? _stampBase64;

  // Product coding settings
  bool _enableBarcode    = false;
  bool _enablePartNumber = false;
  bool _hasProducts      = false; // true = settings are locked

  // Inter-location model
  String _interLocationModel = 'SIMPLE';
  bool   _hasTransactions     = false; // true = model is locked

  // Quantity entry mode (Pack + Loose on PO/GRN/Sales/Transfer line entry)
  String _qtyEntryMode = 'PACK_AND_LOOSE';

  // Number grouping style — Indian (1,15,356.00) vs International (115,356.00)
  String _numberFormat = 'INTERNATIONAL';

  // Per-currency Rate/Price decimal precision (rim_currencies.rate_decimal_places)
  // — a USD unit price may need 4-5dp where CDF only needs 2. Only this
  // company's currently-active currencies are editable here; a fresh
  // TextEditingController per currency row, keyed by that row's own id.
  List<Map<String, dynamic>> _currencies = [];
  final Map<String, TextEditingController> _currencyDecimalCtrls = {};

  // Quick Invoice — immediate vs deferred stock dispatch / cash collection
  bool _quickInvoiceDispatchStock = true;
  bool _quickInvoiceCollectCash   = true;

  bool    _loading = true;
  bool    _saving  = false;
  String? _error;
  String? _successMsg;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCompany());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();    _aliasCtrl.dispose();    _tagLineCtrl.dispose();
    _addressCtrl.dispose(); _countryCtrl.dispose();  _stateCtrl.dispose();
    _cityCtrl.dispose();    _pinCtrl.dispose();
    _websiteCtrl.dispose(); _emailCtrl.dispose();
    _landlineCtrl.dispose(); _mobileCtrl.dispose();
    _tax1LabelCtrl.dispose(); _tax1ValueCtrl.dispose();
    _tax2LabelCtrl.dispose(); _tax2ValueCtrl.dispose();
    _tax3LabelCtrl.dispose(); _tax3ValueCtrl.dispose();
    _tax4LabelCtrl.dispose(); _tax4ValueCtrl.dispose();
    for (final c in _currencyDecimalCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────

  Future<void> _loadCompany() async {
    final session = ref.read(sessionProvider)!;
    try {
      final results = await Future.wait([
        DioClient.instance.get('/ric_companies',
            queryParameters: {'id': 'eq.${session.companyId}', 'select': '*'}),
        DioClient.instance.get('/rim_products',
            queryParameters: {'is_deleted': 'eq.false', 'select': 'id', 'limit': '1'}),
        DioClient.instance.get('/rih_finance_headers',
            queryParameters: {'company_id': 'eq.${session.companyId}', 'select': 'id', 'limit': '1'}),
        DioClient.instance.get('/rim_currencies', queryParameters: {
          'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
          'is_active': 'eq.true', 'select': 'id,currency_id,currency_name,rate_decimal_places',
          'order': 'currency_id.asc',
        }),
      ]);
      final list = results[0].data as List<dynamic>;
      if (list.isNotEmpty) _populate(list.first as Map<String, dynamic>);
      _hasProducts     = (results[1].data as List).isNotEmpty;
      _hasTransactions = (results[2].data as List).isNotEmpty;
      _currencies = List<Map<String, dynamic>>.from(results[3].data as List);
      for (final c in _currencies) {
        final id = c['id'] as String;
        _currencyDecimalCtrls[id] = TextEditingController(text: '${c['rate_decimal_places'] ?? 2}');
      }
      if (mounted) setState(() => _loading = false);
    } on DioException {
      if (mounted) {
        setState(() { _loading = false; _error = 'Could not load company data.'; });
      }
    }
  }

  void _populate(Map<String, dynamic> d) {
    _nameCtrl.text    = d['company_name']  ?? '';
    _aliasCtrl.text   = d['company_alias'] ?? '';
    _tagLineCtrl.text = d['tag_line']      ?? '';
    _addressCtrl.text  = d['address']     ?? '';
    _countryCtrl.text  = d['country']     ?? '';
    _stateCtrl.text    = d['state_name']  ?? '';
    _cityCtrl.text     = d['city_name']   ?? '';
    _pinCtrl.text      = d['pin_zip_code']  ?? '';
    _websiteCtrl.text  = d['website']     ?? '';
    _emailCtrl.text    = d['email']       ?? '';
    _landlineCtrl.text = d['landline_no'] ?? '';
    _mobileCtrl.text   = d['mobile_no']   ?? '';
    _tax1LabelCtrl.text = d['tax_1_label'] ?? '';
    _tax1ValueCtrl.text = d['tax_1_value'] ?? '';
    _tax2LabelCtrl.text = d['tax_2_label'] ?? '';
    _tax2ValueCtrl.text = d['tax_2_value'] ?? '';
    _tax3LabelCtrl.text = d['tax_3_label'] ?? '';
    _tax3ValueCtrl.text = d['tax_3_value'] ?? '';
    _tax4LabelCtrl.text = d['tax_4_label'] ?? '';
    _tax4ValueCtrl.text = d['tax_4_value'] ?? '';
    _logoBase64      = d['logo']               as String?;
    _watermarkBase64 = d['company_watermark']   as String?;
    _stampBase64     = d['company_stamp']       as String?;
    _enableBarcode    = d['enable_barcode']     as bool? ?? false;
    _enablePartNumber = d['enable_part_number'] as bool? ?? false;
    _interLocationModel = d['inter_location_model'] as String? ?? 'SIMPLE';
    _qtyEntryMode        = d['qty_entry_mode']        as String? ?? 'PACK_AND_LOOSE';
    _numberFormat        = d['number_format']         as String? ?? 'INTERNATIONAL';
    _quickInvoiceDispatchStock = d['quick_invoice_dispatch_stock'] as bool? ?? true;
    _quickInvoiceCollectCash   = d['quick_invoice_collect_cash']   as bool? ?? true;
  }

  // ── Image picking ────────────────────────────────────────────────────────

  Future<void> _pickImage(String field) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 80,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final b64 = base64Encode(bytes);
    setState(() {
      if (field == 'logo')      _logoBase64      = b64;
      if (field == 'watermark') _watermarkBase64 = b64;
      if (field == 'stamp')     _stampBase64     = b64;
    });
  }

  void _clearImage(String field) {
    setState(() {
      if (field == 'logo')      _logoBase64      = null;
      if (field == 'watermark') _watermarkBase64 = null;
      if (field == 'stamp')     _stampBase64     = null;
    });
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await DioClient.instance.patch(
        '/ric_companies',
        queryParameters: {'id': 'eq.${session.companyId}'},
        data: {
          'company_name':      _nameCtrl.text.trim(),
          'company_alias':     _aliasCtrl.text.trim(),
          'tag_line':          _tagLineCtrl.text.trim(),
          'address':           _addressCtrl.text.trim(),
          'country':           _countryCtrl.text.trim(),
          'state_name':        _stateCtrl.text.trim(),
          'city_name':         _cityCtrl.text.trim(),
          'pin_zip_code':      _pinCtrl.text.trim(),
          'website':           _websiteCtrl.text.trim(),
          'email':             _emailCtrl.text.trim(),
          'landline_no':       _landlineCtrl.text.trim(),
          'mobile_no':         _mobileCtrl.text.trim(),
          'tax_1_label':       _tax1LabelCtrl.text.trim(),
          'tax_1_value':       _tax1ValueCtrl.text.trim(),
          'tax_2_label':       _tax2LabelCtrl.text.trim(),
          'tax_2_value':       _tax2ValueCtrl.text.trim(),
          'tax_3_label':       _tax3LabelCtrl.text.trim(),
          'tax_3_value':       _tax3ValueCtrl.text.trim(),
          'tax_4_label':       _tax4LabelCtrl.text.trim(),
          'tax_4_value':       _tax4ValueCtrl.text.trim(),
          'logo':               _logoBase64,
          'company_watermark':  _watermarkBase64,
          'company_stamp':      _stampBase64,
          if (!_hasProducts) 'enable_barcode':     _enableBarcode,
          if (!_hasProducts) 'enable_part_number': _enablePartNumber,
          if (!_hasTransactions) 'inter_location_model': _interLocationModel,
          'qty_entry_mode':     _qtyEntryMode,
          'number_format':      _numberFormat,
          'quick_invoice_dispatch_stock': _quickInvoiceDispatchStock,
          'quick_invoice_collect_cash':   _quickInvoiceCollectCash,
          'updated_at':         DateTime.now().toUtc().toIso8601String(),
          'updated_by':         session.userId,
        },
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );

      // Per-currency rate decimal precision — a separate table from
      // ric_companies, so its own PATCH calls (one per active currency row).
      await Future.wait(_currencies.map((c) {
        final id = c['id'] as String;
        final decimalPlaces = int.tryParse(_currencyDecimalCtrls[id]?.text ?? '') ?? 2;
        return DioClient.instance.patch(
          '/rim_currencies',
          queryParameters: {'id': 'eq.$id'},
          data: {
            'rate_decimal_places': decimalPlaces.clamp(0, 6),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'updated_by': session.userId,
          },
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      }));

      // Reflect changes in the session immediately
      ref.read(sessionProvider.notifier).state = session.copyWith(
        companyName:      _nameCtrl.text.trim(),
        enableBarcode:    _enableBarcode,
        enablePartNumber: _enablePartNumber,
        qtyEntryMode:     _qtyEntryMode,
        numberFormat:     _numberFormat,
        quickInvoiceDispatchStock: _quickInvoiceDispatchStock,
        quickInvoiceCollectCash:   _quickInvoiceCollectCash,
      );

      if (mounted) {
        setState(() { _saving = false; _successMsg = 'Company information saved successfully.'; });
      }
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed. Please try again.';
      if (mounted) setState(() { _saving = false; _error = msg; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Page header — Save moved here (top-right of the title,
              // mandatory placement convention) from the bottom of what is
              // a very long scrolling form; mobile stacks it below the
              // title instead of inline to avoid overflow.
              if (Responsive.isMobile(context)) ...[
                _buildTitleBlock(),
                const SizedBox(height: 12),
                _buildSaveButton(),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildTitleBlock()),
                    _buildSaveButton(),
                  ],
                ),
              const SizedBox(height: 28),

              // ── Success / Error banners ──────────────────────────────
              if (_successMsg != null) ...[
                _Banner(
                    color: AppColors.positive,
                    icon: Icons.check_circle_outline,
                    message: _successMsg!),
                const SizedBox(height: 20),
              ],
              if (_error != null) ...[
                _Banner(
                    color: AppColors.negative,
                    icon: Icons.error_outline,
                    message: _error!),
                const SizedBox(height: 20),
              ],

              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildBasicInfo(),
                    const SizedBox(height: 20),
                    _buildContactDetails(),
                    const SizedBox(height: 20),
                    _buildTaxInfo(),
                    const SizedBox(height: 20),
                    _buildImages(),
                    const SizedBox(height: 20),
                    _buildProductCoding(),
                    const SizedBox(height: 20),
                    _buildInterLocationModel(),
                    const SizedBox(height: 20),
                    _buildQtyEntryMode(),
                    const SizedBox(height: 20),
                    _buildNumberFormat(),
                    const SizedBox(height: 20),
                    _buildCurrencyDecimalPlaces(),
                    const SizedBox(height: 20),
                    _buildQuickInvoiceSection(),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBlock() => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Company Information',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 4),
          Text('Edit your company profile, contact details and tax information.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ],
      );

  Widget _buildSaveButton() => SizedBox(
        width: 200,
        child: ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 20, width: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Save Changes'),
        ),
      );

  // ── Section: Basic Information ────────────────────────────────────────────

  Widget _buildBasicInfo() {
    return _SectionCard(
      title: 'Basic Information',
      icon: Icons.business_outlined,
      children: [
        _TwoCol(
          left: TextFormField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Company Name *',
              prefixIcon: Icon(Icons.business),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Company name is required' : null,
          ),
          right: TextFormField(
            controller: _aliasCtrl,
            decoration: const InputDecoration(
              labelText: 'Short Name / Alias',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _tagLineCtrl,
          decoration: const InputDecoration(
            labelText: 'Tag Line',
            hintText: 'e.g. "Your Trusted Partner"',
            prefixIcon: Icon(Icons.format_quote_outlined),
          ),
        ),
      ],
    );
  }

  // ── Section: Address & Contact ────────────────────────────────────────────

  Widget _buildContactDetails() {
    return _SectionCard(
      title: 'Address & Contact',
      icon: Icons.location_on_outlined,
      children: [
        TextFormField(
          controller: _addressCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Address',
            prefixIcon: Icon(Icons.home_outlined),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        _TwoCol(
          left: TextFormField(
            controller: _countryCtrl,
            decoration: const InputDecoration(
              labelText: 'Country',
              prefixIcon: Icon(Icons.flag_outlined),
            ),
          ),
          right: TextFormField(
            controller: _stateCtrl,
            decoration: const InputDecoration(
              labelText: 'State / Province',
              prefixIcon: Icon(Icons.map_outlined),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _TwoCol(
          left: TextFormField(
            controller: _cityCtrl,
            decoration: const InputDecoration(
              labelText: 'City',
              prefixIcon: Icon(Icons.location_city_outlined),
            ),
          ),
          right: TextFormField(
            controller: _pinCtrl,
            decoration: const InputDecoration(
              labelText: 'PIN / ZIP Code',
              prefixIcon: Icon(Icons.pin_outlined),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _websiteCtrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Website',
            hintText: 'https://www.example.com',
            prefixIcon: Icon(Icons.language_outlined),
          ),
        ),
        const SizedBox(height: 16),
        _TwoCol(
          left: TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.email_outlined),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              if (!v.contains('@')) return 'Enter a valid email';
              return null;
            },
          ),
          right: TextFormField(
            controller: _landlineCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Landline No.',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _TwoCol(
          left: TextFormField(
            controller: _mobileCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Mobile No.',
              prefixIcon: Icon(Icons.smartphone_outlined),
            ),
          ),
          right: const SizedBox.shrink(),
        ),
      ],
    );
  }

  // ── Section: Tax Information ──────────────────────────────────────────────

  Widget _buildTaxInfo() {
    return _SectionCard(
      title: 'Tax Information',
      icon: Icons.receipt_long_outlined,
      subtitle:
          'Set label names for your region (e.g. GST No. · PAN No. for India, NIF · RCCM for DRC)',
      children: [
        _buildTaxRow(_tax1LabelCtrl, _tax1ValueCtrl, 'Tax 1'),
        const SizedBox(height: 12),
        _buildTaxRow(_tax2LabelCtrl, _tax2ValueCtrl, 'Tax 2'),
        const SizedBox(height: 12),
        _buildTaxRow(_tax3LabelCtrl, _tax3ValueCtrl, 'Tax 3'),
        const SizedBox(height: 12),
        _buildTaxRow(_tax4LabelCtrl, _tax4ValueCtrl, 'Tax 4'),
      ],
    );
  }

  Widget _buildTaxRow(
      TextEditingController labelCtrl,
      TextEditingController valueCtrl,
      String hint) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: TextFormField(
            controller: labelCtrl,
            decoration: InputDecoration(
              labelText: '$hint Label',
              hintText: 'e.g. GST No.',
              prefixIcon: const Icon(Icons.label_outline),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 3,
          child: TextFormField(
            controller: valueCtrl,
            decoration: InputDecoration(
              labelText: '$hint Value',
              hintText: 'e.g. 27AABCU9603R1ZX',
              prefixIcon: const Icon(Icons.numbers_outlined),
            ),
          ),
        ),
      ],
    );
  }

  // ── Section: Product Coding ───────────────────────────────────────────────

  Widget _buildProductCoding() {
    return _SectionCard(
      title: 'Product Coding',
      icon: Icons.qr_code_outlined,
      subtitle: _hasProducts
          ? 'Locked — products have been created. These settings cannot be changed.'
          : 'Enable before creating products. Cannot be changed once products exist.',
      children: [
        if (_hasProducts)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: AppColors.secondary),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Settings are locked because products already exist in this company.',
                    style: TextStyle(fontSize: 13, color: AppColors.secondary),
                  ),
                ),
              ],
            ),
          ),
        if (_hasProducts) const SizedBox(height: 16),
        _buildCodingToggle(
          icon: Icons.barcode_reader,
          label: 'Enable Barcode',
          description: 'Show barcode field on products and enable barcode scanning on transactions.',
          value: _enableBarcode,
          locked: _hasProducts,
          onChanged: (v) => setState(() => _enableBarcode = v),
        ),
        const SizedBox(height: 12),
        _buildCodingToggle(
          icon: Icons.tag_outlined,
          label: 'Enable Part Number',
          description: "Show manufacturer's part number field on products.",
          value: _enablePartNumber,
          locked: _hasProducts,
          onChanged: (v) => setState(() => _enablePartNumber = v),
        ),
      ],
    );
  }

  Widget _buildCodingToggle({
    required IconData icon,
    required String label,
    required String description,
    required bool value,
    required bool locked,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(description,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (locked)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                value ? 'ON' : 'OFF',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: value ? AppColors.positive : AppColors.textSecondary),
              ),
            )
          else
            Switch(
              value: value,
              onChanged: onChanged,
              thumbColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? Colors.white : Colors.grey.shade400),
              trackColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected) ? AppColors.primary : AppColors.surfaceVariant),
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            ),
        ],
      ),
    );
  }

  // ── Section: Inter-Location Model ─────────────────────────────────────────

  Widget _buildInterLocationModel() {
    return _SectionCard(
      title: 'Inter-Location Model',
      icon: Icons.account_tree_outlined,
      subtitle: _hasTransactions
          ? 'Locked — financial transactions have been posted. This cannot be changed.'
          : 'Set once. Determines how stock movements between your own locations are treated. '
              'See Location Groups to organise locations into entities.',
      children: [
        if (_hasTransactions)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: AppColors.secondary),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Settings are locked because transactions already exist in this company.',
                    style: TextStyle(fontSize: 13, color: AppColors.secondary),
                  ),
                ),
              ],
            ),
          ),
        _buildInterLocationOption(
          value: 'SIMPLE',
          title: 'Simple',
          description: 'All locations share one Profit & Loss and Balance Sheet. '
              'Internal stock movements are pure transfers — no financial posting. '
              'Groups show a Gross Profit report only.',
        ),
        const SizedBox(height: 12),
        _buildInterLocationOption(
          value: 'INTER_ENTITY',
          title: 'Independent Entities',
          description: 'Each location group is its own entity with its own P&L and Balance Sheet. '
              'Stock moved between different groups is posted as an inter-entity invoice.',
        ),
      ],
    );
  }

  Widget _buildInterLocationOption({
    required String value,
    required String title,
    required String description,
  }) {
    final selected = _interLocationModel == value;
    return InkWell(
      onTap: _hasTransactions
          ? null
          : () => setState(() => _interLocationModel = value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.06) : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(description,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Section: Quantity Entry Mode ──────────────────────────────────────────

  Widget _buildQtyEntryMode() {
    return _SectionCard(
      title: 'Quantity Entry Mode',
      icon: Icons.inventory_2_outlined,
      subtitle: 'Controls whether Purchase Order, GRN, Sales and Transfer line entry '
          'shows a separate Loose Qty field, or just Pack Qty. Can be changed anytime — '
          'existing transactions keep their original quantities either way.',
      children: [
        _buildQtyEntryModeOption(
          value: 'PACK_AND_LOOSE',
          title: 'Pack + Loose',
          description: 'Line entry shows both Qty Pack and Qty Loose fields '
              '(e.g. 2 cartons + 5 loose pieces).',
        ),
        const SizedBox(height: 12),
        _buildQtyEntryModeOption(
          value: 'PACK_ONLY',
          title: 'Pack Only',
          description: 'Line entry shows only Qty Pack. Simpler for businesses that '
              'never break a pack/carton on purchase.',
        ),
      ],
    );
  }

  Widget _buildQtyEntryModeOption({
    required String value,
    required String title,
    required String description,
  }) {
    final selected = _qtyEntryMode == value;
    return InkWell(
      onTap: () => setState(() => _qtyEntryMode = value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.06) : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(description,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Section: Number Format ────────────────────────────────────────────────
  // Grouping-separator style for every number shown app-wide (Financial
  // Summary, Posted Journal Entries, line amounts, reports) — orthogonal to
  // a currency's own rate-decimal precision (rim_currencies.rate_decimal_places,
  // set per-currency on the Currency master, not here). See
  // project_redesign_widgets_implementation memory for why these are two
  // separate settings rather than one.
  Widget _buildNumberFormat() {
    return _SectionCard(
      title: 'Number Format',
      icon: Icons.pin_outlined,
      subtitle: 'Controls the digit-grouping style shown throughout the app — totals, '
          'line amounts, reports. Can be changed anytime; it only affects how numbers '
          'are displayed, never what is stored.',
      children: [
        _buildNumberFormatOption(
          value: 'INTERNATIONAL',
          title: 'International',
          description: 'Groups every 3 digits — e.g. 115,356.00',
        ),
        const SizedBox(height: 12),
        _buildNumberFormatOption(
          value: 'INDIAN',
          title: 'Indian',
          description: 'Groups the last 3 digits, then every 2 — e.g. 1,15,356.00',
        ),
      ],
    );
  }

  Widget _buildNumberFormatOption({
    required String value,
    required String title,
    required String description,
  }) {
    final selected = _numberFormat == value;
    return InkWell(
      onTap: () => setState(() => _numberFormat = value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.06) : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(description,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Section: Currency Decimal Places ────────────────────────────────────
  // Orthogonal to Number Format above — that's the grouping SEPARATOR
  // style, this is decimal PRECISION for unit price/rate entry, per
  // currency (a USD unit price may need 4-5dp, CDF only needs 2). Only
  // this company's currently-ACTIVE currencies show here — a currency has
  // to be activated (via its base/local role, or manually elsewhere)
  // before there's a rate ever entered in it worth configuring precision
  // for. Calculated totals are NOT affected by this setting at all — they
  // always round to a fixed 2 decimals regardless of currency, matching
  // universal accounting practice (see AppNumberFormat.amount()).
  Widget _buildCurrencyDecimalPlaces() {
    return _SectionCard(
      title: 'Currency Decimal Places',
      icon: Icons.tag_outlined,
      subtitle: 'Controls how many decimal places a unit price/rate shows and accepts for '
          'each active currency — e.g. 4-5 for a currency you buy in bulk in, 2 for your '
          'local currency. Does not affect totals, which always show 2 decimals.',
      children: _currencies.isEmpty
          ? [const Text('No active currencies found.', style: TextStyle(fontSize: 13, color: AppColors.textSecondary))]
          : [
              for (var i = 0; i < _currencies.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _buildCurrencyDecimalRow(_currencies[i]),
              ],
            ],
    );
  }

  Widget _buildCurrencyDecimalRow(Map<String, dynamic> currency) {
    final id = currency['id'] as String;
    final code = currency['currency_id'] as String? ?? '';
    final name = currency['currency_name'] as String? ?? '';
    final ctrl = _currencyDecimalCtrls[id]!;
    return Row(children: [
      Expanded(
        child: Text('[$code] $name',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
      ),
      SizedBox(
        width: 100,
        child: TextFormField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          decoration: const InputDecoration(
            border: OutlineInputBorder(), isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            labelText: 'Decimals',
          ),
          validator: (v) {
            final n = int.tryParse(v ?? '');
            if (n == null || n < 0 || n > 6) return '0-6';
            return null;
          },
        ),
      ),
    ]);
  }

  // ── Section: Quick Invoice ────────────────────────────────────────────────

  Widget _buildQuickInvoiceSection() {
    return _SectionCard(
      title: 'Quick Invoice',
      icon: Icons.point_of_sale_outlined,
      subtitle: 'Controls whether the Quick Sales screen moves stock/cash immediately on '
          'save, or defers to a dedicated Delivery/Receipt screen. Freely changeable at any '
          'time — each invoice keeps whatever mode was in effect when it was created.',
      children: [
        _buildCodingToggle(
          icon: Icons.local_shipping_outlined,
          label: 'Dispatch Stock Immediately',
          description: 'Quick Invoice deducts stock at Save time. When off, stock is left '
              'pending for a future Delivery screen.',
          value: _quickInvoiceDispatchStock,
          locked: false,
          onChanged: (v) => setState(() => _quickInvoiceDispatchStock = v),
        ),
        const SizedBox(height: 12),
        _buildCodingToggle(
          icon: Icons.payments_outlined,
          label: 'Collect Cash Immediately',
          description: 'Quick Invoice auto-generates a settled Receipt Voucher at Save time. '
              'When off, the receivable is left pending for a future Receipt screen.',
          value: _quickInvoiceCollectCash,
          locked: false,
          onChanged: (v) => setState(() => _quickInvoiceCollectCash = v),
        ),
      ],
    );
  }

  // ── Section: Company Images ───────────────────────────────────────────────

  Widget _buildImages() {
    final logo = _ImagePicker(
      label: 'Company Logo',
      hint: '(printed at top of documents)',
      base64: _logoBase64,
      onPick: () => _pickImage('logo'),
      onClear: () => _clearImage('logo'),
    );
    final watermark = _ImagePicker(
      label: 'Watermark',
      hint: '(background on document pages)',
      base64: _watermarkBase64,
      onPick: () => _pickImage('watermark'),
      onClear: () => _clearImage('watermark'),
    );
    final stamp = _ImagePicker(
      label: 'Company Stamp',
      hint: '(printed at bottom of documents)',
      base64: _stampBase64,
      onPick: () => _pickImage('stamp'),
      onClear: () => _clearImage('stamp'),
    );
    return _SectionCard(
      title: 'Company Images',
      icon: Icons.image_outlined,
      subtitle: 'Images are printed on invoices and official documents.',
      children: [
        // 3 equal Expanded columns squeezed the "Pick Image" button's label
        // down to one character per line on mobile — stack full-width
        // instead of forcing three columns into a phone screen.
        Builder(builder: (context) {
          if (Responsive.isMobile(context)) {
            return Column(children: [
              logo,
              const SizedBox(height: 16),
              watermark,
              const SizedBox(height: 16),
              stamp,
            ]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: logo),
              const SizedBox(width: 16),
              Expanded(child: watermark),
              const SizedBox(width: 16),
              Expanded(child: stamp),
            ],
          );
        }),
      ],
    );
  }
}

// ── Layout helpers ────────────────────────────────────────────────────────────

class _TwoCol extends StatelessWidget {
  final Widget left;
  final Widget right;
  const _TwoCol({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right),
      ],
    );
  }
}

// ── Section card ──────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ── Image picker widget ───────────────────────────────────────────────────────

class _ImagePicker extends StatelessWidget {
  final String label;
  final String hint;
  final String? base64;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _ImagePicker({
    required this.label,
    required this.hint,
    required this.base64,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
        const SizedBox(height: 2),
        Text(hint,
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        Container(
          height: 120,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
            color: AppColors.surfaceVariant,
          ),
          child: base64 != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    const Base64Decoder().convert(base64!),
                    fit: BoxFit.contain,
                  ),
                )
              : const Center(
                  child: Icon(Icons.image_outlined,
                      size: 36, color: AppColors.textSecondary),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.upload_outlined, size: 16),
                label: const Text('Pick Image', maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (base64 != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Remove image',
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: AppColors.negative),
                onPressed: onClear,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ── Banner ────────────────────────────────────────────────────────────────────

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  const _Banner({required this.color, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message,
                  style: TextStyle(fontSize: 13, color: color))),
        ],
      ),
    );
  }
}

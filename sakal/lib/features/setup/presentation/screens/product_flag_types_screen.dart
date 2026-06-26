import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../master/data/models/product_flag_type_model.dart';
import '../../../master/domain/repositories/item_categories_repository.dart';
import '../../../master/presentation/providers/item_categories_providers.dart';

class ProductFlagTypesScreen extends ConsumerStatefulWidget {
  const ProductFlagTypesScreen({super.key});

  @override
  ConsumerState<ProductFlagTypesScreen> createState() => _ProductFlagTypesScreenState();
}

class _ProductFlagTypesScreenState extends ConsumerState<ProductFlagTypesScreen>
    with ScreenPermissionMixin<ProductFlagTypesScreen> {
  @override String get screenName => 'product_flag_types';
  List<ProductFlagTypeModel> _flags   = [];
  bool    _loading = true;
  bool    _saving  = false;
  String? _error;

  late ItemCategoriesRepository _repo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repo = ref.read(itemCategoriesRepositoryProvider);
      _load();
    });
  }

  bool get _canAdd  => canAdd;
  bool get _canEdit => canEdit;

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final flags = await _repo.getFlagTypes(
        clientId: session.clientId, companyId: session.companyId);
      setState(() => _flags = flags);
    } catch (e) {
      setState(() => _error = 'Failed to load: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadDefaults() async {
    final session = ref.read(sessionProvider)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Load Default Flags'),
        content: const Text(
            'This will add the 4 standard flags:\n'
            '• Can be Sold\n'
            '• Can be Purchased\n'
            '• Warehouse Transfer Allowed\n'
            '• Intercompany Transfer Allowed\n\n'
            'Existing flags with the same key will be skipped.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('Load')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      await _repo.loadDefaultFlags(
        clientId: session.clientId, companyId: session.companyId);
      await _load();
      _showMsg('Default flags loaded.');
    } catch (e) {
      _showMsg('Failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _openDialog({ProductFlagTypeModel? existing}) async {
    final session  = ref.read(sessionProvider)!;
    final keyCtrl  = TextEditingController(text: existing?.flagKey   ?? '');
    final lblCtrl  = TextEditingController(text: existing?.flagLabel  ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final sortCtrl = TextEditingController(
        text: existing?.sortOrder.toString() ?? (_flags.length + 1).toString());
    bool defVal = existing?.defaultValue ?? true;
    bool active = existing?.isActive ?? true;
    final formKey = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(existing == null ? 'Add Flag Type' : 'Edit Flag Type'),
          content: SizedBox(
            width: 420,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Flag key — locked on edit
                  TextFormField(
                    controller: keyCtrl,
                    enabled: existing == null,
                    decoration: const InputDecoration(
                      labelText: 'Flag Key *',
                      hintText: 'e.g. is_saleable  (no spaces, snake_case)',
                      helperText: 'Used in code — cannot change after creation',
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(v.trim()))
                        return 'Lowercase letters, numbers and _ only';
                      if (_flags.any((f) => f.flagKey == v.trim() && f.id != existing?.id))
                        return 'Flag key already exists';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: lblCtrl,
                    decoration: const InputDecoration(labelText: 'Label *'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      hintText: 'What does this flag mean?',
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: sortCtrl,
                          decoration: const InputDecoration(labelText: 'Sort Order'),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Default', style: TextStyle(fontSize: 12)),
                          Switch(
                            value: defVal,
                            onChanged: (v) => setS(() => defVal = v),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Active', style: TextStyle(fontSize: 12)),
                          Switch(
                            value: active,
                            onChanged: (v) => setS(() => active = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: AppColors.negative),
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Delete'),
              ),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == null && existing != null) {
      await _delete(existing);
      return;
    }
    if (saved != true) return;

    setState(() => _saving = true);
    try {
      final payload = {
        if (existing?.id != null) 'id': existing!.id,
        'client_id':     session.clientId,
        'company_id':    session.companyId,
        'flag_key':      keyCtrl.text.trim(),
        'flag_label':    lblCtrl.text.trim(),
        'default_value': defVal,
        if (descCtrl.text.trim().isNotEmpty) 'description': descCtrl.text.trim(),
        'sort_order':    int.tryParse(sortCtrl.text) ?? 0,
        'is_active':     active,
      };
      await _repo.saveFlagType(payload);
      await _load();
    } catch (e) {
      _showMsg('Save failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _delete(ProductFlagTypeModel flag) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Flag Type?'),
        content: Text(
            'Remove "${flag.flagLabel}" (${flag.flagKey})?\n\n'
            'Warning: this will not remove the flag from existing categories.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      await _repo.deleteFlagType(flag.id!);
      await _load();
    } catch (e) {
      _showMsg('Delete failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Product Flag Types',
                                style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary)),
                            const SizedBox(height: 4),
                            Text(
                              '${_flags.length} flags defined  ·  '
                              'These appear as toggles on every category and product.',
                              style: const TextStyle(
                                  fontSize: 13, color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      if (_saving)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      if (_flags.isEmpty && _canAdd)
                        OutlinedButton.icon(
                          onPressed: _saving ? null : _loadDefaults,
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: const Text('Load Defaults'),
                        ),
                      if (_flags.isEmpty) const SizedBox(width: 8),
                      if (_canAdd)
                        FilledButton.icon(
                          onPressed: _saving ? null : () => _openDialog(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Flag'),
                        ),
                    ],
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: AppColors.negative)),
                  ],

                  const SizedBox(height: 20),

                  // Info card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.primary.withOpacity(0.15)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 18, color: AppColors.primary),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Each flag is a Yes/No toggle on categories and products. '
                            'Transaction screens use these to filter which products appear '
                            '(e.g. Sales Invoice shows only products where "Can be Sold" = Yes). '
                            'Adding a new flag requires no database migration.',
                            style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  if (_flags.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.toggle_on_outlined,
                                size: 40, color: AppColors.textDisabled),
                            const SizedBox(height: 12),
                            const Text('No flag types defined.',
                                style: TextStyle(color: AppColors.textSecondary)),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _loadDefaults,
                              child: const Text('Load standard defaults'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: ListView.separated(
                          itemCount: _flags.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, color: AppColors.border),
                          itemBuilder: (_, i) => _buildRow(_flags[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildRow(ProductFlagTypeModel flag) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          flag.defaultValue ? 'ON' : 'OFF',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: flag.defaultValue ? AppColors.positive : AppColors.textSecondary),
        ),
      ),
      title: Text(flag.flagLabel,
          style: TextStyle(
              fontWeight: FontWeight.w600,
              color: flag.isActive ? AppColors.textPrimary : AppColors.textSecondary)),
      subtitle: Text(
        flag.flagKey,
        style: const TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: AppColors.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!flag.isActive)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('Inactive',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ),
          if (_canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Edit',
              onPressed: _saving ? null : () => _openDialog(existing: flag),
            ),
        ],
      ),
    );
  }
}

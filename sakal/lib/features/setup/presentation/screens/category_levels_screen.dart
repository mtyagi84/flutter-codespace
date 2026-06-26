import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../master/data/models/category_level_model.dart';
import '../../../master/domain/repositories/item_categories_repository.dart';
import '../../../master/presentation/providers/item_categories_providers.dart';

class CategoryLevelsScreen extends ConsumerStatefulWidget {
  const CategoryLevelsScreen({super.key});

  @override
  ConsumerState<CategoryLevelsScreen> createState() => _CategoryLevelsScreenState();
}

class _CategoryLevelsScreenState extends ConsumerState<CategoryLevelsScreen>
    with ScreenPermissionMixin {
  @override String get screenName => 'category_levels';
  List<CategoryLevelModel> _levels = [];
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

  // ── Permission helper (same pattern as every other screen) ─────────────────
  bool get _canAdd  => canAdd;
  bool get _canEdit => canEdit;

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final levels = await _repo.getLevels(
        clientId:  session.clientId,
        companyId: session.companyId,
      );
      setState(() => _levels = levels);
    } catch (e) {
      setState(() => _error = 'Failed to load: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openDialog({CategoryLevelModel? existing}) async {
    final session = ref.read(sessionProvider)!;
    final nextNo  = existing == null
        ? (_levels.isEmpty ? 1 : _levels.map((l) => l.levelNo).reduce((a,b) => a > b ? a : b) + 1)
        : existing.levelNo;

    if (existing == null && nextNo > 4) {
      _showMsg('Maximum 4 levels allowed.');
      return;
    }

    final labelCtrl = TextEditingController(text: existing?.levelLabel ?? '');
    bool mandatory  = existing?.isMandatory ?? (nextNo == 1);
    final formKey   = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(existing == null ? 'Add Level $nextNo' : 'Edit Level $nextNo'),
          content: SizedBox(
            width: 380,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: labelCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Level $nextNo Label',
                      hintText: nextNo == 1 ? 'e.g. Department' :
                                nextNo == 2 ? 'e.g. Category' :
                                nextNo == 3 ? 'e.g. Sub-Category' : 'e.g. Segment',
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Label is required' : null,
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Mandatory on product'),
                    subtitle: const Text('Product must have this level selected'),
                    value: mandatory,
                    onChanged: nextNo == 1
                        ? null  // Level 1 is always mandatory
                        : (v) => setS(() => mandatory = v),
                  ),
                  if (nextNo == 1)
                    const Padding(
                      padding: EdgeInsets.only(left: 4, top: 4),
                      child: Text('Level 1 is always mandatory.',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
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

    if (saved != true) return;

    setState(() => _saving = true);
    try {
      final payload = (existing?.copyWith(
        levelLabel:  labelCtrl.text.trim(),
        isMandatory: nextNo == 1 ? true : mandatory,
      ) ?? CategoryLevelModel(
        clientId:    session.clientId,
        companyId:   session.companyId,
        levelNo:     nextNo,
        levelLabel:  labelCtrl.text.trim(),
        isMandatory: nextNo == 1 ? true : mandatory,
        isActive:    true,
      )).toJson();

      await _repo.saveLevel(payload);
      await _load();
    } catch (e) {
      _showMsg('Save failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _delete(CategoryLevelModel level) async {
    // Check if categories use this level
    final session = ref.read(sessionProvider)!;
    final cats = await _repo.getCategories(
      clientId:  session.clientId,
      companyId: session.companyId,
    );
    if (cats.any((c) => c.levelNo == level.levelNo)) {
      _showMsg('Cannot delete — categories exist at Level ${level.levelNo}. Delete those first.');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Level?'),
        content: Text('Remove "${level.levelLabel}" (Level ${level.levelNo})?'),
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
      await _repo.deleteLevel(level.id!);
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
                            const Text('Category Level Setup',
                                style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary)),
                            const SizedBox(height: 4),
                            Text(
                              '${_levels.length} of 4 levels configured  ·  '
                              'These labels appear on all product forms and reports.',
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
                      if (_canAdd && _levels.length < 4)
                        FilledButton.icon(
                          onPressed: _saving ? null : () => _openDialog(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Level'),
                        ),
                    ],
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: AppColors.negative)),
                  ],

                  const SizedBox(height: 24),

                  // Explanation card
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
                            'Define up to 4 levels for your item hierarchy. '
                            'Labels are company-specific — one company can use "Department / Category / Sub-Category", '
                            'another can use "Group / Sub-Group / Type". '
                            'Level 1 is always required.',
                            style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Level cards
                  if (_levels.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.account_tree_outlined,
                                size: 40, color: AppColors.textDisabled),
                            const SizedBox(height: 12),
                            const Text('No levels configured yet.',
                                style: TextStyle(color: AppColors.textSecondary)),
                            const SizedBox(height: 8),
                            if (_canAdd)
                              TextButton(
                                onPressed: () => _openDialog(),
                                child: const Text('Add your first level'),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    ...List.generate(_levels.length, (i) => _buildLevelCard(_levels[i], i)),
                ],
              ),
            ),
    );
  }

  Widget _buildLevelCard(CategoryLevelModel level, int index) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text('${level.levelNo}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        ),
        title: Text(level.levelLabel,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(
          level.isMandatory ? 'Mandatory on product' : 'Optional on product',
          style: TextStyle(
              fontSize: 12,
              color: level.isMandatory ? AppColors.positive : AppColors.textSecondary),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!level.isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('Inactive',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ),
            if (_canEdit)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: 'Edit',
                onPressed: _saving ? null : () => _openDialog(existing: level),
              ),
            if (_canEdit)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.negative),
                tooltip: 'Delete',
                onPressed: _saving ? null : () => _delete(level),
              ),
          ],
        ),
      ),
    );
  }
}

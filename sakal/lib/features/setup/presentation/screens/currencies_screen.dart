import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';

class CurrenciesScreen extends ConsumerStatefulWidget {
  const CurrenciesScreen({super.key});

  @override
  ConsumerState<CurrenciesScreen> createState() => _CurrenciesScreenState();
}

class _CurrenciesScreenState extends ConsumerState<CurrenciesScreen> {
  List<Map<String, dynamic>> _allRows      = [];
  List<Map<String, dynamic>> _filtered     = [];
  final _searchCtrl = TextEditingController();
  bool _activeOnly  = false;
  bool _loading     = true;
  String? _error;
  final Set<String> _toggling = {};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Data ─────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    try {
      final res = await DioClient.instance.get(
        '/rim_currencies',
        queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'select':     '*',
          'order':      'currency_id.asc',
        },
      );
      if (mounted) {
        setState(() {
          _allRows  = List<Map<String, dynamic>>.from(res.data as List);
          _loading  = false;
          _error    = null;
        });
        _applyFilter();
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load currencies.'; });
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _allRows.where((r) {
        final matchActive = !_activeOnly || (r['is_active'] as bool? ?? false);
        if (q.isEmpty) return matchActive;
        final code = (r['currency_id']   as String? ?? '').toLowerCase();
        final name = (r['currency_name'] as String? ?? '').toLowerCase();
        return matchActive && (code.contains(q) || name.contains(q));
      }).toList();
    });
  }

  Future<void> _toggle(Map<String, dynamic> row) async {
    final id     = row['id'] as String;
    final newVal = !(row['is_active'] as bool? ?? false);
    if (_toggling.contains(id)) return;

    // Optimistic update
    setState(() {
      _toggling.add(id);
      final idx = _allRows.indexWhere((r) => r['id'] == id);
      if (idx != -1) _allRows[idx] = {..._allRows[idx], 'is_active': newVal};
    });
    _applyFilter();

    try {
      await DioClient.instance.patch(
        '/rim_currencies',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_active':  newVal,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
    } on DioException {
      // Revert on failure
      final idx = _allRows.indexWhere((r) => r['id'] == id);
      if (mounted) {
        setState(() {
          if (idx != -1) _allRows[idx] = {..._allRows[idx], 'is_active': !newVal};
        });
        _applyFilter();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update currency. Please try again.'),
            backgroundColor: AppColors.negative,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _toggling.remove(id));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final activeCount = _allRows.where((r) => r['is_active'] as bool? ?? false).length;
    final total       = _allRows.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Page header ───────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Currency Master',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        const SizedBox(height: 4),
                        const Text(
                            'Activate the currencies your company transacts in. '
                            'Base and local currencies are active by default.',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (!_loading && total > 0) ...[
                    const SizedBox(width: 16),
                    _ActiveBadge(active: activeCount, total: total),
                  ],
                ],
              ),
              const SizedBox(height: 20),

              // ── Error banner ──────────────────────────────────────────
              if (_error != null) ...[
                _ErrorBanner(message: _error!, onRetry: _load),
                const SizedBox(height: 20),
              ],

              // ── Search + filter ───────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search by code or name…',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  _applyFilter();
                                },
                              )
                            : null,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('Active only'),
                    selected: _activeOnly,
                    onSelected: (v) {
                      setState(() => _activeOnly = v);
                      _applyFilter();
                    },
                    selectedColor: AppColors.primary.withValues(alpha: 0.12),
                    checkmarkColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: _activeOnly
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      fontWeight: _activeOnly
                          ? FontWeight.w600
                          : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Currency list ─────────────────────────────────────────
              Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _filtered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(48),
                            child: Center(
                              child: Column(
                                children: [
                                  const Icon(Icons.currency_exchange_outlined,
                                      size: 40,
                                      color: AppColors.textSecondary),
                                  const SizedBox(height: 12),
                                  Text(
                                    _allRows.isEmpty
                                        ? 'No currencies found.\nRun migration 007_currencies.sql in Supabase.'
                                        : 'No currencies match your search.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: AppColors.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _TableHeader(),
                              const Divider(height: 1),
                              ..._filtered.asMap().entries.map((e) =>
                                  _CurrencyRow(
                                    row: e.value,
                                    isEven: e.key.isEven,
                                    toggling: _toggling
                                        .contains(e.value['id'] as String?),
                                    onToggle: () => _toggle(e.value),
                                  )),
                              if (_filtered.length < _allRows.length)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 10),
                                  child: Text(
                                    'Showing ${_filtered.length} of $total currencies',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary),
                                  ),
                                ),
                            ],
                          ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Active badge ──────────────────────────────────────────────────────────────

class _ActiveBadge extends StatelessWidget {
  final int active;
  final int total;
  const _ActiveBadge({required this.active, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.positive.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.positive.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline,
              size: 15, color: AppColors.positive),
          const SizedBox(width: 6),
          Text('$active of $total active',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.positive)),
        ],
      ),
    );
  }
}

// ── Error banner ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.negative))),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

// ── Table header ──────────────────────────────────────────────────────────────

class _TableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: const BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: const [
          SizedBox(width: 70,  child: _HCol('Code')),
          SizedBox(width: 220, child: _HCol('Currency Name')),
          SizedBox(width: 70,  child: _HCol('Symbol')),
          SizedBox(width: 130, child: _HCol('Sub-unit')),
          SizedBox(width: 70,  child: _HCol('Country')),
          SizedBox(width: 70,  child: _HCol('Active')),
        ],
      ),
    );
  }
}

class _HCol extends StatelessWidget {
  final String text;
  const _HCol(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.3));
  }
}

// ── Currency row ──────────────────────────────────────────────────────────────

class _CurrencyRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool isEven;
  final bool toggling;
  final VoidCallback onToggle;
  const _CurrencyRow({
    required this.row,
    required this.isEven,
    required this.toggling,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = row['is_active'] as bool? ?? false;
    final coin     = row['currency_coin'] as String?;

    return Container(
      color: isEven
          ? Colors.transparent
          : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Code
          SizedBox(
            width: 70,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                row['currency_id'] as String? ?? '',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isActive
                        ? AppColors.primary
                        : AppColors.textSecondary),
              ),
            ),
          ),
          // Name
          SizedBox(
            width: 220,
            child: Text(
              row['currency_name'] as String? ?? '',
              style: TextStyle(
                  fontSize: 13,
                  color: isActive
                      ? AppColors.textPrimary
                      : AppColors.textSecondary),
            ),
          ),
          // Notation (symbol)
          SizedBox(
            width: 70,
            child: Text(
              row['currency_notation'] as String? ?? '',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
          ),
          // Coin (sub-unit)
          SizedBox(
            width: 130,
            child: Text(
              coin != null && coin.isNotEmpty ? coin : '—',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          // Country code
          SizedBox(
            width: 70,
            child: Text(
              row['country_code'] as String? ?? '—',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.5),
            ),
          ),
          // Active toggle
          SizedBox(
            width: 70,
            child: toggling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Switch(
                    value: isActive,
                    onChanged: (_) => onToggle(),
                    activeThumbColor: AppColors.positive,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
          ),
        ],
      ),
    );
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';

const _regions = ['Africa', 'Americas', 'Asia', 'Europe', 'Oceania'];

class CountriesScreen extends ConsumerStatefulWidget {
  const CountriesScreen({super.key});

  @override
  ConsumerState<CountriesScreen> createState() => _CountriesScreenState();
}

class _CountriesScreenState extends ConsumerState<CountriesScreen> {
  List<Map<String, dynamic>> _allRows  = [];
  List<Map<String, dynamic>> _filtered = [];
  final _searchCtrl = TextEditingController();
  String? _regionFilter; // null = All
  bool    _activeOnly = false;
  bool    _loading    = true;
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
        '/rim_countries',
        queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'select':     '*',
          'order':      'country_name.asc',
        },
      );
      if (mounted) {
        setState(() {
          _allRows = List<Map<String, dynamic>>.from(res.data as List);
          _loading = false;
          _error   = null;
        });
        _applyFilter();
      }
    } on DioException {
      if (mounted) {
        setState(() { _loading = false; _error = 'Could not load countries.'; });
      }
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _allRows.where((r) {
        if (_activeOnly && !(r['is_active'] as bool? ?? false)) return false;
        if (_regionFilter != null && r['region'] != _regionFilter)  return false;
        if (q.isEmpty) return true;
        final name  = (r['country_name']   as String? ?? '').toLowerCase();
        final code  = (r['country_code']   as String? ?? '').toLowerCase();
        final code3 = (r['country_code_3'] as String? ?? '').toLowerCase();
        return name.contains(q) || code.contains(q) || code3.contains(q);
      }).toList();
    });
  }

  Future<void> _toggle(Map<String, dynamic> row) async {
    final id     = row['id'] as String;
    final newVal = !(row['is_active'] as bool? ?? false);
    if (_toggling.contains(id)) return;

    setState(() {
      _toggling.add(id);
      final idx = _allRows.indexWhere((r) => r['id'] == id);
      if (idx != -1) _allRows[idx] = {..._allRows[idx], 'is_active': newVal};
    });
    _applyFilter();

    try {
      await DioClient.instance.patch(
        '/rim_countries',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_active':  newVal,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
    } on DioException {
      final idx = _allRows.indexWhere((r) => r['id'] == id);
      if (mounted) {
        setState(() {
          if (idx != -1) _allRows[idx] = {..._allRows[idx], 'is_active': !newVal};
        });
        _applyFilter();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update country. Please try again.'),
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
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Country Master',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        SizedBox(height: 4),
                        Text(
                          'Activate the countries your company buys from or sells to.',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textSecondary),
                        ),
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
                const SizedBox(height: 16),
              ],

              // ── Search + Active filter ────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search by name, alpha-2 or alpha-3…',
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
                    selectedColor: AppColors.primary.withOpacity(0.12),
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
              const SizedBox(height: 12),

              // ── Region filter chips ───────────────────────────────────
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _RegionChip(
                      label: 'All',
                      selected: _regionFilter == null,
                      onTap: () {
                        setState(() => _regionFilter = null);
                        _applyFilter();
                      },
                    ),
                    const SizedBox(width: 8),
                    ..._regions.map((r) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _RegionChip(
                            label: r,
                            selected: _regionFilter == r,
                            onTap: () {
                              setState(() => _regionFilter =
                                  _regionFilter == r ? null : r);
                              _applyFilter();
                            },
                          ),
                        )),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ── Count line ────────────────────────────────────────────
              if (!_loading && _allRows.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Showing ${_filtered.length} of $total countries',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),

              // ── Table ─────────────────────────────────────────────────
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
                                  const Icon(Icons.public_off_outlined,
                                      size: 40,
                                      color: AppColors.textSecondary),
                                  const SizedBox(height: 12),
                                  Text(
                                    _allRows.isEmpty
                                        ? 'No countries found.\nRun migration 008_countries.sql in Supabase.'
                                        : 'No countries match your filter.',
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
                                  _CountryRow(
                                    row: e.value,
                                    isEven: e.key.isEven,
                                    toggling: _toggling
                                        .contains(e.value['id'] as String?),
                                    onToggle: () => _toggle(e.value),
                                  )),
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

// ── Region chip ───────────────────────────────────────────────────────────────

class _RegionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RegionChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary
              : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary,
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
        color: AppColors.positive.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.positive.withOpacity(0.3)),
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
        color: AppColors.negative.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.negative.withOpacity(0.3)),
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
          SizedBox(width: 55,  child: _HCol('Code')),
          SizedBox(width: 200, child: _HCol('Country Name')),
          SizedBox(width: 65,  child: _HCol('Alpha-3')),
          SizedBox(width: 90,  child: _HCol('Dial Code')),
          SizedBox(width: 80,  child: _HCol('Currency')),
          SizedBox(width: 100, child: _HCol('Region')),
          SizedBox(width: 65,  child: _HCol('Active')),
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

// ── Country row ───────────────────────────────────────────────────────────────

class _CountryRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool isEven;
  final bool toggling;
  final VoidCallback onToggle;
  const _CountryRow({
    required this.row,
    required this.isEven,
    required this.toggling,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = row['is_active'] as bool? ?? false;
    final region   = row['region']   as String? ?? '';

    return Container(
      color: isEven
          ? Colors.transparent
          : AppColors.surfaceVariant.withOpacity(0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Alpha-2 code chip
          SizedBox(
            width: 55,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primary.withOpacity(0.08)
                    : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                row['country_code'] as String? ?? '',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isActive
                        ? AppColors.primary
                        : AppColors.textSecondary),
              ),
            ),
          ),
          // Country name
          SizedBox(
            width: 200,
            child: Text(
              row['country_name'] as String? ?? '',
              style: TextStyle(
                  fontSize: 13,
                  color: isActive
                      ? AppColors.textPrimary
                      : AppColors.textSecondary),
            ),
          ),
          // Alpha-3
          SizedBox(
            width: 65,
            child: Text(
              row['country_code_3'] as String? ?? '—',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  letterSpacing: 0.3),
            ),
          ),
          // Dial code
          SizedBox(
            width: 90,
            child: Text(
              row['dial_code'] as String? ?? '—',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textPrimary),
            ),
          ),
          // Default currency
          SizedBox(
            width: 80,
            child: Text(
              row['default_currency_id'] as String? ?? '—',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary),
            ),
          ),
          // Region badge
          SizedBox(
            width: 100,
            child: _RegionBadge(region: region),
          ),
          // Active toggle
          SizedBox(
            width: 65,
            child: toggling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Switch(
                    value: isActive,
                    onChanged: (_) => onToggle(),
                    activeColor: AppColors.positive,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Region badge ──────────────────────────────────────────────────────────────

class _RegionBadge extends StatelessWidget {
  final String region;
  const _RegionBadge({required this.region});

  static const _colors = {
    'Africa':   Color(0xFFD4860B),
    'Americas': Color(0xFF1B3A6B),
    'Asia':     Color(0xFF2E7D32),
    'Europe':   Color(0xFF6A1B9A),
    'Oceania':  Color(0xFF00838F),
  };

  @override
  Widget build(BuildContext context) {
    if (region.isEmpty) return const SizedBox.shrink();
    final color = _colors[region] ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Text(
        region,
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.2),
      ),
    );
  }
}

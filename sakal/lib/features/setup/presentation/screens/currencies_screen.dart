import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/layout/screen_header.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/sakal_adaptive_list.dart';

// No repository/model layer exists for this screen (it calls DioClient
// directly) — this row type is defined locally rather than introducing a
// new data/models file for a single screen.
class Currency {
  final String id;
  final String currencyId;        // ISO code — see CLAUDE.md's rim_currencies note
  final String currencyName;
  final String currencyNotation;  // symbol
  final String? currencyCoin;     // sub-unit name
  final String? countryCode;
  final bool   isActive;

  const Currency({
    required this.id,
    required this.currencyId,
    required this.currencyName,
    required this.currencyNotation,
    required this.currencyCoin,
    required this.countryCode,
    required this.isActive,
  });

  factory Currency.fromJson(Map<String, dynamic> j) => Currency(
    id:               j['id']                as String? ?? '',
    currencyId:       j['currency_id']       as String? ?? '',
    currencyName:     j['currency_name']     as String? ?? '',
    currencyNotation: j['currency_notation'] as String? ?? '',
    currencyCoin:     j['currency_coin']     as String?,
    countryCode:      j['country_code']      as String?,
    isActive:         j['is_active']         as bool?   ?? false,
  );

  Currency copyWith({bool? isActive}) => Currency(
    id: id, currencyId: currencyId, currencyName: currencyName,
    currencyNotation: currencyNotation, currencyCoin: currencyCoin, countryCode: countryCode,
    isActive: isActive ?? this.isActive,
  );
}

class CurrenciesScreen extends ConsumerStatefulWidget {
  const CurrenciesScreen({super.key});

  @override
  ConsumerState<CurrenciesScreen> createState() => _CurrenciesScreenState();
}

class _CurrenciesScreenState extends ConsumerState<CurrenciesScreen>
    with ScreenHeaderMixin<CurrenciesScreen> {
  @override
  ScreenHeaderInfo buildScreenHeader() {
    final total = _allRows.length;
    final activeCount = _allRows.where((r) => r.isActive).length;
    return ScreenHeaderInfo(
      title: 'Currency Master',
      subtitle: 'Activate the currencies your company transacts in. '
          'Base and local currencies are active by default.',
      trailingBadge: !_loading && total > 0
          ? _ActiveBadge(active: activeCount, total: total)
          : null,
    );
  }

  List<Currency> _allRows      = [];
  List<Currency> _filtered     = [];
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
          _allRows  = (res.data as List)
              .map((j) => Currency.fromJson(j as Map<String, dynamic>))
              .toList();
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
        final matchActive = !_activeOnly || r.isActive;
        if (q.isEmpty) return matchActive;
        final code = r.currencyId.toLowerCase();
        final name = r.currencyName.toLowerCase();
        return matchActive && (code.contains(q) || name.contains(q));
      }).toList();
    });
  }

  Future<void> _toggle(Currency row) async {
    final id     = row.id;
    final newVal = !row.isActive;
    if (_toggling.contains(id)) return;

    // Optimistic update
    setState(() {
      _toggling.add(id);
      final idx = _allRows.indexWhere((r) => r.id == id);
      if (idx != -1) _allRows[idx] = _allRows[idx].copyWith(isActive: newVal);
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
      // currenciesProvider (shared picker cache) is fetched once per app
      // session — invalidate so activating/deactivating a currency here is
      // reflected elsewhere (GRN, PO, Finance Voucher, ...) immediately.
      ref.invalidate(currenciesProvider);
    } on DioException {
      // Revert on failure
      final idx = _allRows.indexWhere((r) => r.id == id);
      if (mounted) {
        setState(() {
          if (idx != -1) _allRows[idx] = _allRows[idx].copyWith(isActive: !newVal);
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
    // Title/subtitle/active-count badge live in the shared TopBar via
    // ScreenHeaderMixin — call every build so it tracks current state.
    refreshScreenHeader();
    final offline     = ref.watch(sessionProvider)?.offlineMode ?? false;
    final total       = _allRows.length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Error banner ──────────────────────────────────────────
              if (_error != null) ...[
                _ErrorBanner(message: _error!, onRetry: _load),
                const SizedBox(height: 16),
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
              const SizedBox(height: 12),
              if (_filtered.length < _allRows.length)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Showing ${_filtered.length} of $total currencies',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
        // ── Currency list — SakalAdaptiveList owns loading/error/empty +
        // mobile-card/desktop-table switch; the raw fixed-width table here
        // overflowed by 372px on mobile since it never adapted at all.
        Expanded(
          child: SakalAdaptiveList<Currency>(
            loading: _loading,
            error: null,
            rows: _filtered,
            columns: const [
              SakalListColumn('Code', flex: 1),
              SakalListColumn('Currency Name', flex: 3),
              SakalListColumn('Symbol', flex: 1),
              SakalListColumn('Sub-unit', flex: 2),
              SakalListColumn('Country', flex: 1),
              SakalListColumn('Active', flex: 1),
            ],
            rowBuilder: (row, i) => _buildTableRow(row, offline),
            cardBuilder: (row) => _CurrencyCard(
              row: row,
              toggling: _toggling.contains(row.id),
              offline: offline,
              onToggle: () => _toggle(row),
            ),
            emptyState: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.currency_exchange_outlined,
                      size: 40, color: AppColors.textSecondary),
                  const SizedBox(height: 12),
                  Text(
                    _allRows.isEmpty
                        ? 'No currencies found.\nRun migration 007_currencies.sql in Supabase.'
                        : 'No currencies match your search.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTableRow(Currency row, bool offline) {
    final isActive = row.isActive;
    final coin     = row.currencyCoin;
    final toggling = _toggling.contains(row.id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                row.currencyId,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isActive ? AppColors.primary : AppColors.textSecondary),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              row.currencyName,
              style: TextStyle(
                  fontSize: 13,
                  color: isActive ? AppColors.textPrimary : AppColors.textSecondary),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              row.currencyNotation,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              coin != null && coin.isNotEmpty ? coin : '—',
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              row.countryCode ?? '—',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, letterSpacing: 0.5),
            ),
          ),
          Expanded(
            flex: 1,
            child: toggling
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : offline
                    ? Icon(
                        isActive ? Icons.check_circle : Icons.cancel,
                        size: 18,
                        color: isActive ? AppColors.positive : AppColors.textSecondary,
                      )
                    : Switch(
                        value: isActive,
                        onChanged: (_) => _toggle(row),
                        activeThumbColor: AppColors.positive,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
          ),
        ],
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

// ── Mobile card ───────────────────────────────────────────────────────────────

class _CurrencyCard extends StatelessWidget {
  final Currency row;
  final bool toggling;
  final bool offline;
  final VoidCallback onToggle;
  const _CurrencyCard({
    required this.row,
    required this.toggling,
    required this.offline,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = row.isActive;
    final coin     = row.currencyCoin;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primary.withValues(alpha: 0.08)
                    : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                row.currencyId,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isActive ? AppColors.primary : AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.currencyName,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: isActive ? AppColors.textPrimary : AppColors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      row.currencyNotation,
                      if (coin != null && coin.isNotEmpty) coin,
                      if ((row.countryCode ?? '').isNotEmpty) row.countryCode!,
                    ].where((s) => s.isNotEmpty).join('  ·  '),
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            toggling
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : offline
                    ? Icon(
                        isActive ? Icons.check_circle : Icons.cancel,
                        size: 18,
                        color: isActive ? AppColors.positive : AppColors.textSecondary,
                      )
                    : Switch(
                        value: isActive,
                        onChanged: (_) => onToggle(),
                        activeThumbColor: AppColors.positive,
                      ),
          ],
        ),
      ),
    );
  }
}

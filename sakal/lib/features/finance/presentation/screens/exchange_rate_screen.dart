import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/menu_models.dart';
import '../../../../core/providers/master_cache_providers.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/responsive.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/models/exchange_rate_model.dart';
import '../providers/exchange_rate_providers.dart';

MenuFeature? _findFeature(List<MenuModule> modules, String screenPath) {
  for (final mod in modules) {
    for (final grp in mod.groups) {
      for (final feat in grp.features) {
        if (feat.screenName == screenPath) return feat;
      }
    }
  }
  return null;
}

// ── Rate row ──────────────────────────────────────────────────────────────────

class _RateRow {
  final String currencyCode;
  final String currencyName;
  final TextEditingController buyingCtrl;
  final TextEditingController sellingCtrl;

  _RateRow({
    required this.currencyCode,
    required this.currencyName,
    String buying  = '',
    String selling = '',
  })  : buyingCtrl  = TextEditingController(text: buying),
        sellingCtrl = TextEditingController(text: selling);

  void dispose() {
    buyingCtrl.dispose();
    sellingCtrl.dispose();
  }

  double? get mid {
    final b = double.tryParse(buyingCtrl.text);
    final s = double.tryParse(sellingCtrl.text);
    if (b != null && s != null && b > 0 && s > 0) return (b + s) / 2;
    return null;
  }

  bool get isValid =>
      (double.tryParse(buyingCtrl.text) ?? 0) > 0 &&
      (double.tryParse(sellingCtrl.text) ?? 0) > 0;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class ExchangeRateScreen extends ConsumerStatefulWidget {
  const ExchangeRateScreen({super.key});

  @override
  ConsumerState<ExchangeRateScreen> createState() => _ExchangeRateScreenState();
}

class _ExchangeRateScreenState extends ConsumerState<ExchangeRateScreen> {
  List<Map<String, dynamic>> _locations = [];
  String?   _locationId;
  DateTime  _rateDate     = DateTime.now();
  String    _baseCurrency = '';
  List<_RateRow> _rows   = [];

  bool    _loading     = true;
  String? _error;
  bool    _saving      = false;
  bool    _replicating = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    for (final r in _rows) r.dispose();
    super.dispose();
  }

  // ── Init: load locations + company base currency via shared providers ──────

  Future<void> _init() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final locations    = await ref.read(locationsProvider.future);
      final baseCurrency = await ref.read(baseCurrencyProvider.future);

      if (!mounted) return;
      setState(() {
        _locations    = locations;
        _baseCurrency = baseCurrency;
        _locationId   = session.locationId ??
            (locations.isNotEmpty ? locations.first['id'] as String : null);
      });

      await _loadRates();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load setup data.'; });
    }
  }

  // ── Load currencies + existing rates for selected date/location ───────────

  Future<void> _loadRates() async {
    if (_locationId == null || _baseCurrency.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final currencies = await ref.read(currenciesProvider.future);
      final rates      = await ref.read(exchangeRateRepositoryProvider).getRates(
        clientId:   session.clientId,
        companyId:  session.companyId,
        locationId: _locationId!,
        rateDate:   _fmt(_rateDate),
      );

      final rateMap = <String, ExchangeRateModel>{};
      for (final r in rates) rateMap[r.toCurrency] = r;

      for (final r in _rows) r.dispose();

      final rows = <_RateRow>[];
      for (final c in currencies) {
        final code = c['currency_id'] as String;
        if (code == _baseCurrency) continue;
        final existing = rateMap[code];
        rows.add(_RateRow(
          currencyCode: code,
          currencyName: c['currency_name'] as String? ?? code,
          buying:  existing != null ? _fmtRate(existing.buyingRate) : '',
          selling: existing != null ? _fmtRate(existing.sellingRate) : '',
        ));
      }

      if (mounted) setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load rates: $e'; });
    }
  }

  // ── Copy from most recent previous date ───────────────────────────────────

  Future<void> _copyFromPrevious() async {
    if (_locationId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final all = await ref.read(exchangeRateRepositoryProvider).getPreviousRates(
        clientId:   session.clientId,
        companyId:  session.companyId,
        locationId: _locationId!,
        beforeDate: _fmt(_rateDate),
      );

      if (!mounted) return;
      if (all.isEmpty) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No previous rates found for this location.')),
        );
        return;
      }

      // List is ordered rate_date desc from remote DS; pick first per currency
      final latest = <String, ExchangeRateModel>{};
      for (final r in all) {
        if (!latest.containsKey(r.toCurrency)) latest[r.toCurrency] = r;
      }

      for (final row in _rows) {
        final prev = latest[row.currencyCode];
        if (prev != null) {
          row.buyingCtrl.text  = _fmtRate(prev.buyingRate);
          row.sellingCtrl.text = _fmtRate(prev.sellingRate);
        }
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load previous rates.'; });
    }
  }

  // ── Save all valid rows ───────────────────────────────────────────────────

  Future<void> _save() async {
    if (_locationId == null) return;
    final session = ref.read(sessionProvider)!;

    final validRows = _rows.where((r) => r.isValid).toList();
    if (validRows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter at least one buying and selling rate.')),
      );
      return;
    }

    setState(() { _saving = true; _saveError = null; });
    try {
      final payload = validRows.map((r) => {
        'client_id':     session.clientId,
        'company_id':    session.companyId,
        'location_id':   _locationId,
        'rate_date':     _fmt(_rateDate),
        'from_currency': _baseCurrency,
        'to_currency':   r.currencyCode,
        'buying_rate':   double.parse(r.buyingCtrl.text),
        'selling_rate':  double.parse(r.sellingCtrl.text),
        'source':        'MANUAL',
        'created_by':    session.userId,
        'updated_by':    session.userId,
      }).toList();

      await ref.read(exchangeRateRepositoryProvider).saveRates(payload);

      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Exchange rates saved.'),
          backgroundColor: AppColors.positive,
        ));
      }
    } catch (e) {
      if (mounted) setState(() {
        _saving    = false;
        _saveError = 'Save failed: $e';
      });
    }
  }

  // ── Replicate to all locations ────────────────────────────────────────────

  Future<void> _copyToAllLocations() async {
    if (_locationId == null) return;
    final session = ref.read(sessionProvider)!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Copy to All Locations'),
        content: const Text(
            'This will overwrite rates for this date at all other locations. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _replicating = true; _saveError = null; });
    try {
      final count = await ref.read(exchangeRateRepositoryProvider).replicateToAllLocations(
        clientId:       session.clientId,
        companyId:      session.companyId,
        fromLocationId: _locationId!,
        rateDate:       _fmt(_rateDate),
        userId:         session.userId,
      );
      if (mounted) {
        setState(() => _replicating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Rates copied to $count location(s).'),
          backgroundColor: AppColors.positive,
        ));
      }
    } catch (e) {
      if (mounted) setState(() {
        _replicating = false;
        _saveError   = 'Replication failed: $e';
      });
    }
  }

  // ── Date picker ───────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _rateDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2099),
    );
    if (picked != null && picked != _rateDate) {
      setState(() => _rateDate = picked);
      await _loadRates();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // Smart precision: matches DB storage (numeric 18,8) while avoiding
  // unnecessary trailing zeros for large rates.
  String _fmtRate(double rate) {
    if (rate >= 1000) return rate.toStringAsFixed(2);
    if (rate >= 1)    return rate.toStringAsFixed(4);
    return rate.toStringAsFixed(8); // sub-1 rates need full 8 places
  }

  String _midLabel(double? mid) {
    if (mid == null) return '—';
    return _fmtRate(mid);
  }

  String _monthAbbr(int m) => const [
    '', 'Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec'
  ][m];

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session   = ref.watch(sessionProvider);
    final isOffline = session?.offlineMode ?? false;
    final isMobile  = Responsive.isMobile(context);

    final menus   = ref.watch(menuProvider);
    final feature = _findFeature(menus, RouteNames.exchangeRates);

    if (feature == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Color(0xFFADB5BD)),
            SizedBox(height: 12),
            Text('You do not have access to this screen.',
                style: TextStyle(color: Color(0xFF6B7280))),
          ],
        ),
      );
    }

    final canSave = feature.addAllowed || feature.editAllowed;
    final canCopy = feature.addAllowed || feature.editAllowed;
    final canBulk = feature.approveAllowed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isOffline) const OfflineBanner(),

        // ── Page header ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Exchange Rates',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
            const SizedBox(height: 2),
            Text(
              _baseCurrency.isEmpty
                  ? 'Set base currency in Company Setup first'
                  : 'Daily buying & selling rates  ·  Base currency: $_baseCurrency',
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
          ]),
        ),

        const Divider(height: 24),

        // ── Location + Date controls ─────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 12, runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: isMobile ? double.infinity : 260,
                child: DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  value: _locationId,
                  items: _locations.map((l) => DropdownMenuItem(
                    value: l['id'] as String,
                    child: Text(l['location_name'] as String),
                  )).toList(),
                  onChanged: isOffline ? null : (v) async {
                    if (v == null || v == _locationId) return;
                    setState(() => _locationId = v);
                    await _loadRates();
                  },
                ),
              ),

              // Date chip
              InkWell(
                onTap: isOffline ? null : _pickDate,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.calendar_today_outlined,
                        size: 15, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      '${_rateDate.day.toString().padLeft(2,'0')} '
                      '${_monthAbbr(_rateDate.month)} '
                      '${_rateDate.year}',
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_drop_down, size: 18, color: Colors.grey.shade600),
                  ]),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── Action buttons ───────────────────────────────────────────────────
        if (!isOffline && (canCopy || canBulk))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (canCopy)
                OutlinedButton.icon(
                  icon: const Icon(Icons.content_copy_outlined, size: 15),
                  label: const Text('Copy from Previous Date'),
                  onPressed: _loading ? null : _copyFromPrevious,
                ),
              if (canBulk && _locations.length > 1)
                OutlinedButton.icon(
                  icon: _replicating
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync_outlined, size: 15),
                  label: const Text('Copy to All Locations'),
                  onPressed: (_loading || _replicating) ? null : _copyToAllLocations,
                ),
            ]),
          ),

        const SizedBox(height: 12),

        // ── Error banners ────────────────────────────────────────────────────
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.negative.withOpacity(0.08),
                border: Border.all(color: AppColors.negative.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline, color: AppColors.negative, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!,
                    style: const TextStyle(color: AppColors.negative, fontSize: 13))),
                TextButton(onPressed: _loadRates, child: const Text('Retry')),
              ]),
            ),
          ),

        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.negative.withOpacity(0.08),
                border: Border.all(color: AppColors.negative.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_saveError!,
                  style: const TextStyle(color: AppColors.negative, fontSize: 13)),
            ),
          ),

        // ── Main content ─────────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _rows.isEmpty
                  ? _buildEmpty()
                  : isMobile
                      ? _buildMobileList()
                      : _buildDesktopTable(),
        ),

        // ── Save button ──────────────────────────────────────────────────────
        if (!isOffline && !_loading && _rows.isNotEmpty && canSave)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: FilledButton.icon(
              icon: _saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(_saving ? 'Saving…' : 'Save Rates'),
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                minimumSize: const Size(160, 44),
              ),
            ),
          ),
      ],
    );
  }

  // ── Desktop table ─────────────────────────────────────────────────────────

  Widget _buildDesktopTable() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(children: [
        Container(
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(children: [
            _colHdr('Currency',    flex: 3),
            _colHdr('Buying Rate', flex: 2),
            _colHdr('Selling Rate',flex: 2),
            _colHdr('Mid (auto)',  flex: 2),
          ]),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade200),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _rows.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
            itemBuilder: (_, i) => _buildDesktopRow(_rows[i]),
          ),
        ),
      ]),
    );
  }

  Widget _colHdr(String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600,
              fontSize: 13)),
    ),
  );

  Widget _buildDesktopRow(_RateRow row) {
    return StatefulBuilder(
      builder: (_, setRowState) {
        return Container(
          color: Colors.white,
          child: Row(children: [
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(row.currencyCode,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  Text(row.currencyName,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                ]),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _rateField(row.buyingCtrl, () => setRowState(() {})),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _rateField(row.sellingCtrl, () => setRowState(() {})),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  _midLabel(row.mid),
                  style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500,
                    color: row.mid != null ? AppColors.primary : Colors.grey.shade400,
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  // ── Mobile cards ──────────────────────────────────────────────────────────

  Widget _buildMobileList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => StatefulBuilder(
        builder: (_, setRowState) {
          final row = _rows[i];
          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(row.currencyCode,
                      style: const TextStyle(fontWeight: FontWeight.w700,
                          fontSize: 16, color: AppColors.primary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(row.currencyName,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ),
                  if (row.mid != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Mid: ${_midLabel(row.mid)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.primary,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Buying',
                          style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                      const SizedBox(height: 4),
                      _rateField(row.buyingCtrl, () => setRowState(() {})),
                    ],
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Selling',
                          style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                      const SizedBox(height: 4),
                      _rateField(row.sellingCtrl, () => setRowState(() {})),
                    ],
                  )),
                ]),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ── Shared numeric input ──────────────────────────────────────────────────

  Widget _rateField(TextEditingController ctrl, VoidCallback onChange) {
    return TextFormField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: (_) => onChange(),
      style: const TextStyle(fontSize: 14),
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────

  Widget _buildEmpty() {
    final msg = _baseCurrency.isEmpty
        ? 'Base currency not set — configure Company Setup first.'
        : 'No active currencies found.\nAdd currencies in Setup → Currencies.';
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.currency_exchange_outlined, size: 52, color: Color(0xFFADB5BD)),
        const SizedBox(height: 14),
        Text(msg, textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 14)),
      ]),
    );
  }
}

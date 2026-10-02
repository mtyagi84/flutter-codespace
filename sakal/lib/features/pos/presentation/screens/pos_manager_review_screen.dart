import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/errors/error_presenter.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';

/// Async review — NOT the real-time at-counter override (that's a modal on
/// the cashier's own device, see docs/pos/05_returns_exchange_void_approvals.md
/// §0 and docs/pos/mockups/13_supervisor_override.html). This screen is only
/// for what can wait: closed shifts with a cash variance, reviewed from a
/// manager's own device at their own pace.
class PosManagerReviewScreen extends ConsumerStatefulWidget {
  const PosManagerReviewScreen({super.key});

  @override
  ConsumerState<PosManagerReviewScreen> createState() => _PosManagerReviewScreenState();
}

class _PosManagerReviewScreenState extends ConsumerState<PosManagerReviewScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _shifts = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final res = await DioClient.instance.get('/rih_pos_shifts', queryParameters: {
        'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
        'status': 'eq.CLOSED', 'is_deleted': 'eq.false',
        'select': 'id,shift_no,opened_at,closed_at,variance_reason,variance_approved_by,'
            'cashier:rim_users!cashier_id(full_name),'
            'terminal:ric_pos_terminals!terminal_id(terminal_name)',
        'order': 'closed_at.desc', 'limit': '50',
      });
      if (mounted) setState(() { _shifts = List<Map<String, dynamic>>.from(res.data as List); _loading = false; });
    } catch (e, st) {
      AppLogger.error('PosManagerReviewLoad', e, st);
      if (mounted) setState(() { _loading = false; _error = ErrorPresenter.format(e, action: 'load closed shifts'); });
    }
  }

  Future<void> _acknowledge(Map<String, dynamic> shift) async {
    final session = ref.read(sessionProvider)!;
    try {
      await DioClient.instance.patch('/rih_pos_shifts', queryParameters: {'id': 'eq.${shift['id']}'}, data: {
        'variance_approved_by': session.userId,
      });
      _load();
    } catch (e, st) {
      AppLogger.error('PosManagerReviewAck', e, st);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorPresenter.format(e, action: 'acknowledge this shift')), backgroundColor: AppColors.negative));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white,
        title: const Text('Manager Review'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go(RouteNames.posSale)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: AppColors.negative)),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ]))
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Shifts that closed with a cash variance, reviewed here at your own pace — real-time overrides (discount/return/payout) already happened at the counter when they occurred.',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                          ),
                        ),
                        if (_shifts.isEmpty) const Text('No closed shifts yet.', style: TextStyle(color: AppColors.textSecondary)),
                        ..._shifts.map((s) {
                          final hasVariance = (s['variance_reason'] as String?)?.isNotEmpty == true;
                          final acknowledged = s['variance_approved_by'] != null;
                          final cashier = (s['cashier'] as Map<String, dynamic>?)?['full_name'] as String? ?? '';
                          final terminal = (s['terminal'] as Map<String, dynamic>?)?['terminal_name'] as String? ?? '';
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              leading: Icon(hasVariance ? Icons.warning_amber : Icons.check_circle_outline, color: hasVariance ? AppColors.negative : AppColors.positive),
                              title: Text(s['shift_no'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text('$terminal · $cashier${hasVariance ? ' · ${s['variance_reason']}' : ''}'),
                              trailing: hasVariance && !acknowledged
                                  ? FilledButton(onPressed: () => _acknowledge(s), child: const Text('Acknowledge'))
                                  : (hasVariance ? const Text('Acknowledged', style: TextStyle(color: AppColors.positive, fontSize: 12)) : null),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
    );
  }
}

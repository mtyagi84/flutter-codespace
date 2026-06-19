import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/app_colors.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool       _started  = false;
  bool       _complete = false;
  int        _done     = 0;
  int        _total    = 0;
  SyncResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSync());
  }

  Future<void> _runSync() async {
    if (_started) return;
    _started = true;

    final engine = ref.read(syncEngineProvider);
    final count  = await engine.pendingCount();

    if (count == 0) {
      if (mounted) context.go(RouteNames.dashboard);
      return;
    }

    setState(() => _total = count);

    final result = await engine.syncAll(
      onProgress: (done, total) {
        if (mounted) setState(() { _done = done; _total = total; });
      },
    );

    if (!mounted) return;
    setState(() { _result = result; _complete = true; });

    if (result.allSynced) {
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) context.go(RouteNames.dashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: _complete ? _buildResult() : _buildProgress(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_upload_outlined,
            size: 52, color: AppColors.primary),
        const SizedBox(height: 20),
        const Text('Syncing offline work…',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        Text(
          _total == 0 ? 'Preparing…' : '$_done of $_total documents',
          style: const TextStyle(
              fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 24),
        LinearProgressIndicator(
          value: _total == 0 ? null : _done / _total,
          backgroundColor: AppColors.border,
          color: AppColors.primary,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final r = _result!;

    if (r.allSynced) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline,
              size: 52, color: AppColors.positive),
          const SizedBox(height: 16),
          Text(
            '${r.synced} document${r.synced == 1 ? '' : 's'} synced',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.positive),
          ),
          const SizedBox(height: 8),
          const Text('Redirecting to dashboard…',
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.warning_amber_outlined,
              size: 36, color: AppColors.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${r.synced} of ${r.total} synced',
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Text(
          '${r.errors.length} document${r.errors.length == 1 ? '' : 's'} failed — '
          'they stay pending and will retry on your next online login.',
          style: const TextStyle(
              fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        ...r.errors.map((e) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.error_outline,
                    size: 14, color: AppColors.negative),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(e,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.negative))),
              ]),
            )),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => context.go(RouteNames.dashboard),
            child: const Text('Continue to Dashboard'),
          ),
        ),
      ],
    );
  }
}

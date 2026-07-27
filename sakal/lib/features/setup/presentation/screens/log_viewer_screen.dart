import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_logger.dart';

/// Read-only viewer over [AppLogger]'s in-memory ring buffer — a diagnostic
/// aid for support, not a business-data screen, so it carries no permission
/// gating (see CLAUDE.md's "Crash visibility" mandatory pattern). Reachable
/// from the TopBar's account menu ("View Logs").
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  bool _errorsOnly = false;

  @override
  Widget build(BuildContext context) {
    final entries = AppLogger.recentEntries.reversed
        .where((e) => !_errorsOnly || e.level == AppLogLevel.error)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Application Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy all to clipboard',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: AppLogger.exportAsText()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Logs copied to clipboard.')),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text('${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}'),
                const Spacer(),
                const Text('Errors only'),
                Switch(
                  value: _errorsOnly,
                  onChanged: (v) => setState(() => _errorsOnly = v),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('No log entries yet.'))
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 16),
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      final color = e.level == AppLogLevel.error
                          ? AppColors.negative
                          : e.level == AppLogLevel.warn
                              ? AppColors.secondary
                              : AppColors.textSecondary;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${e.time.toIso8601String()}  ·  ${e.tag}',
                            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          SelectableText(e.message, style: const TextStyle(fontSize: 12.5)),
                          if (e.stackTrace != null) ...[
                            const SizedBox(height: 4),
                            SelectableText(
                              e.stackTrace!,
                              style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

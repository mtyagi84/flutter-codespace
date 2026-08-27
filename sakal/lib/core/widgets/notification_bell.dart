import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/notification_provider.dart';
import '../theme/app_colors.dart';
import '../utils/relative_time.dart';

/// Generic notification bell — reusable beyond Product Movement Analysis'
/// own "your report is ready" notifications; any future notification_type
/// (e.g. a workflow-approval module) renders through this same widget with
/// zero changes here, since it only ever reads title/message/linkRoute.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationProvider);
    final unreadCount = ref.watch(unreadNotificationCountProvider);

    return PopupMenuButton<AppNotification>(
      tooltip: 'Notifications',
      offset: const Offset(0, 48),
      icon: Badge(
        isLabelVisible: unreadCount > 0,
        label: Text('$unreadCount', style: const TextStyle(fontSize: 10)),
        backgroundColor: AppColors.negative,
        child: const Icon(Icons.notifications_outlined, color: AppColors.sidebarText),
      ),
      itemBuilder: (_) {
        if (notifications.isEmpty) {
          return [
            const PopupMenuItem(enabled: false, child: Text('No notifications yet')),
          ];
        }
        return notifications.take(20).map((n) {
          return PopupMenuItem<AppNotification>(
            value: n,
            child: SizedBox(
              width: 280,
              child: Row(children: [
                Container(
                  width: 8, height: 8, margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: n.isRead ? Colors.transparent : AppColors.primary,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(n.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: n.isRead ? FontWeight.w400 : FontWeight.w700, fontSize: 13)),
                      if (n.message != null)
                        Text(n.message!,
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      Text(relativeTime(n.createdAt),
                          style: const TextStyle(fontSize: 10, color: AppColors.textDisabled)),
                    ],
                  ),
                ),
              ]),
            ),
          );
        }).toList();
      },
      onSelected: (n) async {
        if (!n.isRead) await ref.read(notificationProvider.notifier).markRead(n.id);
        if (n.linkRoute != null && context.mounted) context.go(n.linkRoute!);
      },
    );
  }
}

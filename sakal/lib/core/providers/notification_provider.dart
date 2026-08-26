import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/dio_client.dart';
import 'session_provider.dart';

class AppNotification {
  final String id;
  final String notificationType;
  final String title;
  final String? message;
  final String? linkRoute;
  final bool isRead;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.notificationType,
    required this.title,
    this.message,
    this.linkRoute,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        notificationType: json['notification_type'] as String,
        title: json['title'] as String,
        message: json['message'] as String?,
        linkRoute: json['link_route'] as String?,
        isRead: json['is_read'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

// Polled, not a live subscription — this app has no realtime/push
// infrastructure anywhere (every screen is plain PostgREST request/
// response), so a ~45s timer is the pragmatic v1 mechanism, same tier of
// "good enough" as every other status indicator in TopBar (MasterDataSync/
// SyncStatus) already is.
class NotificationNotifier extends StateNotifier<List<AppNotification>> {
  final Ref ref;
  Timer? _timer;

  NotificationNotifier(this.ref) : super([]) {
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => _fetch());
  }

  Future<void> _fetch() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    try {
      final res = await DioClient.instance.get('/ric_user_notifications', queryParameters: {
        'select': '*',
        'order': 'created_at.desc',
        'limit': 30,
      });
      final list = (res.data as List<dynamic>)
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList();
      state = list;
    } catch (_) {
      // Silent — a failed poll shouldn't surface an error banner anywhere;
      // it just tries again on the next tick.
    }
  }

  Future<void> refreshNow() => _fetch();

  Future<void> markRead(String id) async {
    try {
      await DioClient.instance.patch('/ric_user_notifications', queryParameters: {'id': 'eq.$id'},
          data: {'is_read': true, 'read_at': DateTime.now().toUtc().toIso8601String()});
      state = [
        for (final n in state)
          if (n.id == id)
            AppNotification(
                id: n.id, notificationType: n.notificationType, title: n.title, message: n.message,
                linkRoute: n.linkRoute, isRead: true, createdAt: n.createdAt)
          else
            n,
      ];
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final notificationProvider = StateNotifierProvider<NotificationNotifier, List<AppNotification>>(
    (ref) => NotificationNotifier(ref));

final unreadNotificationCountProvider = Provider<int>(
    (ref) => ref.watch(notificationProvider).where((n) => !n.isRead).length);

/// Shared "Xm ago"/"Xh ago"/"Xd ago" formatting — used by NotificationBell
/// and the Dashboard's own Recent Activity panel so both render identical
/// timestamps for the same underlying notification.
String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

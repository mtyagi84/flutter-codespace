import 'package:dio/dio.dart';

/// Turns any caught error into a message safe to show a user — never the
/// raw exception text (see CLAUDE.md's "Error handling" mandatory pattern).
/// A single call replaces the old `on DioException catch (e) { ... } catch
/// (e) { 'Unexpected error: $e' }` two-branch handler that used to be
/// hand-rolled, slightly differently, in every screen — `format()` already
/// knows how to read a [DioException]'s response, so callers no longer
/// need to special-case it themselves.
///
/// `DioClient`'s own `onError` interceptor already promotes PostgREST's
/// human-readable `details` field into `message` before this ever runs —
/// this class only decides what to show when that's still not present
/// (a network failure, a timeout, or a genuinely unexpected Dart error).
class ErrorPresenter {
  ErrorPresenter._();

  static String format(Object error, {String action = 'complete this action'}) {
    if (error is DioException) {
      final data = error.response?.data;
      final message = data is Map ? data['message']?.toString() : null;
      if (message != null && message.isNotEmpty) return message;

      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return 'The connection timed out. Please check your network and try again.';
        case DioExceptionType.connectionError:
          return 'Unable to reach the server. Please check your connection and try again.';
        default:
          return 'Unable to $action. Please try again.';
      }
    }
    return 'Unable to $action. Please try again.';
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/network/dio_client.dart';
import 'package:sakal/features/setup/presentation/screens/print_template_list_screen.dart';

import '../../test_helpers/pump_app.dart';

// DioClient's own request interceptor does `await _storage.read(...)`
// (FlutterSecureStorage) on every single request, including the ones this
// file's fake adapter serves. In a bare `flutter_test` run (dart VM target,
// no real Android/iOS platform underneath), flutter_secure_storage's
// MethodChannel call has no native side to answer it — with no mock handler
// registered, that call never resolves at all (not even with an exception),
// which permanently stalls the screen in its loading state regardless of how
// long this file pumps for. Registering a mock handler on the plugin's own
// channel that resolves `read` to null (no stored token — the interceptor
// already handles that by falling back to the anon key) unblocks it.
const _secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// PrintTemplateListScreen is a real structural outlier in this batch: it has
/// NO repository/provider layer at all — every read/write goes straight
/// through the app-wide `DioClient.instance` singleton (a plain, non-Riverpod
/// `Dio` object with no DI hook to override via ProviderScope). The mocktail-
/// repository pattern used by every other screen in this batch doesn't apply
/// here, so this file instead swaps `DioClient.instance.httpClientAdapter`
/// (a public, mutable field on Dio itself) for a fake one that returns
/// canned responses — the standard technique for testing code built directly
/// on a `Dio` instance. The adapter is restored after every test so this
/// swap can never leak into another test file sharing the same process.
class _FakeHttpClientAdapter implements HttpClientAdapter {
  _FakeHttpClientAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object data, {int statusCode = 200}) => ResponseBody.fromString(
      jsonEncode(data),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// Dio's own `DioMixin.fetch()` schedules a zero-duration `Timer` internally
/// (unrelated to connectTimeout/receiveTimeout — confirmed from the actual
/// failure trace: `Timer (duration: 0:00:00.000000, ...)` created inside
/// `dio_mixin.dart:507`, before Dio ever reaches this file's fake adapter)
/// as part of its own request-dispatch plumbing. Neither a single bare
/// `tester.pump()` nor `tester.pumpAndSettle()` reliably flushes it in this
/// codebase's Flutter/dio version combination — pumpAndSettle's own
/// settle-heuristic gets stuck on it ("pumpAndSettle timed out"), and a
/// single pump leaves it "still pending" at teardown. Pumping a fixed
/// number of times with an explicit small duration sidesteps both failure
/// modes: fake_async's `elapse()` actually fires due timers when given a
/// real (non-zero) duration to advance by, unlike a bare `pump()`.
Future<void> _pumpSettled(WidgetTester tester, {int times = 10}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late HttpClientAdapter originalAdapter;
  late Duration? originalConnectTimeout;
  late Duration? originalReceiveTimeout;
  late Duration? originalSendTimeout;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, (call) async {
      switch (call.method) {
        case 'read':
        case 'write':
        case 'delete':
        case 'deleteAll':
          return null;
        case 'readAll':
          return <String, String>{};
        case 'containsKey':
          return false;
        default:
          return null;
      }
    });

    originalAdapter = DioClient.instance.httpClientAdapter;
    // DioClient's real Dio instance carries a 15s connect/receive timeout.
    // flutter_test runs every test inside a FakeAsync zone, so Dio's
    // internal timeout Timer becomes a fake-clock Timer that never fires
    // (pumpAndSettle doesn't advance 15s of virtual time) and is never
    // cancelled quickly enough for the fake adapter's use here — tripping
    // "A Timer is still pending" / "pumpAndSettle timed out" even though
    // the fake adapter itself resolves immediately. Disabling Dio's own
    // timeout policy for the duration of these tests sidesteps that
    // machinery entirely; a fake in-memory adapter never actually hangs in
    // a way that needs a real timeout guard.
    originalConnectTimeout = DioClient.instance.options.connectTimeout;
    originalReceiveTimeout = DioClient.instance.options.receiveTimeout;
    originalSendTimeout = DioClient.instance.options.sendTimeout;
    DioClient.instance.options.connectTimeout = null;
    DioClient.instance.options.receiveTimeout = null;
    DioClient.instance.options.sendTimeout = null;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, null);
    DioClient.instance.httpClientAdapter = originalAdapter;
    DioClient.instance.options.connectTimeout = originalConnectTimeout;
    DioClient.instance.options.receiveTimeout = originalReceiveTimeout;
    DioClient.instance.options.sendTimeout = originalSendTimeout;
  });

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    DioClient.instance.httpClientAdapter =
        _FakeHttpClientAdapter((_) => Completer<ResponseBody>().future);

    await pumpApp(tester, const PrintTemplateListScreen(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start
    // One more pump with an explicit small duration to flush Dio's own
    // internal zero-duration dispatch Timer (see _pumpSettled's doc comment)
    // — the fake adapter's Completer still never resolves, so the screen
    // stays in loading state; this just lets fake_async settle Dio's own
    // housekeeping Timer before the test tears down.
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders a tile per template once the page loads', (tester) async {
    DioClient.instance.httpClientAdapter = _FakeHttpClientAdapter((options) async {
      expect(options.path, '/ric_print_templates');
      return _jsonResponse([
        {
          'id': 'tpl-1',
          'document_type': 'GRN',
          'template_name': 'GRN Custom A4',
          'paper_profile': 'A4',
          'is_default': true,
          'is_active': true,
        },
        {
          'id': 'tpl-2',
          'document_type': 'PURCHASE_ORDER',
          'template_name': 'PO Draft',
          'paper_profile': 'A4',
          'is_default': false,
          'is_active': false,
        },
      ]);
    });

    await pumpApp(tester, const PrintTemplateListScreen(), session: testSession());
    await _pumpSettled(tester);

    expect(find.text('GRN Custom A4'), findsOneWidget);
    expect(find.text('PO Draft'), findsOneWidget);
    expect(find.text('Goods Receipt Note · A4'), findsOneWidget);
    expect(find.text('Purchase Order · A4'), findsOneWidget);
    // Template 1 is the default (DEFAULT badge); template 2 is inactive
    // (INACTIVE badge) — neither condition applies to the other row.
    expect(find.text('DEFAULT'), findsOneWidget);
    expect(find.text('INACTIVE'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows the empty state when the page loads with zero templates', (tester) async {
    DioClient.instance.httpClientAdapter = _FakeHttpClientAdapter((_) async => _jsonResponse([]));

    await pumpApp(tester, const PrintTemplateListScreen(), session: testSession());
    await _pumpSettled(tester);

    expect(
      find.text('No print templates yet — every document type prints using a built-in '
          'default until you create one.'),
      findsOneWidget,
    );
  });

  testWidgets('shows a friendly error message when the request fails', (tester) async {
    // A non-2xx status is enough — Dio itself raises a DioException (its
    // default validateStatus only accepts 200-299), which the screen's own
    // `on DioException` catch turns into a fixed, non-interpolated message.
    DioClient.instance.httpClientAdapter =
        _FakeHttpClientAdapter((_) async => _jsonResponse({'message': 'boom'}, statusCode: 500));

    await pumpApp(tester, const PrintTemplateListScreen(), session: testSession());
    await _pumpSettled(tester);

    expect(find.text('Could not load print templates.'), findsOneWidget);
  });
}

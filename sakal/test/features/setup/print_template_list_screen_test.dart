import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/network/dio_client.dart';
import 'package:sakal/features/setup/presentation/screens/print_template_list_screen.dart';

import '../../test_helpers/pump_app.dart';

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

void main() {
  late HttpClientAdapter originalAdapter;

  setUp(() {
    originalAdapter = DioClient.instance.httpClientAdapter;
  });

  tearDown(() {
    DioClient.instance.httpClientAdapter = originalAdapter;
  });

  testWidgets('shows a loading indicator before the first page resolves', (tester) async {
    DioClient.instance.httpClientAdapter =
        _FakeHttpClientAdapter((_) => Completer<ResponseBody>().future);

    await pumpApp(tester, const PrintTemplateListScreen(), session: testSession());
    await tester.pump(); // let initState's postFrameCallback fire and _load() start

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
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    expect(find.text('Could not load print templates.'), findsOneWidget);
  });
}

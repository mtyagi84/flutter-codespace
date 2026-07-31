import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/sales/domain/repositories/sales_delivery_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_delivery_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_delivery_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesDeliveryRepository extends Mock implements SalesDeliveryRepository {}

// mocktail needs a registered fallback value for any()/captureAny() used on
// a Map/List argument matcher in a when()/verify() call.
class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}
class _FakeStringDynamicMapList extends Fake implements List<Map<String, dynamic>> {}

/// pumpAndSettle() right after a save/validate action is a trap: it keeps
/// pumping until every animation/timer settles, including a SnackBar's own
/// auto-dismiss timer (~4s) — by then the very text under test may already
/// be gone. A few short, bounded pumps let pending async work resolve
/// without running anywhere near that long.
Future<void> _pumpBriefly(WidgetTester tester, {int times = 5}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// SakalFieldCard renders its label as a raw RichText, not wrapped in
/// Text/Text.rich — find.text()/find.textContaining() don't reliably match
/// a bare RichText, so match directly against the TextSpan's own plain text.
Finder _findFieldLabel(String label) => find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

void main() {
  late MockSalesDeliveryRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockSalesDeliveryRepository();
    // _init() unconditionally calls getUsersForAutocomplete() first,
    // regardless of new-vs-edit mode (used to resolve print signatures).
    when(() => mockRepo.getUsersForAutocomplete(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => []);
  });

  List<Override> overrides() => [
        salesDeliveryRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) delivery', () {
    testWidgets('renders the blank form with all key fields and no lines yet', (tester) async {
      await pumpApp(tester, const SalesDeliveryEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Sales Delivery'), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);

      expect(_findFieldLabel('INVOICE *'), findsOneWidget);
      expect(_findFieldLabel('DELIVERY NO'), findsOneWidget);
      expect(_findFieldLabel('DELIVERY DATE'), findsOneWidget);
      expect(_findFieldLabel('CUSTOMER'), findsOneWidget);
      expect(_findFieldLabel('DISPATCH LOCATION'), findsOneWidget);
      expect(_findFieldLabel('RECEIVED BY'), findsOneWidget);
      expect(_findFieldLabel('REASON'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      // Invoice picker card — this screen consolidates from a Sales
      // Invoice, there is no free-text "Add Line" affordance anywhere.
      expect(find.text('Delivery Lines'), findsOneWidget);
      expect(find.text('No lines yet — pick an invoice above.'), findsOneWidget);

      expect(find.text('Ship To'), findsOneWidget);
      expect(_findFieldLabel('SAVED DELIVERY LOCATION'), findsOneWidget);
      expect(find.text('Transport Details'), findsOneWidget);
      expect(_findFieldLabel('VEHICLE NO'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved delivery has no delivery number yet, so no
      // print button and no approve button (approve requires !_isNew).
      expect(find.byIcon(Icons.print_outlined), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no invoice is selected', (tester) async {
      await pumpApp(tester, const SalesDeliveryEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select an invoice to deliver against.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            transport: any(named: 'transport'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow — consolidated from a Sales Invoice, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            deliveryNo: any(named: 'deliveryNo'),
            deliveryDate: any(named: 'deliveryDate'),
          )).thenAnswer((_) async => {
            'delivery_no': 'SD-001',
            'delivery_date': '2026-07-20',
            'status': 'DRAFT',
            'location_id': 'loc-001',
            'location': {'location_name': 'Main Warehouse'},
            'invoice_no': 'SI-001',
            'invoice_date': '2026-07-15',
            'customer_id': 'cust-001',
            'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
            'ship_to_location_id': null,
            'ship_to_location_name': 'Warehouse B',
            'ship_to_address_line1': 'Addr 1',
            'ship_to_address_line2': '',
            'ship_to_city_id': null,
            'ship_to_contact_person': 'John Doe',
            'ship_to_contact_phone': '123456',
            'received_by_name': 'Jane Receiver',
            'reason': 'Delivery reason',
            'remarks': 'Delivery remarks',
            'created_by': 'user-001',
            'approved_by': null,
          });
      when(() => mockRepo.getCustomerDeliveryLocations(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            customerId: any(named: 'customerId'),
          )).thenAnswer((_) async => []);
      when(() => mockRepo.getTransportDetails(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            deliveryNo: any(named: 'deliveryNo'),
            deliveryDate: any(named: 'deliveryDate'),
          )).thenAnswer((_) async => null);
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            deliveryNo: any(named: 'deliveryNo'),
            deliveryDate: any(named: 'deliveryDate'),
          )).thenAnswer((_) async => [
            {
              'invoice_line_serial': 1,
              'product_id': 'prod-001',
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'qty_pack': 8,
              'qty_loose': 0,
              'base_qty': 8,
              'barcode': null,
              'serial_no': 1,
            },
          ]);
      when(() => mockRepo.getInvoiceLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => [
            {
              'serial_no': 1,
              'base_qty': 10,
              'delivered_qty': 8, // this draft's own already-saved 8 counts here too
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'barcode': null,
            },
          ]);
    }

    testWidgets('loads and displays every field from the saved header, invoice, and untracked line', (tester) async {
      stubExistingDraft();

      await pumpApp(
        tester,
        const SalesDeliveryEntryScreen(editDeliveryNo: 'SD-001', editDeliveryDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('Sales Delivery · SD-001'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer read-only field
      expect(find.text('Main Warehouse'), findsOneWidget); // Dispatch Location
      expect(find.text('20 Jul 2026'), findsOneWidget); // Delivery Date
      expect(find.textContaining('SI-001'), findsWidgets); // Invoice picker's own initial text
      expect(find.text('Delivery reason'), findsOneWidget);
      expect(find.text('Delivery remarks'), findsOneWidget);
      expect(find.text('Jane Receiver'), findsOneWidget);

      // Delivery line, re-enriched from the invoice's own line data.
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Pending 10.00 Piece'), findsOneWidget); // SakalLineItemCard subtitle
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('8.00'), findsOneWidget); // Delivery Qty Pack — initialQtyPack from saved qty_pack
      expect(find.text('0.00'), findsOneWidget); // Delivery Qty Loose

      // No batch/serial editor for an untracked (tracking_type: NONE) line.
      expect(find.text('Batches to Deliver (FEFO auto-allocated)'), findsNothing);
      expect(find.text('Serial Numbers to Deliver (FEFO auto-allocated)'), findsNothing);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(find.byIcon(Icons.print_outlined), findsOneWidget); // a saved delivery is printable
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            transport: any(named: 'transport'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SD-001');
      when(() => mockRepo.cacheDeliveryLocally(
            effectiveDeliveryNo: any(named: 'effectiveDeliveryNo'),
            header: any(named: 'header'),
            lines: any(named: 'lines'),
          )).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const SalesDeliveryEntryScreen(editDeliveryNo: 'SD-001', editDeliveryDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Delivery remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            transport: any(named: 'transport'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['delivery_no'], 'SD-001');
      expect(header['delivery_date'], '2026-07-20');
      expect(header['invoice_no'], 'SI-001');
      expect(header['invoice_date'], '2026-07-15');
      expect(header['ship_to_location_id'], null);
      expect(header['ship_to_location_name'], 'Warehouse B');
      expect(header['ship_to_address_line1'], 'Addr 1');
      expect(header['ship_to_address_line2'], '');
      expect(header['ship_to_city_id'], null);
      expect(header['ship_to_contact_person'], 'John Doe');
      expect(header['ship_to_contact_phone'], '123456');
      expect(header['received_by_name'], 'Jane Receiver');
      expect(header['reason'], 'Delivery reason');
      expect(header['remarks'], 'Updated remarks');

      expect(lines, hasLength(1));
      final line = lines.first;
      expect(line['serial_no'], 1);
      expect(line['invoice_line_serial'], 1);
      expect(line['product_id'], 'prod-001');
      expect(line['barcode'], '');
      expect(line['uom_id'], 'uom-001');
      expect(line['uom_conversion_factor'], 1.0);
      expect(line['qty_pack'], 8.0);
      expect(line['qty_loose'], 0.0);
      expect(line['base_qty'], 8.0); // deliveryQty

      expect(find.text('Sales Delivery SD-001 saved.'), findsOneWidget);
    });
  });

  // This screen consolidates from a Sales Invoice — there is no free
  // product-line SakalAutocomplete anywhere; lines only ever come from
  // picking an Invoice in the header's own picker. That picker is
  // structurally different from every other picker driven in this app's
  // widget-test suite so far: its own optionsBuilder fires an unawaited
  // repository search per keystroke and returns whatever _invoiceOptions
  // currently holds SYNCHRONOUSLY (never a Future the widget itself
  // awaits) — see the test's own inline comment below for why two
  // distinct keystrokes are needed to observe the real fetched results.
  group('Invoice autocomplete interaction (real search + select)', () {
    Finder fieldInCard(String label, Finder Function() matcher) => find.descendant(
          of: find.ancestor(
                of: find.byWidgetPredicate((w) =>
                    w is RichText &&
                    (w.text.toPlainText().trim().toUpperCase() == label.toUpperCase() ||
                        w.text.toPlainText().trim().toUpperCase() == '${label.toUpperCase()} *')),
                matching: find.byType(SakalFieldCard),
              ).first,
          matching: matcher(),
        );

    testWidgets(
        'typing into the Invoice field shows the matching option, and selecting it loads that invoice\'s pending lines',
        (tester) async {
      when(() => mockRepo.getPendingDeliveryInvoices(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            search: any(named: 'search'),
          )).thenAnswer((_) async => [
            {
              'invoice_no': 'SI-001',
              'invoice_date': '2026-07-15',
              'customer_id': 'cust-001',
              'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
              'location_id': 'loc-001',
              'location': {'location_name': 'Main Warehouse'},
              'pending_qty': 10.0,
            },
          ]);
      when(() => mockRepo.getInvoiceLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => [
            {
              'serial_no': 1,
              'product_id': 'prod-wid-a',
              'base_qty': 10,
              'delivered_qty': 0,
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'barcode': null,
            },
          ]);
      when(() => mockRepo.getCustomerDeliveryLocations(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            customerId: any(named: 'customerId'),
          )).thenAnswer((_) async => []);

      await pumpApp(tester, const SalesDeliveryEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      final invoiceField = fieldInCard('Invoice', () => find.byType(TextFormField));

      // The Invoice field's own optionsBuilder returns _invoiceOptions
      // SYNCHRONOUSLY while firing an unawaited repository search in the
      // background (`unawaited(_searchInvoices(v.text)); return
      // _invoiceOptions;`) — unlike every other picker tested elsewhere in
      // this app, which either filters an already-loaded list or returns
      // a Future the widget itself awaits. The first keystroke's call
      // therefore returns the still-empty initial list while the real
      // fetch resolves in the background; a second, DIFFERENT keystroke
      // is needed so the controller-change listener re-invokes the (by-
      // then-rebuilt) closure that closes over the now-populated list —
      // by the time this second call happens, `widget.optionsBuilder` on
      // the live State object already reflects the latest rebuild.
      await tester.enterText(invoiceField, 'S');
      await tester.pumpAndSettle();
      await tester.enterText(invoiceField, 'SI');
      await tester.pumpAndSettle();

      const expectedOption = 'SI-001 — [CUS01] Customer One · Main Warehouse · Pending 10.00';
      expect(find.text(expectedOption), findsOneWidget);

      await tester.tap(find.text(expectedOption));
      // invoiceField carries key: ValueKey(_invoiceNo ?? '') — selecting
      // sets _invoiceNo, forcing a remount.
      await tester.pumpAndSettle();

      // _onInvoiceSelected sets the customer/location header snapshot and
      // replaces _lines with the invoice's own pending lines — the
      // simplest observable proof both the selection and its downstream
      // fetch landed.
      expect(find.text('No lines yet — pick an invoice above.'), findsNothing);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer read-only field
      expect(find.text('Main Warehouse'), findsOneWidget); // Dispatch Location read-only field
      expect(find.textContaining('SI-001'), findsWidgets); // Invoice field's own updated display text
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/core/layout/screen_header.dart';
import 'package:sakal/core/sync/sync_engine.dart';
import 'package:sakal/core/widgets/sakal_field_card.dart';
import 'package:sakal/features/sales/domain/repositories/sales_return_repository.dart';
import 'package:sakal/features/sales/presentation/providers/sales_return_providers.dart';
import 'package:sakal/features/sales/presentation/screens/sales_return_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockSalesReturnRepository extends Mock implements SalesReturnRepository {}

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
      (w) => w is RichText && w.maxLines == 1 && w.text.toPlainText().toUpperCase().contains(label.toUpperCase()),
    );

/// The screen's title/subtitle/badge no longer render as body text — they're
/// posted to the shared TopBar via ScreenHeaderMixin (screen_header.dart),
/// and pumpApp() doesn't include a TopBar in its pumped tree at all. Read
/// the posted ScreenHeaderInfo back from the provider instead of searching
/// for rendered text.
ScreenHeaderInfo? _readHeader(WidgetTester tester, Finder screenFinder) =>
    ProviderScope.containerOf(tester.element(screenFinder)).read(screenHeaderProvider);

/// Forces a viewport narrower than the app's 600px mobile breakpoint —
/// flutter_test's own default (~800x600) falls on the DESKTOP side of that
/// threshold, so the Lines section's isMobile branch (SakalLineItemCard,
/// whose subtitle concatenates "Invoiced X · Remaining Y" into one string —
/// the desktop row instead shows those as two separate fields) would
/// otherwise never render; some tests were written against that mobile-card
/// shape.
void _useMobileViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late MockSalesReturnRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
    registerFallbackValue(_FakeStringDynamicMapList());
  });

  setUp(() {
    mockRepo = MockSalesReturnRepository();
    // _init() only touches the repository at all when editReturnNo != null
    // (a brand-new return has nothing to load) — unlike Sales Delivery's
    // own _init(), which unconditionally resolves users for print
    // signatures. Nothing needs stubbing here for the blank-form tests.
  });

  List<Override> overrides() => [
        salesReturnRepositoryProvider.overrideWithValue(mockRepo),
        syncEngineProvider.overrideWithValue(SyncEngine(null)),
      ];

  group('New (blank) return', () {
    testWidgets('renders the blank form with all key fields and no lines yet', (tester) async {
      await pumpApp(tester, const SalesReturnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(SalesReturnEntryScreen));
      expect(header?.title, 'New Sales Return');
      expect(header?.subtitle, 'Unsaved draft');

      expect(_findFieldLabel('INVOICE *'), findsOneWidget);
      expect(_findFieldLabel('RETURN NO'), findsOneWidget);
      expect(_findFieldLabel('RETURN DATE'), findsOneWidget);
      expect(_findFieldLabel('CUSTOMER'), findsOneWidget);
      expect(_findFieldLabel('SALE TYPE'), findsOneWidget);
      expect(_findFieldLabel('REASON'), findsOneWidget);

      // Invoice picker card — this screen consolidates from a Sales
      // Invoice, there is no free-text "Add Line" affordance anywhere.
      expect(find.text('Return Lines'), findsOneWidget);
      expect(find.text('No lines yet — pick an invoice above.'), findsOneWidget);

      // No saved charges and no invoice picked yet -> the Charges card
      // renders nothing at all (only shown when _charges.isNotEmpty).
      expect(find.text('Additional Charges'), findsNothing);

      expect(_findFieldLabel('TAXABLE AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('TAX AMOUNT'), findsOneWidget);
      expect(_findFieldLabel('RETURN TOTAL'), findsOneWidget);
      expect(_findFieldLabel('REMARKS'), findsOneWidget);

      // Cash-refund fields only render when _showRefundFields (CASH sale +
      // IMMEDIATE collection) — never true before an invoice is picked.
      expect(find.text('Cash Refund'), findsNothing);

      expect(find.text('Save Draft'), findsOneWidget);
      // A brand-new, never-saved return has no return number yet, so no
      // print button and no approve button (approve requires !_isNew).
      expect(header?.actions, isEmpty);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('blocks save and shows a validation message when no invoice is selected', (tester) async {
      await pumpApp(tester, const SalesReturnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      expect(find.text('Select an invoice to return against.'), findsOneWidget);
      verifyNever(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          ));
    });
  });

  group('Editing an existing DRAFT (resume flow — consolidated from a Sales Invoice, untracked line)', () {
    void stubExistingDraft() {
      when(() => mockRepo.getHeader(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            returnNo: any(named: 'returnNo'),
            returnDate: any(named: 'returnDate'),
          )).thenAnswer((_) async => {
            'return_no': 'SR-001',
            'return_date': '2026-07-20',
            'status': 'DRAFT',
            'invoice_no': 'SI-001',
            'invoice_date': '2026-07-15',
            'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
            'reason': 'Damaged item',
            'remarks': 'Return remarks',
            'refund_amount_local': 0,
            'refund_amount_base': 0,
          });
      when(() => mockRepo.getApprovedInvoices(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            search: any(named: 'search'),
          )).thenAnswer((_) async => [
            {
              'invoice_no': 'SI-001',
              'invoice_date': '2026-07-15',
              'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
              'sale_type': 'CREDIT',
              'stock_dispatch_mode': 'DEFERRED',
              'cash_collection_mode': 'DEFERRED',
              'collected_amount_local': 0,
              'collected_amount_base': 0,
            },
          ]);
      when(() => mockRepo.getLines(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            returnNo: any(named: 'returnNo'),
            returnDate: any(named: 'returnDate'),
          )).thenAnswer((_) async => [
            {
              'invoice_line_serial': 1,
              'product_id': 'prod-001',
              'barcode': null,
              'uom_id': 'uom-001',
              'uom': {'description': 'Piece'},
              'uom_conversion_factor': 1,
              'qty_pack': 8,
              'qty_loose': 0,
              'rate': 25,
              'tax_group_id': 'taxgrp-001',
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
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'base_qty': 10, // invoice's own original invoiced qty
              'gross_amount': 250,
              'tax_amount': 40,
              'final_amount': 290,
            },
          ]);
      when(() => mockRepo.getAlreadyReturnedByLine(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => []);
      when(() => mockRepo.getCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            returnNo: any(named: 'returnNo'),
            returnDate: any(named: 'returnDate'),
          )).thenAnswer((_) async => []);
      when(() => mockRepo.getInvoiceCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => []);
    }

    testWidgets('loads and displays every field from the saved header, invoice, and untracked line', (tester) async {
      stubExistingDraft();
      _useMobileViewport(tester);

      await pumpApp(
        tester,
        const SalesReturnEntryScreen(editReturnNo: 'SR-001', editReturnDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      final header = _readHeader(tester, find.byType(SalesReturnEntryScreen));
      expect(header?.title, 'Sales Return · SR-001');
      expect(header?.subtitle, 'Draft');
      expect(find.text('SR-001'), findsOneWidget); // Return No read-only field
      expect(find.text('20 Jul 2026'), findsOneWidget); // Return Date
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer read-only field
      expect(find.text('Credit'), findsOneWidget); // Sale Type, resolved from the matched invoice's sale_type
      expect(find.textContaining('SI-001'), findsWidgets); // Invoice picker's own initial text
      expect(find.text('Damaged item'), findsOneWidget);
      expect(find.text('Return remarks'), findsOneWidget);

      // Return line, re-enriched from the invoice's own line data. invoicedQty
      // (10, from the invoice line's base_qty) minus alreadyReturned (0, no
      // prior APPROVED returns) leaves remainingReturnable = 10.
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('Invoiced 10.00 Piece · Remaining 10.00'), findsOneWidget); // SakalLineItemCard subtitle
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('8.00'), findsOneWidget); // Return Qty Pack — initialQtyPack from saved qty_pack
      expect(find.text('0.00'), findsOneWidget); // Return Qty Loose
      expect(find.text('25.00'), findsOneWidget); // Rate, AppNumberFormat.amount(25, ...)
      // fraction = returnQty(8) / invoicedQty(10) = 0.8, applied to the
      // invoice line's own fixed gross/tax/final amounts (never re-priced).
      expect(find.text('232.00'), findsOneWidget); // Amount = finalAmount = 290 * 0.8

      // No batch/serial editor for an untracked (tracking_type: NONE) line.
      expect(find.text('Select Batches to Return'), findsNothing);
      expect(find.text('Select Serial Numbers to Return'), findsNothing);

      // Totals card: taxable = grossAmount (250*0.8=200), tax = taxAmount
      // (40*0.8=32). Return Total's own display string carries a leading
      // space because _returnCurrencyCode is declared but never assigned
      // anywhere in this screen (always null) — matches actual current
      // behavior, not a widget-test artifact.
      expect(find.text('200.00'), findsOneWidget);
      expect(find.text('32.00'), findsOneWidget);
      expect(find.text(' 232.00'), findsOneWidget);

      expect(find.text('Save Draft'), findsOneWidget);
      expect(find.text('Approve'), findsNothing); // canApprove defaults false from the harness's empty menuProvider
      expect(header?.actions.length, 1); // a saved return is printable
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingDraft();
      when(() => mockRepo.save(
            header: any(named: 'header'),
            lines: any(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).thenAnswer((_) async => 'SR-001');

      await pumpApp(
        tester,
        const SalesReturnEntryScreen(editReturnNo: 'SR-001', editReturnDate: '2026-07-20'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Return remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Draft'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.save(
            header: captureAny(named: 'header'),
            lines: captureAny(named: 'lines'),
            batches: any(named: 'batches'),
            serials: any(named: 'serials'),
            charges: any(named: 'charges'),
            userId: any(named: 'userId'),
          )).captured;
      final header = captured[0] as Map<String, dynamic>;
      final lines = captured[1] as List<Map<String, dynamic>>;

      expect(header['client_id'], 'client-001');
      expect(header['company_id'], 'company-001');
      expect(header['return_no'], 'SR-001');
      expect(header['return_date'], '2026-07-20');
      expect(header['invoice_no'], 'SI-001');
      expect(header['invoice_date'], '2026-07-15');
      expect(header['taxable_amount'], 200.0);
      expect(header['tax_amount'], 32.0);
      expect(header['charges_amount'], 0.0);
      expect(header['return_total'], 232.0);
      expect(header['refund_amount_local'], 0); // _showRefundFields false (CREDIT sale) -> always 0
      expect(header['refund_amount_base'], 0);
      expect(header['reason'], 'Damaged item');
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
      expect(line['base_qty'], 8.0); // returnQty
      expect(line['rate'], 25.0);
      expect(line['tax_group_id'], 'taxgrp-001');
      expect(line['gross_amount'], 200.0);
      expect(line['tax_amount'], 32.0);
      expect(line['final_amount'], 232.0);

      expect(find.text('Sales Return SR-001 saved.'), findsOneWidget);
    });
  });

  // Same GRN-consolidation shape as Purchase Return, applied to a Sales
  // Invoice instead — no free product-line SakalAutocomplete anywhere. The
  // Customer/Sale Type fields are both read-only (SakalFieldCard.readOnly),
  // driven entirely off the Invoice selection — there is no separate
  // Customer picker on this screen — so this group drives only the
  // Invoice picker itself. Same "unawaited search + return stale state"
  // optionsBuilder shape as Sales Delivery's own Invoice field — see that
  // screen's own test for why two distinct keystrokes are needed.
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
        'typing into the Invoice field shows the matching option, and selecting it loads that invoice\'s returnable lines',
        (tester) async {
      when(() => mockRepo.getApprovedInvoices(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            search: any(named: 'search'),
          )).thenAnswer((_) async => [
            {
              'invoice_no': 'SI-001',
              'invoice_date': '2026-07-15',
              'customer': {'account_code': 'CUS01', 'account_name': 'Customer One'},
              'sale_type': 'CREDIT',
              'stock_dispatch_mode': 'DEFERRED',
              'cash_collection_mode': 'DEFERRED',
              'collected_amount_local': 0,
              'collected_amount_base': 0,
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
              'product_id': 'prod-001',
              'product': {'product_code': 'WID-A', 'product_name': 'Widget A', 'tracking_type': 'NONE'},
              'base_qty': 10,
              'gross_amount': 250,
              'tax_amount': 40,
              'final_amount': 290,
            },
          ]);
      when(() => mockRepo.getInvoiceCharges(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => []);
      when(() => mockRepo.getAlreadyReturnedByLine(
            clientId: any(named: 'clientId'),
            companyId: any(named: 'companyId'),
            invoiceNo: any(named: 'invoiceNo'),
            invoiceDate: any(named: 'invoiceDate'),
          )).thenAnswer((_) async => []);

      await pumpApp(tester, const SalesReturnEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      final invoiceField = fieldInCard('Invoice', () => find.byType(TextFormField));

      // Same "returns stale state synchronously while fetching in the
      // background" optionsBuilder shape as Sales Delivery's own Invoice
      // field — a second, different keystroke is needed to observe the
      // real (by-then-fetched) options; see that screen's test for the
      // full explanation.
      await tester.enterText(invoiceField, 'S');
      await tester.pumpAndSettle();
      await tester.enterText(invoiceField, 'SI');
      await tester.pumpAndSettle();

      const expectedOption = 'SI-001 — [CUS01] Customer One';
      expect(find.text(expectedOption), findsOneWidget);

      await tester.tap(find.text(expectedOption));
      // invoiceField carries key: ValueKey(_invoiceNo ?? '') — selecting
      // sets _invoiceNo, forcing a remount.
      await tester.pumpAndSettle();

      // _onInvoiceSelected sets the customer/sale-type header snapshot
      // (both read-only fields) and replaces _lines with the invoice's
      // own returnable lines.
      expect(find.text('No lines yet — pick an invoice above.'), findsNothing);
      expect(find.textContaining('Widget A'), findsWidgets);
      expect(find.text('[CUS01] Customer One'), findsOneWidget); // Customer read-only field
      expect(find.text('Credit'), findsOneWidget); // Sale Type read-only field, resolved from sale_type
      expect(find.textContaining('SI-001'), findsWidgets); // Invoice field's own updated display text
    });
  });
}

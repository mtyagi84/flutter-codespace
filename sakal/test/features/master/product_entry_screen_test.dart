import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sakal/features/master/data/models/common_master_model.dart';
import 'package:sakal/features/master/data/models/item_category_model.dart';
import 'package:sakal/features/master/data/models/product_flag_type_model.dart';
import 'package:sakal/features/master/data/models/product_media_model.dart';
import 'package:sakal/features/master/data/models/product_model.dart';
import 'package:sakal/features/master/data/models/product_uom_model.dart';
import 'package:sakal/features/master/data/models/tax_group_model.dart';
import 'package:sakal/features/master/domain/repositories/products_repository.dart';
import 'package:sakal/features/master/presentation/providers/products_providers.dart';
import 'package:sakal/features/master/presentation/screens/product_entry_screen.dart';

import '../../test_helpers/pump_app.dart';

class MockProductsRepository extends Mock implements ProductsRepository {}

// mocktail needs a registered fallback value for any()/captureAny() used on
// a Map argument matcher in a when()/verify() call.
class _FakeStringDynamicMap extends Fake implements Map<String, dynamic> {}

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
  late MockProductsRepository mockRepo;

  setUpAll(() {
    registerFallbackValue(_FakeStringDynamicMap());
  });

  setUp(() {
    mockRepo = MockProductsRepository();
    // _init() -> _loadRefs() always fetches this fixed set of reference
    // data regardless of new-vs-edit mode. 'uom-001'/'Piece' must be
    // present so the Base UOM DropdownButtonFormField's initialValue
    // (whether null for a new product or a loaded product's own
    // base_uom_id) always has a matching item — an unmatched initialValue
    // throws a "no matching item" assertion, same trap already documented
    // for Purchase Order's own Buyer dropdown.
    when(() => mockRepo.loadMasterSets(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <String, List<CommonMasterModel>>{
          'UNIT': [
            const CommonMasterModel(
              id: 'uom-001', clientId: 'client-001', companyId: 'company-001',
              typeId: 'UNIT', description: 'Piece', sortOrder: 1, isActive: true, isDeleted: false,
            ),
          ],
        });
    when(() => mockRepo.getCategories(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <ItemCategoryModel>[]);
    when(() => mockRepo.getTaxGroups(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <TaxGroupModel>[]);
    when(() => mockRepo.getCurrencies(any())).thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => mockRepo.getFlagTypes(
          clientId: any(named: 'clientId'),
          companyId: any(named: 'companyId'),
        )).thenAnswer((_) async => <ProductFlagTypeModel>[]);
  });

  List<Override> overrides() => [
        productsRepositoryProvider.overrideWithValue(mockRepo),
      ];

  group('New (blank) product', () {
    testWidgets('renders the blank form with all key fields and sections', (tester) async {
      await pumpApp(tester, const ProductEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(find.text('New Product'), findsOneWidget);
      expect(find.text('Product Master'), findsOneWidget);

      expect(_findFieldLabel('PRODUCT CODE'), findsOneWidget);
      expect(_findFieldLabel('PRODUCT NAME'), findsOneWidget);
      expect(_findFieldLabel('BASE UOM'), findsOneWidget);

      // Section titles — every card is always present regardless of
      // whether it has any real data yet.
      expect(find.text('Basic Details'), findsOneWidget);
      expect(find.text('Identifiers & Codes'), findsOneWidget);
      expect(find.text('Classification'), findsOneWidget);
      expect(find.text('UOM & Tracking'), findsOneWidget);
      expect(find.text('Costing'), findsOneWidget);
      expect(find.text('Taxation & Supplier'), findsOneWidget);
      expect(find.text('Physical Dimensions'), findsOneWidget);
      expect(find.text('UOM Levels (Pack Sizes)'), findsOneWidget);
      expect(find.text('Product Flags'), findsOneWidget);
      expect(find.text('Product Images'), findsOneWidget);

      // Identifiers & Codes: session.enableBarcode/enablePartNumber both
      // default false, so the Barcode/Part Number row never renders at
      // all (not even as disabled fields).
      expect(_findFieldLabel('BARCODE'), findsNothing);
      expect(_findFieldLabel('PART NUMBER'), findsNothing);

      // Classification: no Brand/Item Size/Item Color masters configured
      // in this fixture -> each picker falls back to plain explanatory text
      // instead of a DropdownButtonFormField.
      expect(find.text('No brand options defined'), findsOneWidget);
      expect(find.text('No item size options defined'), findsOneWidget);
      expect(find.text('No item color options defined'), findsOneWidget);

      // UOM Levels / Product Flags empty states.
      expect(find.text('No UOM levels added yet.'), findsOneWidget);
      expect(find.text('Add UOM Level'), findsOneWidget);
      expect(find.text('No flag types configured. Go to Setup › Product Flag Types to add flags.'), findsOneWidget);

      // Product Images: the "No images added." text is gated on
      // `visible.isEmpty && !canSave` — canSave is true for a new product
      // (canAdd defaults true from the harness's empty menuProvider), so
      // that text never renders; only the Add Image button does.
      expect(find.text('No images added.'), findsNothing);
      expect(find.text('Add Image'), findsOneWidget);

      expect(find.text('Save Product'), findsOneWidget);
    });

    testWidgets('blocks save and shows a validation message when required fields are empty', (tester) async {
      await pumpApp(tester, const ProductEntryScreen(), overrides: overrides(), session: testSession());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Product'));
      await _pumpBriefly(tester);

      // Product Code, Product Name, and Base UOM are all required and all
      // blank on a fresh form -> Form.validate() fails before _save() ever
      // builds a payload or calls the repository.
      expect(find.text('Please fill in all required fields.'), findsOneWidget);
      verifyNever(() => mockRepo.saveProduct(any(), isNew: any(named: 'isNew')));
    });
  });

  group('Editing an existing product (resume flow, untracked, no UOM levels)', () {
    void stubExistingProduct() {
      when(() => mockRepo.getProduct('prod-001')).thenAnswer((_) async => const ProductModel(
            id: 'prod-001',
            clientId: 'client-001',
            companyId: 'company-001',
            productCode: 'WID-A',
            productName: 'Widget A',
            productNature: 'TRADING',
            baseUomId: 'uom-001',
            trackingType: 'NONE',
            isActive: true,
            isScalable: false,
            standardCost: 10.5,
            averageCost: 9.75,
            lastPurchaseCost: 10.0,
            remarks: 'Original remarks',
          ));
      when(() => mockRepo.getProductUoms('prod-001')).thenAnswer((_) async => <ProductUomModel>[]);
      when(() => mockRepo.getProductMedia('prod-001')).thenAnswer((_) async => <ProductMediaModel>[]);
    }

    testWidgets('loads and displays every field from the saved product', (tester) async {
      stubExistingProduct();

      await pumpApp(
        tester,
        const ProductEntryScreen(productId: 'prod-001'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Title shows the loaded product's own name once loaded (not "Edit
      // Product") — and the Product Name field's own EditableText displays
      // the identical string, so this is genuinely 2 matches, not 1.
      expect(find.text('Widget A'), findsNWidgets(2));
      expect(find.text('WID-A'), findsOneWidget);
      expect(find.text('Trading / Resale'), findsOneWidget); // Product Nature dropdown
      expect(find.text('Piece'), findsOneWidget); // Base UOM dropdown
      expect(find.text('No Tracking'), findsOneWidget); // Tracking Type dropdown

      // Standard Cost is a SakalFormattedNumberField — its OWN plain
      // controller holds '10.5' but the field it actually renders is a
      // separate display controller reformatted via AppNumberFormat.rate
      // (2 decimal places by default) on initState, so the on-screen text
      // is '10.50', not the raw '10.5'.
      expect(find.text('10.50'), findsOneWidget);
      // Average Cost / Last Purchase are plain read-only fields, 4 decimal
      // places (AppNumberFormat.rate(..., decimalPlaces: 4)).
      expect(find.text('9.7500'), findsOneWidget);
      expect(find.text('10.0000'), findsOneWidget);

      expect(find.text('Original remarks'), findsOneWidget);

      expect(find.text('Save Product'), findsOneWidget);
    });

    testWidgets('editing remarks and saving calls the repository with the updated payload', (tester) async {
      stubExistingProduct();
      when(() => mockRepo.saveProduct(any(), isNew: any(named: 'isNew'))).thenAnswer((_) async {});

      await pumpApp(
        tester,
        const ProductEntryScreen(productId: 'prod-001'),
        overrides: overrides(),
        session: testSession(),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.text('Original remarks'), 'Updated remarks');
      await tester.tap(find.text('Save Product'));
      await _pumpBriefly(tester);

      final captured = verify(() => mockRepo.saveProduct(captureAny(), isNew: any(named: 'isNew'))).captured;
      final payload = captured[0] as Map<String, dynamic>;

      expect(payload['id'], 'prod-001');
      expect(payload['client_id'], 'client-001');
      expect(payload['company_id'], 'company-001');
      expect(payload['product_code'], 'WID-A');
      expect(payload['product_name'], 'Widget A');
      expect(payload['base_uom_id'], 'uom-001');
      expect(payload['standard_cost'], 10.5);
      expect(payload['tracking_type'], 'NONE');
      expect(payload['is_active'], true);
      expect(payload['is_scalable'], false);
      expect(payload['flags'], <String, bool>{});
      expect(payload['remarks'], 'Updated remarks');
      // !_isNew -> 'updated_by'/'updated_at' are stamped, 'created_by' is not.
      expect(payload['updated_by'], 'user-001');
      expect(payload.containsKey('updated_at'), true);
      expect(payload.containsKey('created_by'), false);

      // This screen's own success feedback is a persistent banner
      // (_successMsg), separate from and worded differently than the
      // transient SnackBar ('Product saved.') — asserting the banner text
      // avoids racing the SnackBar's ~4s auto-dismiss timer.
      expect(find.text('Product saved successfully.'), findsOneWidget);
    });
  });
}

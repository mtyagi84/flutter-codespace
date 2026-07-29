import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/utils/responsive.dart';

// Responsive's methods all read MediaQuery.sizeOf(context), so they need a
// real BuildContext — this is the one widget-level test in an otherwise pure
// core/utils test batch. See CLAUDE.md's Responsive Breakpoints note: isTablet
// (600-1024px) was defined but never actually used anywhere for a long time —
// these tests exist so a future regression on the breakpoint boundaries
// itself (not just call sites) gets caught immediately.
void main() {
  Future<Map<String, bool>> resultsAtWidth(WidgetTester tester, double width) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );
    return {
      'isMobile': Responsive.isMobile(capturedContext),
      'isTablet': Responsive.isTablet(capturedContext),
      'isDesktop': Responsive.isDesktop(capturedContext),
      'isTabletOrDesktop': Responsive.isTabletOrDesktop(capturedContext),
    };
  }

  group('Responsive breakpoints', () {
    testWidgets('a narrow phone width (< 600) is mobile only', (tester) async {
      final r = await resultsAtWidth(tester, 375);
      expect(r, {'isMobile': true, 'isTablet': false, 'isDesktop': false, 'isTabletOrDesktop': false});
    });

    testWidgets('exactly 600 is the mobile/tablet boundary — belongs to tablet, not mobile', (tester) async {
      final r = await resultsAtWidth(tester, 600);
      expect(r, {'isMobile': false, 'isTablet': true, 'isDesktop': false, 'isTabletOrDesktop': true});
    });

    testWidgets('a mid-range tablet width (600-1024) is tablet only', (tester) async {
      final r = await resultsAtWidth(tester, 800);
      expect(r, {'isMobile': false, 'isTablet': true, 'isDesktop': false, 'isTabletOrDesktop': true});
    });

    testWidgets('exactly 1024 is the tablet/desktop boundary — belongs to desktop, not tablet', (tester) async {
      final r = await resultsAtWidth(tester, 1024);
      expect(r, {'isMobile': false, 'isTablet': false, 'isDesktop': true, 'isTabletOrDesktop': true});
    });

    testWidgets('a wide desktop width (>= 1024) is desktop only', (tester) async {
      final r = await resultsAtWidth(tester, 1440);
      expect(r, {'isMobile': false, 'isTablet': false, 'isDesktop': true, 'isTabletOrDesktop': true});
    });

    testWidgets('isMobile and isTabletOrDesktop are always exact opposites, at every width', (tester) async {
      for (final width in [200.0, 599.0, 600.0, 900.0, 1023.0, 1024.0, 2000.0]) {
        final r = await resultsAtWidth(tester, width);
        expect(r['isMobile'], !r['isTabletOrDesktop']!, reason: 'mismatch at width $width');
      }
    });
  });
}

# Nexus ERP Master Redesign Specification
### Target: Adaptive Flutter Web & Mobile App (Single Codebase)
### Design System Style: ProData High-Density Adaptive System

This document is compiled as a master visual and technical specification for **Claude Code** to execute a comprehensive UI/UX redesign of our Flutter ERP. It contains architectural strategies, pixel-perfect layout instructions, copy-pasteable Dart classes, and high-fidelity prompt templates.

---

## 1. Core UX Architectural Principles

### A. The Adaptive Grid Strategy (Single Codebase)
Instead of building separate apps for Web and Mobile, we implement an **Adaptive Shell** utilizing Flutter's `LayoutBuilder`. 
* **Desktop Web (Width > 900px):** Permanent high-density sidebar navigation menu (240px wide) + Inline custom action headers + Multi-column bento grids + Sticky right sidebar financial panels.
* **Mobile App (Width <= 900px):** Standard clean Top AppBar with Back button + Collapsible accordion cards + Swipeable horizontal scroll tables + Bottom Navigation Bar (44px min tap targets).

### B. High-Density Layout Rules
* **Row Height Optimization:** Row heights for master data tables are strictly set to **40px (Dense)** or **52px (Comfortable)** to maximize immediate vertical information display.
* **Baseline Rhythm:** Standard 4px grid. Padding is structured in steps of `4`, `8`, `12`, `16`, `24`.
* **Zero Horizonal Clipping:** All form fields and columns use `TextOverflow.ellipsis` to gracefully adapt to small viewports.

---

## 2. Dynamic Theme Engine with 4 Corporate Palettes

To allow users to switch themes on-the-fly, we implement a custom state manager (`ThemeController` or standard `ChangeNotifier`) that maps the active selection to custom constructed Material 3 `ThemeData`.

### Flutter Theme State Manager & Palettes
```dart
// lib/theme/erp_theme.dart
import 'package:flutter/material.dart';

enum ErpThemePreset { navy, emerald, slate, terracotta }

class ErpThemeConfig {
  final String name;
  final Color primary;
  final Color secondary;
  final Color background;
  final Color surface;
  final Color accent;

  const ErpThemeConfig({
    required this.name,
    required this.primary,
    required this.secondary,
    required this.background,
    required this.surface,
    required this.accent,
  });

  static const Map<ErpThemePreset, ErpThemeConfig> presets = {
    ErpThemePreset.navy: ErpThemeConfig(
      name: "Classic Navy (Corporate)",
      primary: Color(0xFF0F172A),
      secondary: Color(0xFF2563EB),
      background: Color(0xFFF8FAFC),
      surface: Color(0xFFF1F5F9),
      accent: Color(0xFF3B82F6),
    ),
    ErpThemePreset.emerald: ErpThemeConfig(
      name: "Emerald Forest (Logistics)",
      primary: Color(0xFF065F46),
      secondary: Color(0xFF0284C7),
      background: Color(0xFFF4F7F6),
      surface: Color(0xFFE6EDEA),
      accent: Color(0xFF047857),
    ),
    ErpThemePreset.slate: ErpThemeConfig(
      name: "Cosmic Slate (Modern Tech)",
      primary: Color(0xFF1E293B),
      secondary: Color(0xFF4F46E5),
      background: Color(0xFFF8FAFC),
      surface: Color(0xFFF1F5F9),
      accent: Color(0xFF312E81),
    ),
    ErpThemePreset.terracotta: ErpThemeConfig(
      name: "Warm Terracotta (Commerce)",
      primary: Color(0xFF9A3412),
      secondary: Color(0xFFB45309),
      background: Color(0xFFFDF8F6),
      surface: Color(0xFFF5E8E2),
      accent: Color(0xFF7C2D12),
    ),
  };

  static ThemeData getTheme(ErpThemePreset preset) {
    final config = presets[preset]!;
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: config.primary,
        primary: config.primary,
        secondary: config.secondary,
        background: config.background,
        surface: Colors.white,
      ),
      fontFamily: 'Inter',
      scaffoldBackgroundColor: config.background,
      cardTheme: CardTheme(
        color: Colors.white,
        elevation: 0.5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: config.secondary, width: 2),
        ),
      ),
    );
  }
}
```

---

## 3. Pixel-Perfect Blueprints for Core Layouts

### Blueprint A: Adaptive Shell Navigation Shell
Using `LayoutBuilder` to toggle between desktop sidebar and mobile bottom navigation.

```dart
// lib/widgets/adaptive_navigation_shell.dart
import 'package:flutter/material.dart';
import '../theme/erp_theme.dart';

class AdaptiveNavigationShell extends StatefulWidget {
  final Widget child;
  final Function(ErpThemePreset) onThemeChanged;
  final ErpThemePreset currentPreset;

  const AdaptiveNavigationShell({
    super.key, 
    required this.child,
    required this.onThemeChanged,
    required this.currentPreset,
  });

  @override
  State<AdaptiveNavigationShell> createState() => _AdaptiveNavigationShellState();
}

class _AdaptiveNavigationShellState extends State<AdaptiveNavigationShell> {
  int _currentIndex = 1; // "Receipts" index

  @override
  Widget build(BuildContext context) {
    final activeTheme = ErpThemeConfig.presets[widget.currentPreset]!;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth > 900;
        
        return Scaffold(
          appBar: !isDesktop 
              ? AppBar(
                  backgroundColor: Colors.white,
                  title: Text(
                    'GRN/HO/2026/00007', 
                    style: TextStyle(color: activeTheme.primary, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  actions: [
                    _buildThemeDropdown(),
                    IconButton(icon: const Icon(Icons.print_outlined), onPressed: () {}),
                  ],
                )
              : null,
          body: Row(
            children: [
              if (isDesktop) _buildSidebar(activeTheme),
              Expanded(
                child: Column(
                  children: [
                    if (isDesktop) _buildDesktopHeader(activeTheme),
                    Expanded(child: widget.child),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: !isDesktop 
              ? BottomNavigationBar(
                  currentIndex: _currentIndex,
                  type: BottomNavigationBarType.fixed,
                  selectedItemColor: activeTheme.secondary,
                  onTap: (index) => setState(() => _currentIndex = index),
                  items: const [
                    BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
                    BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'Receipts'),
                    BottomNavigationBarItem(icon: Icon(Icons.inventory_2_outlined), label: 'Inventory'),
                    BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'Settings'),
                  ],
                )
              : null,
        );
      },
    );
  }

  Widget _buildThemeDropdown() {
    return DropdownButton<ErpThemePreset>(
      value: widget.currentPreset,
      onChanged: (val) {
        if (val != null) widget.onThemeChanged(val);
      },
      underline: const SizedBox(),
      items: ErpThemePreset.values.map((preset) {
        return DropdownMenuItem(
          value: preset,
          child: Text(ErpThemeConfig.presets[preset]!.name.split(' ')[0]),
        );
      }).toList(),
    );
  }

  Widget _buildSidebar(ErpThemeConfig theme) {
    return Container(
      width: 240,
      color: theme.surface,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            color: theme.primary,
            child: const Row(
              children: [
                Icon(Icons.warehouse_outlined, color: Colors.white),
                SizedBox(width: 12),
                Text('Main Warehouse', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          // Sidebar Nav Elements
          _buildSidebarItem('Dashboard', Icons.dashboard_outlined, false, theme),
          _buildSidebarItem('Receipts', Icons.receipt_long, true, theme),
          _buildSidebarItem('Inventory', Icons.inventory_2_outlined, false, theme),
          _buildSidebarItem('Finance', Icons.payments_outlined, false, theme),
          const Spacer(),
          _buildThemeSelectorWidget(theme),
          _buildSidebarItem('Settings', Icons.settings, false, theme),
        ],
      ),
    );
  }

  Widget _buildSidebarItem(String title, IconData icon, bool isActive, ErpThemeConfig theme) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isActive ? theme.secondary.withOpacity(0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: Icon(icon, color: isActive ? theme.secondary : Colors.grey),
        title: Text(title, style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.normal, color: isActive ? theme.primary : Colors.grey.shade700)),
        dense: true,
      ),
    );
  }

  Widget _buildThemeSelectorWidget(ErpThemeConfig theme) { ... }
  Widget _buildDesktopHeader(ErpThemeConfig theme) { ... }
}
```

### Blueprint B: High-Density Zebra Data Table
Optimized for goods entries, using horizontal scrolling on mobile and compact row heights.

```dart
// lib/widgets/dense_zebra_table.dart
import 'package:flutter/material.dart';

class DenseZebraTable extends StatelessWidget {
  final List<dynamic> items;
  final bool isCompact; // Controlled by the global density toggle (Dense vs Comfortable)

  const DenseZebraTable({super.key, required this.items, required this.isCompact});

  @override
  Widget build(BuildContext context) {
    final double rowHeight = isCompact ? 40.0 : 54.0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Table header bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFFF1F5F9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.between,
              children: [
                const Text('Line Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Chip(
                  label: const Text('1 Product Selected', style: TextStyle(color: Colors.white, fontSize: 10)),
                  backgroundColor: Theme.of(context).primaryColor,
                ),
              ],
            ),
          ),
          // horizontal single child scrollview keeps web tables readable and mobile tables non-clipping
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: MaterialStateProperty.all(Theme.of(context).primaryColor),
              headingTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
              dataRowHeight: rowHeight,
              horizontalMargin: 12,
              columnSpacing: 16,
              columns: const [
                DataColumn(label: Text('Product Name')),
                DataColumn(label: Text('UOM')),
                DataColumn(label: Text('Qty', numeric: true)),
                DataColumn(label: Text('Rate (EUR)', numeric: true)),
                DataColumn(label: Text('Disc %', numeric: true)),
                DataColumn(label: Text('Tax Group')),
                DataColumn(label: Text('Amount', numeric: true)),
              ],
              rows: List.generate(items.length, (index) {
                final item = items[index];
                final isOdd = index % 2 != 0;
                return DataRow(
                  color: MaterialStateProperty.all(isOdd ? Colors.black.withOpacity(0.015) : Colors.white),
                  cells: [
                    DataCell(Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text(item.sku, style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                      ],
                    )),
                    DataCell(Text(item.uom, style: const TextStyle(fontSize: 12))),
                    DataCell(Text(item.qty.toString(), style: const TextStyle(fontWeight: FontWeight.w600))),
                    DataCell(Text(item.rate.toString())),
                    DataCell(Text('${item.discount}%')),
                    DataCell(Text(item.taxGroup, style: const TextStyle(fontSize: 11))),
                    DataCell(Text(item.amount.toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
```

### Blueprint C: Sticky/Floating Financial Summary Card
Contrasting brand accent color, always in view on widescreen, stacks nicely at the bottom on mobile view.

```dart
// lib/widgets/financial_summary_card.dart
import 'package:flutter/material.dart';

class FinancialSummaryCard extends StatelessWidget {
  final double gross;
  final double discount;
  final double tax;
  final double grandTotal;

  const FinancialSummaryCard({
    super.key, 
    required this.gross, 
    required this.discount, 
    required this.tax, 
    required this.grandTotal,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: primaryColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FINANCIAL SUMMARY',
            style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
          const SizedBox(height: 16),
          _buildSummaryRow('Gross Amount', gross.toStringAsFixed(2)),
          _buildSummaryRow('Discount', '- (${discount.toStringAsFixed(2)})', isDiscount: true),
          _buildSummaryRow('Total Tax', tax.toStringAsFixed(2)),
          const Divider(color: Colors.white24, height: 24, thickness: 1),
          const Text(
            'Grand Total (EUR)',
            style: TextStyle(color: Colors.white70, fontSize: 10),
          ),
          const SizedBox(height: 4),
          Text(
            '€${grandTotal.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.white70, size: 14),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Landed cost calculations included',
                    style: TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isDiscount = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.between,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: isDiscount ? const Color(0xFFFFCDD2) : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
```

---

## 4. The Golden Instruction Prompt for Claude Code

Copy the entire block below and paste it directly into **Claude Code** to run the redesign command.

```text
================================================================================
CLAUDE CODE TASK: FLUTTER ERP UI/UX REDESIGN (DESKTOP & MOBILE ADAPTIVE)
================================================================================

We are redesigning our Flutter ERP for both Mobile and Web using a single codebase.
Please implement the following layout paradigms exactly as specified:

1. THEME ENGINE STATE (4 Preset Swapper):
- Implement a reactive ChangeNotifier called `ThemeController` that manages the selected ThemePreset:
  * navy: Color(0xFF0F172A) primary, Color(0xFF2563EB) accent, Color(0xFFF8FAFC) background.
  * emerald: Color(0xFF065F46) primary, Color(0xFF0284C7) accent, Color(0xFFF4F7F6) background.
  * slate: Color(0xFF1E293B) primary, Color(0xFF4F46E5) accent, Color(0xFFF8FAFC) background.
  * terracotta: Color(0xFF9A3412) primary, Color(0xFFB45309) accent, Color(0xFFF5E8E2) background.
- Include a small dropdown or popup widget in the layout headers allowing users to swap themes live.

2. ADAPTIVE SHELL (LayoutBuilder):
- Widescreen (> 900px):
  * Left permanent Sidebar Navigation Rail (240px width) with Warehouse selectors, navigation routes, and the active theme preset dropdown.
  * Desktop top header containing GRN breadcrumbs and approved status badge.
- Mobile View (<= 900px):
  * Standard AppBar displaying GRN number and approved label.
  * Modern Bottom Navigation Bar with clear icons (Dashboard, Receipts, Inventory, Settings).

3. HIGH DENSITY LAYOUT (Compact Density Toggle):
- Add a boolean toggle `isCompact` to the state.
- When `isCompact` is TRUE (Dense), set row heights in all DataTables to exactly 40.0. All margins should scale to 12.0.
- When `isCompact` is FALSE (Comfortable), set row heights to 54.0. Margins should scale to 18.0.

4. WIDGET REFACTORINGS:
- Wrap all core Tables in `SingleChildScrollView(scrollDirection: Axis.horizontal)` so mobile screens scroll tables horizontally instead of clipping layout borders.
- Style the financial summary card with high visual contrast utilizing the active primary theme color as a solid background with clear white display typography.

Please scan our existing files, construct these components cleanly, wire the theme notifier to root MaterialApp builder, and verify there are no Dart compilation errors.
================================================================================
```

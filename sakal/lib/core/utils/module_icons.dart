import 'package:flutter/material.dart';

/// Module-code → icon map, shared by the sidebar's own module accordion
/// and the Dashboard's Quick Access grid — extracted so both render the
/// same icon for the same module rather than maintaining two copies.
const Map<String, IconData> kModuleIcons = <String, IconData>{
  'AD': Icons.admin_panel_settings_outlined,
  'SL': Icons.point_of_sale_outlined,
  'PR': Icons.shopping_cart_outlined,
  'IN': Icons.inventory_2_outlined,
  'FN': Icons.account_balance_outlined,
};

IconData moduleIconFor(String moduleCode) => kModuleIcons[moduleCode] ?? Icons.apps_outlined;

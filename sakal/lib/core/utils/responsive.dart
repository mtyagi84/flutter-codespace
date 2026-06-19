import 'package:flutter/material.dart';

class Responsive {
  static const double _mobileBreak = 600;
  static const double _tabletBreak = 1024;

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < _mobileBreak;

  static bool isTablet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= _mobileBreak && w < _tabletBreak;
  }

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= _tabletBreak;

  static bool isTabletOrDesktop(BuildContext context) => !isMobile(context);
}

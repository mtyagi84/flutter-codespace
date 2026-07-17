import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/menu_models.dart';

class UserSession {
  final String userId;
  final String clientId;
  final String clientNo;
  final String companyId;
  final String companyName;
  final String? locationId;
  final String fullName;
  final String username;
  final bool   offlineMode;
  final bool   enableBarcode;
  final bool   enablePartNumber;
  final String qtyEntryMode;
  final bool   quickInvoiceDispatchStock;
  final bool   quickInvoiceCollectCash;

  const UserSession({
    required this.userId,
    required this.clientId,
    required this.clientNo,
    required this.companyId,
    required this.companyName,
    this.locationId,
    required this.fullName,
    required this.username,
    this.offlineMode      = false,
    this.enableBarcode    = false,
    this.enablePartNumber = false,
    this.qtyEntryMode     = 'PACK_AND_LOOSE',
    this.quickInvoiceDispatchStock = true,
    this.quickInvoiceCollectCash   = true,
  });

  UserSession copyWith({
    String? companyId,
    String? companyName,
    bool?   enableBarcode,
    bool?   enablePartNumber,
    String? qtyEntryMode,
    bool?   quickInvoiceDispatchStock,
    bool?   quickInvoiceCollectCash,
  }) =>
      UserSession(
        userId:           userId,
        clientId:         clientId,
        clientNo:         clientNo,
        companyId:        companyId        ?? this.companyId,
        companyName:      companyName      ?? this.companyName,
        locationId:       locationId,
        fullName:         fullName,
        username:         username,
        offlineMode:      offlineMode,
        enableBarcode:    enableBarcode    ?? this.enableBarcode,
        enablePartNumber: enablePartNumber ?? this.enablePartNumber,
        qtyEntryMode:     qtyEntryMode     ?? this.qtyEntryMode,
        quickInvoiceDispatchStock: quickInvoiceDispatchStock ?? this.quickInvoiceDispatchStock,
        quickInvoiceCollectCash:   quickInvoiceCollectCash   ?? this.quickInvoiceCollectCash,
      );
}

final sessionProvider = StateProvider<UserSession?>((ref) => null);

final menuProvider = StateProvider<List<MenuModule>>((ref) => []);

final sidebarCollapsedProvider = StateProvider<bool>((ref) => false);

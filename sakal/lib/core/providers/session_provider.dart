import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/menu_models.dart';
import '../network/dio_client.dart';

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
  final String numberFormat;

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
    this.numberFormat = 'INTERNATIONAL',
  });

  UserSession copyWith({
    String? companyId,
    String? companyName,
    bool?   enableBarcode,
    bool?   enablePartNumber,
    String? qtyEntryMode,
    bool?   quickInvoiceDispatchStock,
    bool?   quickInvoiceCollectCash,
    String? numberFormat,
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
        numberFormat:     numberFormat     ?? this.numberFormat,
      );
}

final sessionProvider = StateProvider<UserSession?>((ref) => null);

final menuProvider = StateProvider<List<MenuModule>>((ref) => []);

final sidebarCollapsedProvider = StateProvider<bool>((ref) => false);

// Which modules are currently open in the sidebar's expanded (240px) tree
// view — moved out of Sidebar's own local State so it survives widget
// rebuilds within the session (previously reset to "all expanded" on
// every Sidebar remount, not just app restart). Session-lifetime only,
// same no-disk-persistence precedent as sidebarCollapsedProvider itself.
// Starts empty; Sidebar seeds it once with just the current route's own
// module on first build, not eagerly here, since that seeding needs the
// active route/menu tree which aren't available at provider-construction
// time.
final sidebarExpandedModulesProvider = StateProvider<Set<String>>((ref) => {});

// A user's own print-mode preference for the post-save "print now?" flow
// (Quick Invoice and, in future, other transaction screens) — 'DIRECT'
// (open the PDF and immediately trigger the browser's print dialog) or
// 'ON_SCREEN' (today's plain download), backed by ric_user_preferences
// (migration 203). Fetched once at login/company-switch alongside the
// menu fetch; defaults to 'ON_SCREEN' (matching the table's own DEFAULT)
// until the user explicitly picks Direct Print, at which point the row
// is created lazily — no write on every login for a user who never
// touches this setting.
final userPreferencesProvider = StateProvider<String>((ref) => 'ON_SCREEN');

Future<String> fetchPrintMode(UserSession session) async {
  try {
    final res = await DioClient.instance.get('/ric_user_preferences', queryParameters: {
      'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
      'user_id': 'eq.${session.userId}', 'select': 'print_mode', 'limit': '1',
    });
    final list = res.data as List;
    return list.isNotEmpty ? (list.first as Map<String, dynamic>)['print_mode'] as String? ?? 'ON_SCREEN' : 'ON_SCREEN';
  } catch (_) {
    return 'ON_SCREEN';
  }
}

Future<void> setPrintMode(WidgetRef ref, UserSession session, String mode) async {
  await DioClient.instance.post(
    '/ric_user_preferences',
    data: {
      'client_id': session.clientId, 'company_id': session.companyId,
      'user_id': session.userId, 'print_mode': mode,
    },
    queryParameters: {'on_conflict': 'client_id,company_id,user_id'},
    options: Options(headers: {'Prefer': 'resolution=merge-duplicates'}),
  );
  ref.read(userPreferencesProvider.notifier).state = mode;
}

// Same shape/lifetime as sidebarExpandedModulesProvider, one level down —
// which GROUPS (within an already-expanded module) currently have their
// own feature list open. Added so a group's accordion can actually be
// collapsed (see Sidebar._buildGroup) instead of always rendering every
// feature the moment its parent module opens.
final sidebarExpandedGroupsProvider = StateProvider<Set<String>>((ref) => {});

// Toggles a single menu item's favorite/starred state — writes straight to
// ric_user_menu_favorites (a real DELETE/INSERT, not a soft-delete — this
// is a pure per-user UI preference row, not a business transaction record)
// then updates menuProvider's already-loaded tree in place so the star
// reflects instantly everywhere it's shown (sidebar, module/group landing
// pages, the Dashboard's Favorites strip) without a full menu re-fetch.
Future<void> toggleMenuFavorite(
  WidgetRef ref,
  UserSession session,
  String featureCode,
  bool newValue,
) async {
  if (newValue) {
    await DioClient.instance.post('/ric_user_menu_favorites', data: {
      'client_id': session.clientId, 'company_id': session.companyId,
      'user_id': session.userId, 'feature_code': featureCode,
    });
  } else {
    await DioClient.instance.delete('/ric_user_menu_favorites', queryParameters: {
      'client_id': 'eq.${session.clientId}', 'company_id': 'eq.${session.companyId}',
      'user_id': 'eq.${session.userId}', 'feature_code': 'eq.$featureCode',
    });
  }

  final updated = ref.read(menuProvider).map((m) => MenuModule(
        moduleCode: m.moduleCode, moduleName: m.moduleName, serialNo: m.serialNo,
        groups: m.groups.map((g) => MenuGroup(
              groupCode: g.groupCode, groupName: g.groupName, serialNo: g.serialNo,
              features: g.features.map((f) => f.featureCode == featureCode
                      ? f.copyWith(isFavorite: newValue)
                      : f)
                  .toList(),
            )).toList(),
      )).toList();
  ref.read(menuProvider.notifier).state = updated;
}

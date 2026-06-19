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

  const UserSession({
    required this.userId,
    required this.clientId,
    required this.clientNo,
    required this.companyId,
    required this.companyName,
    this.locationId,
    required this.fullName,
    required this.username,
    this.offlineMode = false,
  });

  UserSession copyWith({
    String? companyId,
    String? companyName,
  }) =>
      UserSession(
        userId:      userId,
        clientId:    clientId,
        clientNo:    clientNo,
        companyId:   companyId   ?? this.companyId,
        companyName: companyName ?? this.companyName,
        locationId:  locationId,
        fullName:    fullName,
        username:    username,
        offlineMode: offlineMode,
      );
}

final sessionProvider = StateProvider<UserSession?>((ref) => null);

final menuProvider = StateProvider<List<MenuModule>>((ref) => []);

final sidebarCollapsedProvider = StateProvider<bool>((ref) => false);

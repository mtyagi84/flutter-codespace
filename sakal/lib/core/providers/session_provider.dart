import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/menu_models.dart';

class UserSession {
  final String userId;
  final String clientId;
  final String clientNo;
  final String companyId;
  final String? locationId;
  final String fullName;
  final String username;

  const UserSession({
    required this.userId,
    required this.clientId,
    required this.clientNo,
    required this.companyId,
    this.locationId,
    required this.fullName,
    required this.username,
  });
}

// Holds user identity after login — cleared on app close
final sessionProvider = StateProvider<UserSession?>((ref) => null);

// Holds the sidebar menu for the logged-in user
final menuProvider = StateProvider<List<MenuModule>>((ref) => []);

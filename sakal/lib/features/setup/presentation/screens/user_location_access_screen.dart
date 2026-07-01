import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/user_location_access_helper.dart';
import '../widgets/location_access_picker.dart';

class UserLocationAccessScreen extends ConsumerStatefulWidget {
  const UserLocationAccessScreen({super.key});

  @override
  ConsumerState<UserLocationAccessScreen> createState() => _UserLocationAccessScreenState();
}

class _UserLocationAccessScreenState extends ConsumerState<UserLocationAccessScreen>
    with ScreenPermissionMixin<UserLocationAccessScreen> {
  @override String get screenName => '/setup/user-location-access';

  List<Map<String, dynamic>> _users     = [];
  List<Map<String, dynamic>> _locations = [];
  bool    _loading = true;
  bool    _loadingAccess = false;
  bool    _saving  = false;
  String? _error;

  String?      _userId;
  Set<String>  _selectedLocationIds = {};
  String?      _defaultLocationId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider)!;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DioClient.instance.get('/rim_users', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'select':     'id,full_name',
          'order':      'full_name.asc',
        }),
        DioClient.instance.get('/ric_locations', queryParameters: {
          'client_id':  'eq.${session.clientId}',
          'company_id': 'eq.${session.companyId}',
          'is_deleted': 'eq.false',
          'is_active':  'eq.true',
          'select':     'id,location_name',
          'order':      'location_name.asc',
        }),
      ]);
      if (mounted) {
        setState(() {
          _users     = List<Map<String, dynamic>>.from(results[0].data as List);
          _locations = List<Map<String, dynamic>>.from(results[1].data as List);
          _loading   = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load users or locations.'; });
    }
  }

  Future<void> _selectUser(String? userId) async {
    setState(() {
      _userId = userId;
      _selectedLocationIds = {};
      _defaultLocationId   = null;
    });
    if (userId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() => _loadingAccess = true);
    try {
      final result = await UserLocationAccessHelper.getForUser(
        clientId: session.clientId, companyId: session.companyId, userId: userId,
      );
      if (mounted) {
        setState(() {
          _selectedLocationIds = result['selected'] as Set<String>;
          _defaultLocationId   = result['default'] as String?;
          _loadingAccess = false;
        });
      }
    } on DioException {
      if (mounted) {
        setState(() { _loadingAccess = false; });
        _showMsg('Could not load location access for this user.', color: AppColors.negative);
      }
    }
  }

  Future<void> _save() async {
    if (_userId == null) return;
    final session = ref.read(sessionProvider)!;
    setState(() => _saving = true);
    try {
      await UserLocationAccessHelper.save(
        clientId: session.clientId,
        companyId: session.companyId,
        userId: _userId!,
        selectedLocationIds: _selectedLocationIds,
        defaultLocationId: _defaultLocationId,
        updatedBy: session.userId,
      );
      if (mounted) _showMsg('Location access saved.', color: AppColors.positive);
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String? ?? 'Save failed. Please try again.';
      _showMsg(msg, color: AppColors.negative);
    } catch (e) {
      _showMsg('Unexpected error: $e', color: AppColors.negative);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMsg(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('User Location Access',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text('Restrict which locations a user can work at, and mark their default location.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 24),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.negative.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.negative, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.negative))),
                      TextButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: _userId,
                              decoration: const InputDecoration(
                                labelText: 'Select User',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              items: _users
                                  .map((u) => DropdownMenuItem(
                                      value: u['id'] as String, child: Text(u['full_name'] as String)))
                                  .toList(),
                              onChanged: (canEdit && !offline) ? _selectUser : null,
                            ),
                            const SizedBox(height: 16),

                            if (_userId != null) ...[
                              const Text('Assigned Locations',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                              const SizedBox(height: 6),
                              _loadingAccess
                                  ? const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 20),
                                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                    )
                                  : LocationAccessPicker(
                                      key: ValueKey(_userId),
                                      locations: _locations,
                                      initialSelected: _selectedLocationIds,
                                      initialDefault: _defaultLocationId,
                                      onChanged: (selected, defaultId) => setState(() {
                                        _selectedLocationIds = selected;
                                        _defaultLocationId   = defaultId;
                                      }),
                                    ),
                              const SizedBox(height: 20),

                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  SizedBox(
                                    width: 140,
                                    child: ElevatedButton(
                                      onPressed: (_saving || !canEdit || offline) ? null : _save,
                                      child: _saving
                                          ? const SizedBox(
                                              height: 18, width: 18,
                                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                          : const Text('Save'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

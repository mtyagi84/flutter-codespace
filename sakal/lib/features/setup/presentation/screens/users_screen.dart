import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/screen_permission_mixin.dart';
import '../../../../core/widgets/offline_banner.dart';
import '../../data/user_location_access_helper.dart';
import '../widgets/location_access_picker.dart';

const _salutations = ['Mr', 'Mrs', 'Ms', 'Dr', 'Prof'];

const _languages = [
  {'code': 'en', 'label': 'English'},
  {'code': 'fr', 'label': 'French'},
  {'code': 'sw', 'label': 'Swahili'},
];

class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen>
    with ScreenPermissionMixin<UsersScreen> {
  @override String get screenName => '/setup/users';

  List<Map<String, dynamic>> _rows      = [];
  List<Map<String, dynamic>> _locations = [];
  bool    _loading = true;
  String? _error;

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
        DioClient.instance.get(
          '/rim_users',
          queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'is_deleted': 'eq.false',
            'select':
                'id,salutation,full_name,username,email,phone,'
                'language_code,theme,photo,is_active,default_location_id',
            'order': 'full_name.asc',
          },
        ),
        DioClient.instance.get(
          '/ric_locations',
          queryParameters: {
            'client_id':  'eq.${session.clientId}',
            'company_id': 'eq.${session.companyId}',
            'is_deleted': 'eq.false',
            'is_active':  'eq.true',
            'select':     'id,location_name',
            'order':      'location_name.asc',
          },
        ),
      ]);
      if (mounted) {
        setState(() {
          _rows      = List<Map<String, dynamic>>.from(results[0].data as List);
          _locations = List<Map<String, dynamic>>.from(results[1].data as List);
          _loading   = false;
        });
      }
    } on DioException {
      if (mounted) setState(() { _loading = false; _error = 'Could not load users.'; });
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> row) async {
    final newVal = !(row['is_active'] as bool? ?? true);
    try {
      await DioClient.instance.patch(
        '/rim_users',
        queryParameters: {'id': 'eq.${row['id']}'},
        data: {
          'is_active':  newVal,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      _load();
    } on DioException {
      _showError('Could not update status.');
    }
  }

  Future<void> _delete(String id) async {
    try {
      await DioClient.instance.patch(
        '/rim_users',
        queryParameters: {'id': 'eq.$id'},
        data: {
          'is_deleted': true,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        options: Options(headers: {'Prefer': 'return=minimal'}),
      );
      _load();
    } on DioException {
      _showError('Could not delete user.');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.negative),
    );
  }

  void _openDialog([Map<String, dynamic>? existing]) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UserDialog(
        existing: existing,
        locations: _locations,
        onSaved: _load,
      ),
    );
  }

  void _openResetPassword(Map<String, dynamic> row) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ResetPasswordDialog(
        userId:   row['id'] as String,
        userName: row['full_name'] as String? ?? row['username'] as String? ?? '',
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(sessionProvider)?.offlineMode ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('User Management',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        SizedBox(height: 4),
                        Text('Manage user accounts for this company.',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (canAdd && !offline)
                    ElevatedButton.icon(
                      onPressed: () => _openDialog(),
                      icon: const Icon(Icons.person_add_outlined, size: 18),
                      label: const Text('Add User'),
                    ),
                ],
              ),
              const SizedBox(height: 24),

              if (offline) const OfflineBanner(),
              if (offline) const SizedBox(height: 16),

              // ── Error banner ──────────────────────────────────────────
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
                      const Icon(Icons.error_outline,
                          color: AppColors.negative, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13, color: AppColors.negative))),
                      TextButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // ── Table ─────────────────────────────────────────────────
              Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _rows.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(Icons.group_outlined,
                                      size: 40, color: AppColors.textSecondary),
                                  SizedBox(height: 12),
                                  Text('No users yet.',
                                      style: TextStyle(
                                          color: AppColors.textSecondary)),
                                  Text('Click "Add User" to create one.',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _TableHeader(),
                              const Divider(height: 1),
                              ..._rows.asMap().entries.map((e) => _TableRow(
                                    row: e.value,
                                    isEven: e.key.isEven,
                                    canEdit: canEdit && !offline,
                                    onEdit: () => _openDialog(e.value),
                                    onToggle: () => _toggleActive(e.value),
                                    onDelete: () => _confirmDelete(
                                        e.value['id'] as String),
                                    onResetPassword: () =>
                                        _openResetPassword(e.value),
                                  )),
                            ],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete User?'),
        content: const Text(
            'This will mark the account as deleted. The user will no longer be able to log in.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppColors.negative))),
        ],
      ),
    );
    if (ok == true) _delete(id);
  }
}

// ── Table header ──────────────────────────────────────────────────────────────

class _TableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 48),
          SizedBox(width: 12),
          SizedBox(width: 200, child: _HCol('Name / Username')),
          SizedBox(width: 190, child: _HCol('Email')),
          SizedBox(width: 130, child: _HCol('Phone')),
          SizedBox(width: 80,  child: _HCol('Language')),
          SizedBox(width: 80,  child: _HCol('Active')),
          SizedBox(width: 130, child: _HCol('Actions')),
        ],
      ),
    );
  }
}

class _HCol extends StatelessWidget {
  final String text;
  const _HCol(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.3));
  }
}

// ── Table row ─────────────────────────────────────────────────────────────────

class _TableRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool isEven;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onResetPassword;

  const _TableRow({
    required this.row,
    required this.isEven,
    required this.canEdit,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    required this.onResetPassword,
  });

  @override
  Widget build(BuildContext context) {
    final active     = row['is_active'] as bool? ?? true;
    final fullName   = row['full_name']  as String? ?? '';
    final salutation = row['salutation'] as String?;
    final username   = row['username']   as String? ?? '';
    final langCode    = row['language_code'] as String? ?? 'en';
    final photoBase64 = row['photo'] as String?;

    final displayName = [if (salutation != null) salutation, fullName]
        .where((s) => s.isNotEmpty)
        .join(' ');

    return Container(
      color: isEven
          ? Colors.transparent
          : AppColors.surfaceVariant.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Avatar(
            photoBase64: photoBase64,
            initials: _initials(fullName),
            active: active,
          ),
          const SizedBox(width: 12),

          SizedBox(
            width: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                Text('@$username',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),

          SizedBox(
            width: 190,
            child: Text(row['email'] as String? ?? '—',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textPrimary)),
          ),

          SizedBox(
            width: 130,
            child: Text(row['phone'] as String? ?? '—',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textPrimary)),
          ),

          SizedBox(
            width: 80,
            child: _LangChip(code: langCode),
          ),

          SizedBox(
            width: 80,
            child: Switch(
              value: active,
              onChanged: canEdit ? (_) => onToggle() : null,
              activeThumbColor: AppColors.positive,
            ),
          ),

          SizedBox(
            width: 130,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: AppColors.primary),
                  onPressed: canEdit ? onEdit : null,
                ),
                IconButton(
                  tooltip: 'Reset Password',
                  icon: const Icon(Icons.lock_reset_outlined,
                      size: 18, color: AppColors.secondary),
                  onPressed: canEdit ? onResetPassword : null,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppColors.negative),
                  onPressed: canEdit ? onDelete : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      return parts[0][0].toUpperCase();
    }
    return '?';
  }
}

// ── Avatar ────────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String? photoBase64;
  final String  initials;
  final bool    active;

  const _Avatar({this.photoBase64, required this.initials, required this.active});

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoBase64 != null && photoBase64!.isNotEmpty;
    return Stack(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: AppColors.primary.withValues(alpha: 0.12),
          backgroundImage: hasPhoto
              ? MemoryImage(const Base64Decoder().convert(photoBase64!))
              : null,
          child: !hasPhoto
              ? Text(initials,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary))
              : null,
        ),
        if (!active)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.negative,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Language chip ─────────────────────────────────────────────────────────────

class _LangChip extends StatelessWidget {
  final String code;
  const _LangChip({required this.code});

  @override
  Widget build(BuildContext context) {
    final label = const {
      'en': 'EN',
      'fr': 'FR',
      'sw': 'SW',
    }[code] ?? code.toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.primary)),
    );
  }
}

// ── Add / Edit Dialog ─────────────────────────────────────────────────────────

class _UserDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic>?        existing;
  final List<Map<String, dynamic>>   locations;
  final VoidCallback                 onSaved;

  const _UserDialog({
    this.existing,
    required this.locations,
    required this.onSaved,
  });

  @override
  ConsumerState<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends ConsumerState<_UserDialog> {
  final _formKey     = GlobalKey<FormState>();
  final _nameCtrl    = TextEditingController();
  final _userCtrl    = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _pwCtrl      = TextEditingController();
  final _confirmCtrl = TextEditingController();

  String? _salutation;
  String  _language    = 'en';
  String  _theme       = 'light';
  Set<String> _selectedLocationIds = {};
  String? _defaultLocationId;
  bool    _loadingAccess = false;
  String? _photoBase64;
  bool    _mustChange  = true;
  bool    _saving      = false;
  String? _error;
  bool    _showPw      = false;
  bool    _showConfirm = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _nameCtrl.text  = d['full_name']           ?? '';
      _userCtrl.text  = d['username']            ?? '';
      _emailCtrl.text = d['email']               ?? '';
      _phoneCtrl.text = d['phone']               ?? '';
      _salutation     = d['salutation']          as String?;
      _language       = d['language_code']       as String? ?? 'en';
      _theme          = d['theme']               as String? ?? 'light';
      _photoBase64    = d['photo']               as String?;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAccess(d['id'] as String));
    }
  }

  Future<void> _loadAccess(String userId) async {
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
      if (mounted) setState(() => _loadingAccess = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 400,
      maxHeight: 400,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    setState(() => _photoBase64 = base64Encode(bytes));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() { _saving = true; _error = null; });
    final session = ref.read(sessionProvider)!;
    final now     = DateTime.now().toUtc().toIso8601String();

    try {
      String userId;
      if (_isEdit) {
        userId = widget.existing!['id'] as String;
        await DioClient.instance.patch(
          '/rim_users',
          queryParameters: {'id': 'eq.$userId'},
          data: {
            'salutation':          _salutation,
            'full_name':           _nameCtrl.text.trim(),
            'email':               _emailCtrl.text.trim().isEmpty
                ? null : _emailCtrl.text.trim(),
            'phone':               _phoneCtrl.text.trim().isEmpty
                ? null : _phoneCtrl.text.trim(),
            'photo':               _photoBase64,
            'language_code':       _language,
            'theme':               _theme,
            'updated_at':          now,
            'updated_by':          session.userId,
          },
          options: Options(headers: {'Prefer': 'return=minimal'}),
        );
      } else {
        final res = await DioClient.instance.post(
          '/rpc/fn_create_user',
          data: {
            'p_client_id':            session.clientId,
            'p_company_id':           session.companyId,
            'p_location_id':          _defaultLocationId,
            'p_username':             _userCtrl.text.trim(),
            'p_full_name':            _nameCtrl.text.trim(),
            'p_salutation':           _salutation,
            'p_email':                _emailCtrl.text.trim().isEmpty
                ? null : _emailCtrl.text.trim(),
            'p_phone':                _phoneCtrl.text.trim().isEmpty
                ? null : _phoneCtrl.text.trim(),
            'p_photo':                _photoBase64,
            'p_language_code':        _language,
            'p_theme':                _theme,
            'p_password':             _pwCtrl.text,
            'p_must_change_password': _mustChange,
            'p_created_by':           session.userId,
          },
        );
        userId = res.data as String;
      }

      await UserLocationAccessHelper.save(
        clientId: session.clientId,
        companyId: session.companyId,
        userId: userId,
        selectedLocationIds: _selectedLocationIds,
        defaultLocationId: _defaultLocationId,
        updatedBy: session.userId,
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      widget.onSaved();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String?
          ?? 'Save failed. Please try again.';
      if (mounted) setState(() { _saving = false; _error = msg; });
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = 'Unexpected error: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Dialog header ──────────────────────────────────────
                Row(
                  children: [
                    Icon(
                      _isEdit
                          ? Icons.edit_outlined
                          : Icons.person_add_outlined,
                      color: AppColors.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _isEdit ? 'Edit User' : 'Add User',
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
                  ],
                ),
                const SizedBox(height: 20),

                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.negative.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.negative)),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── Row 1: Title + Full Name ───────────────────────────
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: DropdownButtonFormField<String>(
                        initialValue: _salutation,
                        decoration: const InputDecoration(labelText: 'Title'),
                        items: [
                          const DropdownMenuItem(
                              value: null, child: Text('—')),
                          ..._salutations.map((s) =>
                              DropdownMenuItem(value: s, child: Text(s))),
                        ],
                        onChanged: (v) => setState(() => _salutation = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Full Name *',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Full name is required'
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Row 2: Username + Email ────────────────────────────
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _userCtrl,
                        readOnly: _isEdit,
                        decoration: InputDecoration(
                          labelText: 'Username *',
                          prefixIcon: const Icon(Icons.alternate_email),
                          filled: _isEdit,
                          fillColor: _isEdit
                              ? AppColors.surfaceVariant.withValues(alpha: 0.5)
                              : null,
                          helperText: _isEdit ? 'Username cannot be changed' : null,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Username is required'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Row 3: Phone ────────────────────────────────────────
                TextFormField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 14),

                // ── Row 4: Language + Theme ────────────────────────────
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _language,
                        decoration: const InputDecoration(
                          labelText: 'Language',
                          prefixIcon: Icon(Icons.language_outlined),
                        ),
                        items: _languages
                            .map((l) => DropdownMenuItem(
                                  value: l['code'] as String,
                                  child: Text(l['label'] as String),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _language = v ?? 'en'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _theme,
                        decoration: const InputDecoration(
                          labelText: 'Theme',
                          prefixIcon: Icon(Icons.palette_outlined),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'light', child: Text('Light')),
                          DropdownMenuItem(
                              value: 'dark', child: Text('Dark')),
                        ],
                        onChanged: (v) =>
                            setState(() => _theme = v ?? 'light'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Assigned Locations ──────────────────────────────────
                const Text('Assigned Locations',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                _loadingAccess
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : LocationAccessPicker(
                        key: ValueKey(widget.existing?['id'] ?? 'new'),
                        locations: widget.locations,
                        initialSelected: _selectedLocationIds,
                        initialDefault: _defaultLocationId,
                        onChanged: (selected, defaultId) => setState(() {
                          _selectedLocationIds = selected;
                          _defaultLocationId   = defaultId;
                        }),
                      ),
                const SizedBox(height: 14),

                // ── Profile Photo ──────────────────────────────────────
                _PhotoPicker(
                  photoBase64: _photoBase64,
                  initials: _nameCtrl.text.trim().isEmpty
                      ? '?'
                      : _nameCtrl.text.trim()[0].toUpperCase(),
                  onPick: _pickPhoto,
                  onClear: () => setState(() => _photoBase64 = null),
                ),

                // ── Password fields (Add only) ─────────────────────────
                if (!_isEdit) ...[
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _pwCtrl,
                          obscureText: !_showPw,
                          decoration: InputDecoration(
                            labelText: 'Password *',
                            prefixIcon: const Icon(Icons.lock_outlined),
                            suffixIcon: IconButton(
                              icon: Icon(_showPw
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined),
                              onPressed: () =>
                                  setState(() => _showPw = !_showPw),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return 'Password is required';
                            }
                            if (v.length < 6) return 'Minimum 6 characters';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _confirmCtrl,
                          obscureText: !_showConfirm,
                          decoration: InputDecoration(
                            labelText: 'Confirm Password *',
                            prefixIcon: const Icon(Icons.lock_outlined),
                            suffixIcon: IconButton(
                              icon: Icon(_showConfirm
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined),
                              onPressed: () =>
                                  setState(() => _showConfirm = !_showConfirm),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return 'Please confirm password';
                            }
                            if (v != _pwCtrl.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _mustChange,
                    onChanged: (v) =>
                        setState(() => _mustChange = v ?? true),
                    title: const Text(
                      'Require password change on first login',
                      style: TextStyle(fontSize: 13),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    fillColor: WidgetStateProperty.all(AppColors.primary),
                  ),
                ],

                const SizedBox(height: 24),

                // ── Actions ────────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed:
                            _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                        child: const Text('Cancel')),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 130,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text(_isEdit ? 'Save Changes' : 'Add User'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Profile photo picker ──────────────────────────────────────────────────────

class _PhotoPicker extends StatelessWidget {
  final String?      photoBase64;
  final String       initials;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _PhotoPicker({
    required this.photoBase64,
    required this.initials,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoBase64 != null && photoBase64!.isNotEmpty;
    return Row(
      children: [
        // Avatar preview
        CircleAvatar(
          radius: 36,
          backgroundColor: AppColors.primary.withValues(alpha: 0.12),
          backgroundImage: hasPhoto
              ? MemoryImage(const Base64Decoder().convert(photoBase64!))
              : null,
          child: !hasPhoto
              ? Text(initials,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary))
              : null,
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Profile Photo',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 2),
            const Text('Picked from gallery, stored securely.',
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.upload_outlined, size: 16),
                  label: Text(hasPhoto ? 'Change Photo' : 'Pick Photo'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
                if (hasPhoto) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Remove photo',
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: AppColors.negative),
                    onPressed: onClear,
                  ),
                ],
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ── Reset Password Dialog ─────────────────────────────────────────────────────

class _ResetPasswordDialog extends ConsumerStatefulWidget {
  final String userId;
  final String userName;

  const _ResetPasswordDialog({
    required this.userId,
    required this.userName,
  });

  @override
  ConsumerState<_ResetPasswordDialog> createState() =>
      _ResetPasswordDialogState();
}

class _ResetPasswordDialogState
    extends ConsumerState<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pwCtrl  = TextEditingController();
  bool    _showPw = false;
  bool    _saving = false;
  String? _error;

  @override
  void dispose() {
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      await DioClient.instance.post(
        '/rpc/fn_admin_set_password',
        data: {
          'p_user_id':      widget.userId,
          'p_new_password': _pwCtrl.text,
        },
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password reset. User must change it on next login.'),
            backgroundColor: AppColors.positive,
          ),
        );
      }
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] as String?
          ?? 'Reset failed. Please try again.';
      if (mounted) setState(() { _saving = false; _error = msg; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_reset_outlined,
                        color: AppColors.secondary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Reset Password — ${widget.userName}',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary),
                      ),
                    ),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Set a temporary password. The user will be required to change it on next login.',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 20),

                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.negative.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.negative)),
                  ),
                  const SizedBox(height: 14),
                ],

                TextFormField(
                  controller: _pwCtrl,
                  obscureText: !_showPw,
                  decoration: InputDecoration(
                    labelText: 'New Temporary Password *',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(_showPw
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showPw = !_showPw),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Password is required';
                    if (v.length < 6) return 'Minimum 6 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context, rootNavigator: true).pop(),
                        child: const Text('Cancel')),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.secondary),
                        child: _saving
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Text('Reset Password'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

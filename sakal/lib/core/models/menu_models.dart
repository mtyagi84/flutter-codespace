class MenuFeature {
  final String featureCode;
  final String featureName;
  final String screenName;
  final int serialNo;
  final bool editAllowed;
  final bool approveAllowed;
  final bool copyAllowed;
  final bool excelUploadAllowed;

  const MenuFeature({
    required this.featureCode,
    required this.featureName,
    required this.screenName,
    required this.serialNo,
    required this.editAllowed,
    required this.approveAllowed,
    required this.copyAllowed,
    required this.excelUploadAllowed,
  });

  factory MenuFeature.fromJson(Map<String, dynamic> j) => MenuFeature(
        featureCode:        j['feature_code'] as String,
        featureName:        j['feature_name'] as String,
        screenName:         j['screen_name'] as String,
        serialNo:           j['serial_no'] as int? ?? 0,
        editAllowed:        j['edit_allowed'] as bool? ?? false,
        approveAllowed:     j['approve_allowed'] as bool? ?? false,
        copyAllowed:        j['copy_allowed'] as bool? ?? false,
        excelUploadAllowed: j['excel_upload_allowed'] as bool? ?? false,
      );
}

class MenuGroup {
  final String groupCode;
  final String groupName;
  final int serialNo;
  final List<MenuFeature> features;

  const MenuGroup({
    required this.groupCode,
    required this.groupName,
    required this.serialNo,
    required this.features,
  });

  factory MenuGroup.fromJson(Map<String, dynamic> j) => MenuGroup(
        groupCode: j['group_code'] as String,
        groupName: j['group_name'] as String,
        serialNo:  j['serial_no'] as int? ?? 0,
        features:  (j['features'] as List<dynamic>? ?? [])
            .map((f) => MenuFeature.fromJson(f as Map<String, dynamic>))
            .toList(),
      );
}

class MenuModule {
  final String moduleCode;
  final String moduleName;
  final int serialNo;
  final List<MenuGroup> groups;

  const MenuModule({
    required this.moduleCode,
    required this.moduleName,
    required this.serialNo,
    required this.groups,
  });

  factory MenuModule.fromJson(Map<String, dynamic> j) => MenuModule(
        moduleCode: j['module_code'] as String,
        moduleName: j['module_name'] as String,
        serialNo:   j['serial_no'] as int? ?? 0,
        groups:     (j['groups'] as List<dynamic>? ?? [])
            .map((g) => MenuGroup.fromJson(g as Map<String, dynamic>))
            .toList(),
      );
}

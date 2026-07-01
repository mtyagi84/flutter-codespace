import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

/// Checklist of locations with one markable as default.
/// Used by the standalone User Location Access screen and the
/// Add/Edit User dialog.
class LocationAccessPicker extends StatefulWidget {
  final List<Map<String, dynamic>> locations; // {id, location_name}
  final Set<String> initialSelected;
  final String? initialDefault;
  final void Function(Set<String> selected, String? defaultId) onChanged;

  const LocationAccessPicker({
    super.key,
    required this.locations,
    required this.initialSelected,
    required this.initialDefault,
    required this.onChanged,
  });

  @override
  State<LocationAccessPicker> createState() => _LocationAccessPickerState();
}

class _LocationAccessPickerState extends State<LocationAccessPicker> {
  late Set<String> _selected;
  String? _default;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelected};
    _default  = widget.initialDefault;
  }

  @override
  void didUpdateWidget(covariant LocationAccessPicker old) {
    super.didUpdateWidget(old);
    if (old.initialSelected != widget.initialSelected || old.initialDefault != widget.initialDefault) {
      _selected = {...widget.initialSelected};
      _default  = widget.initialDefault;
    }
  }

  void _toggle(String locId, bool checked) {
    setState(() {
      if (checked) {
        _selected.add(locId);
        _default ??= locId;
      } else {
        _selected.remove(locId);
        if (_default == locId) {
          _default = _selected.isNotEmpty ? _selected.first : null;
        }
      }
    });
    widget.onChanged(_selected, _default);
  }

  void _makeDefault(String locId) {
    if (!_selected.contains(locId)) return;
    setState(() => _default = locId);
    widget.onChanged(_selected, _default);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.locations.isEmpty) {
      return const Text('No locations available.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary));
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 220),
      child: Scrollbar(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: widget.locations.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
          itemBuilder: (context, i) {
            final loc      = widget.locations[i];
            final locId    = loc['id'] as String;
            final checked  = _selected.contains(locId);
            final isDefault = _default == locId;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Checkbox(
                    value: checked,
                    onChanged: (v) => _toggle(locId, v ?? false),
                  ),
                  Expanded(
                    child: Text(loc['location_name'] as String,
                        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                  ),
                  IconButton(
                    tooltip: isDefault ? 'Default location' : 'Set as default',
                    icon: Icon(
                      isDefault ? Icons.star : Icons.star_border,
                      size: 20,
                      color: isDefault ? AppColors.secondary : AppColors.textDisabled,
                    ),
                    onPressed: checked ? () => _makeDefault(locId) : null,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

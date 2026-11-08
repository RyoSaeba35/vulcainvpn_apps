import 'dart:io';

import 'package:flutter/material.dart';

import '../colors.dart';
import '../l10n/app_localizations.dart';
import '../services/location_service.dart';

/// Flag emoji, or the country code on Windows (no flag emoji font there).
class LocationFlag extends StatelessWidget {
  final String code;
  final String flag;
  final double size;

  const LocationFlag({super.key, required this.code, required this.flag, this.size = 26});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && flag.isNotEmpty) {
      return SizedBox(
        width: size + 8,
        child: Text(flag, style: TextStyle(fontSize: size), textAlign: TextAlign.center),
      );
    }
    return Container(
      width: size + 8,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        code,
        style: TextStyle(fontSize: size * 0.45, fontWeight: FontWeight.bold, color: Colors.grey[800]),
      ),
    );
  }
}

/// Icon used for "Automatic"
class _AutoIcon extends StatelessWidget {
  static const double size = 26;
  const _AutoIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 8,
      child: Icon(Icons.bolt, color: MyColors.myOrange, size: size),
    );
  }
}

/// The tappable row on the home tab showing the current location choice.
class LocationTile extends StatelessWidget {
  final String selected;
  final String? connectedCountry;
  final bool enabled;
  final VoidCallback onTap;
  final AppLocalizations loc;

  const LocationTile({
    super.key,
    required this.selected,
    required this.connectedCountry,
    required this.enabled,
    required this.onTap,
    required this.loc,
  });

  @override
  Widget build(BuildContext context) {
    final lang = loc.locale.languageCode;
    final isAuto = selected == LocationService.automatic;
    final location = isAuto ? null : LocationService.byCode(selected);
    final connected = connectedCountry != null ? LocationService.byCode(connectedCountry!) : null;

    final title = isAuto ? loc.locationAutomatic : (location?.displayName(lang) ?? selected);
    String subtitle;
    if (isAuto && connected != null) {
      subtitle = '${loc.locationConnectedVia}: ${connected.displayName(lang)}';
    } else if (isAuto) {
      subtitle = loc.locationAutomaticDesc;
    } else {
      subtitle = loc.region(location?.region);
    }

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              isAuto
                  ? const _AutoIcon()
                  : LocationFlag(code: selected, flag: location?.flag ?? ''),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: enabled ? Colors.grey[700] : Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the picker. Returns the chosen code ("auto" or "FR"), or null if
/// dismissed. [refresh] reloads the list from the backend while it is open.
Future<String?> showLocationPicker({
  required BuildContext context,
  required AppLocalizations loc,
  required String current,
  required Future<bool> Function() refresh,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LocationPickerSheet(loc: loc, current: current, refresh: refresh),
  );
}

class _LocationPickerSheet extends StatefulWidget {
  final AppLocalizations loc;
  final String current;
  final Future<bool> Function() refresh;

  const _LocationPickerSheet({required this.loc, required this.current, required this.refresh});

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ok = await widget.refresh();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = !ok;
    });
  }

  Color _loadColor(String? load) {
    switch (load) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      default:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = widget.loc;
    final lang = loc.locale.languageCode;
    final locations = LocationService.locations;
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(loc.chooseLocationTitle,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(loc.chooseLocationSubtitle, style: TextStyle(color: Colors.grey[600])),
            ),
            if (_loading) const LinearProgressIndicator(color: MyColors.myOrange, minHeight: 2),
            if (_failed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(loc.locationListError, style: TextStyle(color: Colors.orange[800], fontSize: 13)),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  _row(
                    leading: const _AutoIcon(),
                    title: loc.locationAutomatic,
                    subtitle: loc.locationAutomaticDesc,
                    badge: loc.locationRecommended,
                    selected: widget.current == LocationService.automatic,
                    enabled: true,
                    onTap: () => Navigator.pop(context, LocationService.automatic),
                  ),
                  const Divider(height: 1),
                  for (final location in locations)
                    _row(
                      leading: LocationFlag(code: location.code, flag: location.flag),
                      title: location.displayName(lang),
                      subtitle: location.available ? loc.region(location.region) : loc.locationReason(location.reason),
                      loadColor: location.available ? _loadColor(location.load) : null,
                      selected: widget.current == location.code,
                      enabled: location.available,
                      onTap: () => Navigator.pop(context, location.code),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row({
    required Widget leading,
    required String title,
    required String subtitle,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
    String? badge,
    Color? loadColor,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: ListTile(
        enabled: enabled,
        onTap: enabled ? onTap : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
        leading: leading,
        title: Row(
          children: [
            Flexible(
              child: Text(title,
                  style: TextStyle(fontWeight: selected ? FontWeight.bold : FontWeight.w500),
                  overflow: TextOverflow.ellipsis),
            ),
            if (badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: MyColors.myOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(badge,
                    style: const TextStyle(fontSize: 11, color: MyColors.myOrange, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: selected
            ? const Icon(Icons.check_circle, color: MyColors.myOrange)
            : (loadColor != null
                ? Container(width: 10, height: 10, decoration: BoxDecoration(color: loadColor, shape: BoxShape.circle))
                : null),
      ),
    );
  }
}

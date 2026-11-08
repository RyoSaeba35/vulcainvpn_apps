import 'package:flutter/material.dart';
import 'dart:io';
import '../../colors.dart';
import '../../l10n/app_localizations.dart';
import '../../services/location_service.dart';
import '../../widgets/location_picker.dart';
import '../../widgets/world_map_view.dart';

class HomeTab extends StatelessWidget {
  final String connectionState;
  final int connectionSeconds;
  final String currentIp;
  final String currentCountry;
  final String currentCountryCode;
  final bool isLoadingIp;
  final VoidCallback onToggleConnection;
  final String selectedLocation;
  final String? connectedCountry;
  final VoidCallback onChangeLocation;
  final AppLocalizations loc;

  const HomeTab({
    super.key,
    required this.connectionState,
    required this.connectionSeconds,
    required this.currentIp,
    required this.currentCountry,
    required this.currentCountryCode,
    required this.isLoadingIp,
    required this.onToggleConnection,
    required this.selectedLocation,
    required this.connectedCountry,
    required this.onChangeLocation,
    required this.loc,
  });

  String _getFlag(String countryCode) {
    if (countryCode.isEmpty) return '';
    return String.fromCharCodes(
      Runes(countryCode.toUpperCase().replaceAllMapped(
        RegExp(r'[A-Z]'),
        (match) => String.fromCharCode(
          match.group(0)!.codeUnitAt(0) + 127397,
        ),
      )),
    );
  }

  String _formatTime(int seconds) {
    int hours = seconds ~/ 3600;
    int minutes = (seconds % 3600) ~/ 60;
    int secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  bool get connectedState => connectionState == 'connected';

  /// Country shown on the map: the server's country once known, else the
  /// country chosen in the picker (null for Automatic before connecting)
  String? get mapCountry {
    final chosen = selectedLocation == LocationService.automatic ? null : selectedLocation;
    if (connectionState == 'disconnected') return null;
    return connectedCountry ?? chosen;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ─── TOP SECTION: World map (Flexible) ─────────────────────────
        Expanded(
          flex: 3, // Takes 3 parts of available space
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: WorldMapView(
                connectionState: connectionState,
                countryCode: mapCountry,
              ),
            ),
          ),
        ),

        // ─── MIDDLE SECTION: Information (Flexible) ────────────────────
        Expanded(
          flex: 2, // Takes 2 parts of available space
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    connectionState == 'connected'
                        ? loc.connected
                        : connectionState == 'connecting'
                            ? loc.connecting
                            : loc.disconnected,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 15),

                  // ✅ IP Line
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${loc.ip}: ',
                        style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                      ),
                      if (isLoadingIp && connectionState == 'disconnected')
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Flexible(
                          child: Text(
                            currentIp,
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[700],
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // ✅ Second Line: Country (when disconnected) OR Duration (when connected)
                  if (connectionState == 'connected')
                    // Show Duration when connected
                    Text(
                      '${loc.duration}: ${_formatTime(connectionSeconds)}',
                      style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                    )
                  else
                    // Show Country when disconnected
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${loc.country}: ',
                          style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                        ),
                        if (!isLoadingIp && currentCountry.isNotEmpty)
                          Flexible(
                            child: Text(
                              '$currentCountry${Platform.isWindows ? '' : ' ${_getFlag(currentCountryCode)}'}',
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey[700],
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),

                  if (connectionState == 'connected')
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        loc.secureConnection,
                        style: TextStyle(fontSize: 16, color: Colors.green[700]),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // ─── LOCATION PICKER ───────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 12, 40, 0),
          child: LocationTile(
            selected: selectedLocation,
            connectedCountry: connectedState ? connectedCountry : null,
            enabled: connectionState == 'connected' || connectionState == 'disconnected',
            onTap: onChangeLocation,
            loc: loc,
          ),
        ),

        // ─── BOTTOM SECTION: Button (Fixed Height) ─────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 20, 40, 40),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (connectionState == 'connecting' || connectionState == 'disconnecting')
                  ? null
                  : onToggleConnection,
              style: ElevatedButton.styleFrom(
                backgroundColor: connectionState == 'connected'
                    ? Colors.red
                    : MyColors.myOrange,
                disabledBackgroundColor: Colors.grey,
                padding: const EdgeInsets.symmetric(
                  horizontal: 60,
                  vertical: 22,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                elevation: 5,
              ),
              child: Text(
                connectionState == 'connected'
                    ? loc.disconnect
                    : connectionState == 'connecting'
                        ? loc.connectingBtn
                        : connectionState == 'disconnecting'
                            ? loc.disconnectingBtn
                            : loc.connect,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

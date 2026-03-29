import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:io';
import '../../colors.dart';
import '../../l10n/app_localizations.dart';

class HomeTab extends StatelessWidget {
  final String connectionState;
  final int connectionSeconds;
  final String currentIp;
  final String currentCountry;
  final String currentCountryCode;
  final bool isLoadingIp;
  final VoidCallback onToggleConnection;
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ─── TOP SECTION: SVG (Flexible) ───────────────────────────────
        Expanded(
          flex: 3, // Takes 3 parts of available space
          child: Center(
            child: SvgPicture.asset(
              connectionState == 'connected'
                  ? 'assets/icons/connected.svg'
                  : 'assets/icons/disconnected.svg',
              height: 200, // Fixed reasonable height instead of percentage
              colorFilter: connectionState == 'connecting'
                  ? const ColorFilter.mode(
                      MyColors.myOrange,
                      BlendMode.srcIn,
                    )
                  : null,
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          '${loc.location}: $currentCountry${Platform.isWindows ? '' : ' ${_getFlag(currentCountryCode)}'} ',
                          style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (isLoadingIp)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Flexible(
                          child: Text(
                            '($currentIp)',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[700],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (connectionState == 'connected')
                    Padding(
                      padding: const EdgeInsets.only(top: 15),
                      child: Text(
                        '${loc.duration}: ${_formatTime(connectionSeconds)}',
                        style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                      ),
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

        // ─── BOTTOM SECTION: Button (Fixed Height) ─────────────────────
        Padding(
          padding: const EdgeInsets.all(40),
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

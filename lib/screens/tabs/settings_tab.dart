import 'package:flutter/material.dart';
import '../../main.dart';
import '../../colors.dart';
import '../../l10n/app_localizations.dart';
import '../../services/auth_service.dart';
import '../../services/vpn_service.dart';
import '../../widgets/info_card.dart';
import '../../widgets/info_row.dart';
import '../../services/vpn_config_service.dart';

class SettingsTab extends StatelessWidget {
  final VoidCallback onLogout;
  final VpnService vpnService;
  final String connectionState;
  final AppLocalizations loc;

  const SettingsTab({
    super.key,
    required this.onLogout,
    required this.vpnService,
    required this.connectionState,
    required this.loc,
  });

  void _showLanguageDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final loc = AppLocalizations.of(context)!;
        return AlertDialog(
          title: Text(loc.language),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(loc.english),
                leading: const Text('🇬🇧', style: TextStyle(fontSize: 24)),
                onTap: () {
                  MyApp.setLocale(context, const Locale('en'));
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: Text(loc.french),
                leading: const Text('🇫🇷', style: TextStyle(fontSize: 24)),
                onTap: () {
                  MyApp.setLocale(context, const Locale('fr'));
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showDebugInfo(BuildContext context) async {
    final loc = AppLocalizations.of(context)!;

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final email = await AuthService.getStoredEmail();
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      // Close loading
      if (context.mounted) Navigator.pop(context);

      // Show debug info
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.bug_report, color: Colors.blue),
                const SizedBox(width: 8),
                Text(loc.debugInfo),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${loc.email}: ${email ?? loc.notLoggedIn}'),
                  const SizedBox(height: 8),
                  Text('${loc.deviceId}: ${deviceId ?? loc.notRegistered}'),
                  const SizedBox(height: 8),
                  Text('${loc.apiKey}: ${apiKey != null ? apiKey.substring(0, 16) : loc.missing}...'),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    loc.lastVpnConfig,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  // ⭐ Show last config data
                  Text(
                    VpnConfigService.lastDebugInfo.isEmpty
                      ? loc.noConfigYet
                      : VpnConfigService.lastDebugInfo,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (VpnConfigService.lastFullConfig.isNotEmpty)
                TextButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(loc.fullConfig),
                        content: SingleChildScrollView(
                          child: SelectableText(
                            VpnConfigService.lastFullConfig,
                            style: const TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(loc.close),
                          ),
                        ],
                      ),
                    );
                  },
                  child: Text(loc.viewFullConfig),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(loc.close),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) Navigator.pop(context);
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(loc.error),
            content: Text('${loc.failedLoadDebug}\n$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(loc.ok),
              ),
            ],
          ),
        );
      }
    }
  }

  void _showLogoutDialog(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.logout),
        content: Text(loc.logoutConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              if (connectionState == 'connected') {
                await vpnService.stopVpn();
              }
              onLogout();
            },
            child: Text(
              loc.logout,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        InfoCard(
          title: loc.account,
          icon: Icons.person_outline,
          children: [
            FutureBuilder<String?>(
              future: AuthService.getStoredEmail(),
              builder: (context, snapshot) {
                return InfoRow(
                  label: loc.email,
                  value: snapshot.data ?? '—',
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        InfoCard(
          title: loc.preferences,
          icon: Icons.tune_outlined,
          children: [
            InkWell(
              onTap: () => _showLanguageDialog(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      loc.language,
                      style:
                          TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    Row(
                      children: [
                        Text(
                          Localizations.localeOf(context).languageCode == 'fr'
                              ? '🇫🇷 ${loc.french}'
                              : '🇬🇧 ${loc.english}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, color: Colors.grey[400]),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // ⭐ Debug section
        InfoCard(
          title: loc.debug,
          icon: Icons.bug_report,
          children: [
            InkWell(
              onTap: () => _showDebugInfo(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      loc.debugInfo,
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    Row(
                      children: [
                        Text(
                          loc.show,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, color: Colors.grey[400]),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton.icon(
            onPressed: () => _showLogoutDialog(context),
            icon: const Icon(Icons.logout, color: Colors.red),
            label: Text(
              loc.logout,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.red),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

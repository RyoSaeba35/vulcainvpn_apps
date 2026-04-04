import 'package:flutter/material.dart';
import '../../main.dart';
import '../../colors.dart';
import '../../l10n/app_localizations.dart';
import '../../services/auth_service.dart';
import '../../services/vpn_service.dart';
import '../../services/settings_service.dart'; // ✅ NEW
import '../../widgets/info_card.dart';
import '../../widgets/info_row.dart';

class SettingsTab extends StatefulWidget {
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

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  // ✅ NEW: Auto-reconnect state
  bool _autoReconnectEnabled = true;
  bool _isLoadingSettings = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // ✅ NEW: Load settings from storage
  Future<void> _loadSettings() async {
    final autoReconnect = await SettingsService.getAutoReconnect();
    if (mounted) {
      setState(() {
        _autoReconnectEnabled = autoReconnect;
        _isLoadingSettings = false;
      });
    }
  }

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
              if (widget.connectionState == 'connected') {
                await widget.vpnService.stopVpn();
              }
              widget.onLogout();
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
            // Language selector
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
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
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

            const Divider(height: 24),

            // ✅ NEW: Auto-reconnect toggle
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Row(
                children: [
                  Icon(
                    Icons.sync,
                    size: 20,
                    color: Colors.grey[700],
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Auto-Reconnect',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[800],
                    ),
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(left: 32, top: 4),
                child: Text(
                  'Automatically reconnect if VPN connection is lost',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                  ),
                ),
              ),
              value: _autoReconnectEnabled,
              activeColor: MyColors.myOrange,
              onChanged: _isLoadingSettings
                  ? null // Disable while loading
                  : (bool value) async {
                      setState(() => _autoReconnectEnabled = value);
                      await SettingsService.setAutoReconnect(value);

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                Icon(
                                  value ? Icons.check_circle : Icons.info,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  value
                                      ? 'Auto-reconnect enabled'
                                      : 'Auto-reconnect disabled',
                                ),
                              ],
                            ),
                            backgroundColor: value ? Colors.green : Colors.grey[700],
                            duration: const Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
            ),
          ],
        ),

        const SizedBox(height: 32),

        // Logout button
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

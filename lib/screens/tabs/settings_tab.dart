import 'package:flutter/material.dart';
import '../../main.dart';
import '../../colors.dart';
import '../../l10n/app_localizations.dart';
import '../../services/auth_service.dart';
import '../../services/vpn_service.dart';
import '../../services/settings_service.dart';
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
  bool _autoReconnectEnabled = true;
  ConnectionMode _connectionMode = ConnectionMode.balanced;
  bool _isLoadingSettings = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final autoReconnect = await SettingsService.getAutoReconnect();
    final connectionMode = await SettingsService.getConnectionMode();
    if (mounted) {
      setState(() {
        _autoReconnectEnabled = autoReconnect;
        _connectionMode = connectionMode;
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

  void _showConnectionModeDialog(BuildContext context) {
    final loc = AppLocalizations.of(context)!; // ✅ Add this

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(loc.connectionMode),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildModeOption(
                mode: ConnectionMode.standard,
                title: loc.modeStandard,
                subtitle: loc.modeStandardDesc,
                emoji: '⚡',
              ),
              const Divider(height: 20),
              _buildModeOption(
                mode: ConnectionMode.stealth,
                title: loc.modeStealth,
                subtitle: loc.modeStealthDesc,
                emoji: '🕵️',
              ),
              const Divider(height: 20),
              _buildModeOption(
                mode: ConnectionMode.balanced,
                title: loc.modeBalanced,
                subtitle: loc.modeBalancedDesc,
                emoji: '⚖️',
              ),
            ],
          ),
        );
      },
    );
  }

  // ✅ NEW: Build mode option widget
  Widget _buildModeOption({
    required ConnectionMode mode,
    required String title,
    required String subtitle,
    required String emoji,
  }) {
    final isSelected = _connectionMode == mode;
    final loc = AppLocalizations.of(context)!; // ✅ Add this

    return InkWell(
      onTap: () async {
        setState(() => _connectionMode = mode);
        await SettingsService.setConnectionMode(mode);
        Navigator.pop(context);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${loc.connectionMode}: $title'),
                        const SizedBox(height: 2),
                        Text(
                          loc.modeReconnectHint,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              backgroundColor: MyColors.myOrange,
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 32)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: MyColors.myOrange, size: 24),
          ],
        ),
      ),
    );
  }

  // ✅ NEW: Get readable mode name
  String _getModeName(ConnectionMode mode) {
    final loc = widget.loc; // ✅ Use widget.loc since we have it

    switch (mode) {
      case ConnectionMode.standard:
        return loc.modeStandardFull;
      case ConnectionMode.stealth:
        return loc.modeStealthFull;
      case ConnectionMode.balanced:
        return loc.modeBalancedFull;
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

            // ✅ NEW: Connection Mode selector
            InkWell(
              onTap: _isLoadingSettings ? null : () => _showConnectionModeDialog(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.swap_horiz, size: 20, color: Colors.grey[700]),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc.connectionMode, // ✅ Changed
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _getModeName(_connectionMode),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Icon(Icons.chevron_right, color: Colors.grey[400]),
                  ],
                ),
              ),
            ),
            const Divider(height: 24),

            // Auto-reconnect toggle
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
                    loc.autoReconnect, // ✅ Changed
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
                  loc.autoReconnectDesc, // ✅ Changed
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                  ),
                ),
              ),
              value: _autoReconnectEnabled,
              activeColor: MyColors.myOrange,
              onChanged: _isLoadingSettings
                  ? null
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
                                      ? loc.autoReconnectEnabled // ✅ Changed
                                      : loc.autoReconnectDisabled, // ✅ Changed
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

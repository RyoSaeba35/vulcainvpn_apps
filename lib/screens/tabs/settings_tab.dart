import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/auth_strings.dart';
import '../../main.dart';
import '../../colors.dart';
import '../../l10n/app_localizations.dart';
import '../../services/auth_service.dart';
import '../delete_account_screen.dart';
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

  // ── Diagnostic report state ───────────────────────────────────────────────
  bool _isSendingReport = false;
  int _logSizeKB = 0;
  static const int _maxMessageLength = 300;
  static final MethodChannel _platform = MethodChannel(
    Platform.isIOS ? 'com.vulcain.vpn/ios_control' : 'com.vulcain.vpn/control',
  );

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final autoReconnect = await SettingsService.getAutoReconnect();
    final connectionMode = await SettingsService.getConnectionMode();

    int logSize = 0;
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final raw = await _platform.invokeMethod('getLogSizeKB');
        logSize = (raw as num).toInt();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _autoReconnectEnabled = autoReconnect;
        _connectionMode = connectionMode;
        _logSizeKB = logSize;
        _isLoadingSettings = false;
      });
    }
  }

  // ── Message sanitization ──────────────────────────────────────────────────
  // Strips control characters, HTML/script tags, code-injection chars.
  // Only keeps printable text: letters, digits, punctuation, spaces.
  String _sanitizeMessage(String raw) {
    // Remove control characters (0x00–0x1F, 0x7F)
    var s = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    // Strip anything that could be interpreted as markup or code
    s = s.replaceAll(RegExp(r'[<>{}\[\]\\`]'), '');
    // Collapse runs of whitespace to a single space, trim edges
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Hard cap — should never exceed since TextField enforces it, but just in case
    if (s.length > _maxMessageLength) s = s.substring(0, _maxMessageLength);
    return s;
  }

  // ── Report dialog ─────────────────────────────────────────────────────────
  Future<void> _showReportDialog() async {
    final controller = TextEditingController();
    // Local char count to rebuild only the counter without a StatefulBuilder
    // wrapping the whole dialog — keep it simple with StatefulBuilder.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final remaining = _maxMessageLength - controller.text.length;
            return AlertDialog(
              title: const Text('Send Diagnostic Report'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Describe what happened (optional):',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    maxLines: 4,
                    maxLength: _maxMessageLength,
                    // Hide the default counter — we draw our own below
                    buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
                        null,
                    decoration: InputDecoration(
                      hintText: 'e.g. VPN disconnected after ~30s on mobile data…',
                      border: const OutlineInputBorder(),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: MyColors.myOrange),
                      ),
                    ),
                    // Block characters that serve no purpose in a bug description
                    // and could be used for injection
                    inputFormatters: [
                      FilteringTextInputFormatter.deny(
                        RegExp(r'[<>{}\[\]\\`\x00-\x1F\x7F]'),
                      ),
                    ],
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Technical logs attached automatically.',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                      Text(
                        '$remaining left',
                        style: TextStyle(
                          fontSize: 11,
                          color: remaining <= 30 ? Colors.orange : Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text(
                    'Send',
                    style: TextStyle(color: MyColors.myOrange),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && mounted) {
      final message = _sanitizeMessage(controller.text);
      await _sendDiagnosticReport(message: message);
    }
    controller.dispose();
  }

  // ── Diagnostic report ─────────────────────────────────────────────────────
  Future<void> _sendDiagnosticReport({String message = ''}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    if (_isSendingReport) return;
    setState(() => _isSendingReport = true);

    try {
      final token = await AuthService.getValidAccessToken();
      if (token == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please log in again before sending a report.'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      final result = await _platform.invokeMethod('sendDiagnosticReport', {
        'access_token': token,
        'device': '${Platform.operatingSystem} device',
        'os_version': Platform.operatingSystemVersion,
        'app_version': '1.1.1',
        'message': message,
      });

      if (!mounted) return;

      if (result == 'sent') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Diagnostic report sent. Thank you!'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (result == 'debounced') {
        // Silent — already sending
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send report ($result). Please try again.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending report: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSendingReport = false);
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
    final loc = AppLocalizations.of(context)!;

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

  Widget _buildModeOption({
    required ConnectionMode mode,
    required String title,
    required String subtitle,
    required String emoji,
  }) {
    final isSelected = _connectionMode == mode;
    final loc = AppLocalizations.of(context)!;

    return InkWell(
      onTap: () async {
        setState(() => _connectionMode = mode);
        await SettingsService.setConnectionMode(mode);
        if (!mounted) return;
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

  String _getModeName(ConnectionMode mode) {
    final loc = widget.loc;

    switch (mode) {
      case ConnectionMode.standard:
        return loc.modeStandardFull;
      case ConnectionMode.stealth:
        return loc.modeStealthFull;
      case ConnectionMode.balanced:
        return loc.modeBalancedFull;
    }
  }

  Future<void> _clearLogs() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Diagnostic Logs'),
        content: const Text(
            'This will permanently delete all diagnostic logs stored on this device. Are you sure?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _platform.invokeMethod('clearLogs');
        if (mounted) {
          setState(() => _logSizeKB = 0);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Diagnostic logs cleared.'),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to clear logs: $e'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  // ── Legal links ───────────────────────────────────────────────────────────

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open link: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ── Support the app ───────────────────────────────────────────────────────
  static const String _packageName = 'com.vulcainvpn.app';
  static const String _playUrl = 'https://play.google.com/store/apps/details?id=$_packageName';
  static const String _siteUrl = 'https://www.vulcainvpn.com';

  /// Opens the app's page in the Play Store app (review section), or the
  /// Play website if the Store app is missing.
  Future<void> _openReview() async {
    final s = AuthStrings.of(context);
    try {
      final opened = await launchUrl(
        Uri.parse('market://details?id=$_packageName&showAllReviews=true'),
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;
    } catch (_) {}
    try {
      await launchUrl(Uri.parse(_playUrl), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.couldNotOpenStore), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _shareApp(BuildContext buttonContext) async {
    final s = AuthStrings.of(context);
    // iPad / desktop need an anchor for the share popup
    final box = buttonContext.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: s.shareMessage(_playUrl, _siteUrl),
        subject: s.shareSubject,
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Widget _buildSupportRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required void Function(BuildContext rowContext) onTap,
  }) {
    return Builder(
      builder: (rowContext) => InkWell(
        onTap: () => onTap(rowContext),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: MyColors.myOrange, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  void _openLicences(BuildContext context) {
    showLicensePage(
      context: context,
      applicationName: 'Vulcain VPN',
      applicationVersion: '1.1.1',
      applicationIcon: Padding(
        padding: const EdgeInsets.all(8),
        child: Image.asset('assets/icons/icon.png', width: 48, height: 48),
      ),
    );
  }

  Widget _buildLegalRow(String label, String url) {
    return InkWell(
      onTap: () => _launchUrl(url),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            Icon(Icons.open_in_new, size: 16, color: Colors.grey[500]),
          ],
        ),
      ),
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

  // Google Play requires in-app account deletion for apps with sign up
  Future<void> _openDeleteAccount() async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
    );

    if (deleted == true) {
      if (widget.connectionState == 'connected') {
        await widget.vpnService.stopVpn();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your account has been deleted.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      widget.onLogout(); // Clears local tokens and returns to the login screen
    }
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

            // Connection Mode selector
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
                              loc.connectionMode,
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
                    loc.autoReconnect,
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
                  loc.autoReconnectDesc,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                  ),
                ),
              ),
              value: _autoReconnectEnabled,
              activeThumbColor: MyColors.myOrange,
              onChanged: _isLoadingSettings
                  ? null
                  : (bool value) async {
                      setState(() => _autoReconnectEnabled = value);
                      await SettingsService.setAutoReconnect(value);

                      if (context.mounted) {
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
                                      ? loc.autoReconnectEnabled
                                      : loc.autoReconnectDisabled,
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

        // ── Support the app ───────────────────────────────────────────────
        InfoCard(
          title: AuthStrings.of(context).supportTheApp,
          icon: Icons.favorite_border,
          children: [
            // Reviews only make sense where the app is on Google Play
            if (Platform.isAndroid) ...[
              _buildSupportRow(
                icon: Icons.star_outline,
                title: AuthStrings.of(context).leaveReview,
                subtitle: AuthStrings.of(context).leaveReviewDesc,
                onTap: (_) => _openReview(),
              ),
              const Divider(height: 1),
            ],
            _buildSupportRow(
              icon: Icons.share_outlined,
              title: AuthStrings.of(context).shareApp,
              subtitle: AuthStrings.of(context).shareAppDesc,
              onTap: _shareApp,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                AuthStrings.of(context).supportThanks,
                style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.4),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Support & Diagnostics ─────────────────────────────────────────
        if (Platform.isAndroid || Platform.isIOS)
          InfoCard(
            title: 'Support & Diagnostics',
            icon: Icons.bug_report_outlined,
            children: [
              InfoRow(
                label: 'Diagnostic log size',
                value: _logSizeKB > 0 ? '$_logSizeKB KB' : 'Empty',
              ),
              const SizedBox(height: 12),

              // Send report button — opens dialog first
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isSendingReport ? null : _showReportDialog,
                  icon: _isSendingReport
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: MyColors.myOrange,
                          ),
                        )
                      : const Icon(Icons.email_outlined, color: MyColors.myOrange),
                  label: Text(
                    _isSendingReport ? 'Sending report...' : 'Send Diagnostic Report',
                    style: const TextStyle(color: MyColors.myOrange),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: MyColors.myOrange),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Clear logs button
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: _logSizeKB == 0 ? null : _clearLogs,
                  icon: Icon(
                    Icons.delete_outline,
                    color: _logSizeKB == 0 ? Colors.grey : Colors.red[400],
                    size: 18,
                  ),
                  label: Text(
                    'Clear Diagnostic Logs',
                    style: TextStyle(
                      color: _logSizeKB == 0 ? Colors.grey : Colors.red[400],
                      fontSize: 13,
                    ),
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Diagnostic reports are sent directly and securely to our support team. '
                  'Only technical logs are included — no personal data beyond your account email.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),

        if (Platform.isAndroid || Platform.isIOS) const SizedBox(height: 16),

        // ── Legal ─────────────────────────────────────────────────────────
        InfoCard(
          title: 'Legal',
          icon: Icons.gavel_outlined,
          children: [
            _buildLegalRow('Privacy Policy', 'https://www.vulcainvpn.com/privacy'),
            const Divider(height: 1),
            _buildLegalRow('Terms of Service', 'https://www.vulcainvpn.com/terms'),
            const Divider(height: 1),
            _buildLegalRow('Logging Policy', 'https://www.vulcainvpn.com/logging'),
            const Divider(height: 1),
            _buildLegalRow('Legal Notice', 'https://www.vulcainvpn.com/mentions-legales'),
            const Divider(height: 1),
            // GPL-3.0: the app's source code is public
            _buildLegalRow('Source Code (GPL-3.0)', 'https://github.com/RyoSaeba35/vulcainvpn_apps'),
            const Divider(height: 1),
            InkWell(
              onTap: () => _openLicences(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Open Source Licences',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    Icon(Icons.chevron_right, color: Colors.grey[400]),
                  ],
                ),
              ),
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

        const SizedBox(height: 12),

        // Delete account
        Center(
          child: TextButton(
            onPressed: _openDeleteAccount,
            child: Text(
              'Delete account',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

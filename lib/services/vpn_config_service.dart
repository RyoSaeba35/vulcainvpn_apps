import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'settings_service.dart';

class VpnConfigService {
  static String lastDebugInfo = '';
  static String lastFullConfig = '';

  // ✅ FIXED: Make async to get connection mode
  static Future<Map<String, dynamic>> buildConfig({
    required Map<String, dynamic> wireguard,
    required Map<String, dynamic>? hysteria2,
    required Map<String, dynamic>? shadowsocks,
  }) async {
    // ✅ Get connection mode from settings
    final mode = await SettingsService.getConnectionMode();

    if (kDebugMode) {
      StringBuffer debug = StringBuffer();
      debug.writeln('🔧 Building config with mode: ${mode.name}');
      debug.writeln('📦 WireGuard:');
      wireguard.forEach((key, value) {
        debug.writeln('  $key: [REDACTED]');
      });
      debug.writeln('\n📦 Shadowsocks: ${shadowsocks != null ? "YES" : "NO"}');
      debug.writeln('📦 Hysteria2: ${hysteria2 != null ? "YES" : "NO"}');

      lastDebugInfo = debug.toString();

      print('🔧 Building config...');
      print(lastDebugInfo);
    }

    // ✅ Pass mode to config builders
    final config = Platform.isWindows || Platform.isMacOS || Platform.isLinux
        ? _buildDesktopConfig(wireguard, hysteria2, shadowsocks, mode)
        : _buildMobileConfig(wireguard, hysteria2, shadowsocks, mode);

    if (kDebugMode) {
      try {
        final configJson = toJsonString(config);
        lastFullConfig = _redactCredentialsFromJson(configJson);
      } catch (e) {
        lastFullConfig = 'Error creating redacted config: $e';
      }
    }

    return config;
  }

  static String _redactCredentialsFromJson(String jsonString) {
    final sensitiveFields = [
      'private_key',
      'public_key',
      'pre_shared_key',
      'peer_public_key',
      'password',
    ];

    String redacted = jsonString;
    for (var field in sensitiveFields) {
      final regex = RegExp('"$field"\\s*:\\s*"[^"]*"');
      redacted = redacted.replaceAll(regex, '"$field": "[REDACTED]"');
    }

    return redacted;
  }

  // ✅ UPDATED: Add mode parameter
  static Map<String, dynamic> _buildDesktopConfig(
    Map<String, dynamic> wg,
    Map<String, dynamic>? hy2,
    Map<String, dynamic>? ss,
    ConnectionMode mode,
  ) {
    return {
      "log": {"level": "error", "timestamp": true},
      "dns": {
        "servers": [
          {"type": "udp", "tag": "dns-direct", "server": "223.5.5.5"},
          {
            "type": "https",
            "tag": "dns-proxy",
            "server": "1.1.1.1",
            "path": "/dns-query",
            "detour": "proxy"
          }
        ],
        "rules": [
          {"clash_mode": "direct", "server": "dns-direct"},
          {"clash_mode": "global", "server": "dns-proxy"}
        ],
        "final": "dns-proxy",
        "strategy": "prefer_ipv4",
        "disable_cache": false,
        "disable_expire": false,
        "independent_cache": true
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "interface_name": "Vulcain VPN",
          "address": ["172.19.0.1/30"],
          "mtu": 1420,
          "auto_route": true,
          "strict_route": true,
          "stack": "mixed",
          "sniff": true,
          "sniff_override_destination": true
        }
      ],
      "endpoints": [
        {
          "type": "wireguard",
          "tag": "wireguard_1",
          "address": ["${wg['client_ip']}/32"],
          "private_key": wg['client_private_key'],
          "mtu": 1420,
          "peers": [
            {
              "address": wg['server_ip'],
              "port": int.parse(wg['server_port'].toString()),
              "public_key": wg['server_public_key'],
              "pre_shared_key": wg['client_preshared_key'],
              "allowed_ips": ["0.0.0.0/0", "::/0"]
            }
          ]
        }
      ],
      "outbounds": [
        {
          "type": "selector",
          "tag": "proxy",
          "outbounds": _buildSelectorOutbounds(hy2, ss, mode), // ✅ Pass mode
          "default": "auto"
        },
        {
          "type": "urltest",
          "tag": "auto",
          "outbounds": _buildAutoOutbounds(hy2, ss, mode), // ✅ Pass mode
          "url": "https://www.gstatic.com/generate_204",
          "interval": "10m",
          "tolerance": 50
        },
        if (ss != null) {
          "type": "shadowsocks",
          "tag": "ss-out",
          "server": ss['server'],
          "server_port": int.parse(ss['port'].toString()),
          "method": ss['method'],
          "password": ss['password'],
          "multiplex": {
            "enabled": true,
            "protocol": "h2mux",
            "max_connections": 4,
            "min_streams": 4,
            "padding": true
          },
          "tcp_fast_open": true
        },
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          "type": "hysteria2",
          "tag": "hysteria2",
          "server": hy2['server'],
          "server_port": int.parse(hy2['port'].toString()),
          "password": hy2['password'],
          "tls": {
            "enabled": true,
            "server_name": hy2['tls_server_name']?.toString().isNotEmpty == true
                ? hy2['tls_server_name']
                : "www.cloudflare.com",
            "alpn": ["h3"],
            "insecure": true
          },
          "up_mbps": 100,
          "down_mbps": 100,
          "obfs": {
            "type": hy2['obfs_type'],
            "password": hy2['obfs_password']
          }
        },
        {"type": "direct", "tag": "direct"}
      ],
      "route": {
        "default_domain_resolver": "dns-direct",
        "rules": [
          {"protocol": "dns", "action": "hijack-dns"},
          {"ip_is_private": true, "action": "route", "outbound": "direct"}
        ],
        "auto_detect_interface": true,
        "final": "proxy"
      },
      "experimental": {
        "cache_file": {
          "enabled": true,
          "path": "cache.db",
          "store_fakeip": true
        },
        "clash_api": {
          "external_controller": "127.0.0.1:9090",
          "secret": "",
          "default_mode": "rule"
        }
      }
    };
  }

  // ✅ UPDATED: Add mode parameter
  static Map<String, dynamic> _buildMobileConfig(
    Map<String, dynamic> wg,
    Map<String, dynamic>? hy2,
    Map<String, dynamic>? ss,
    ConnectionMode mode,
  ) {
    return {
      "log": {"level": "error", "timestamp": true},
      "dns": {
        "servers": [
          {"tag": "dns-direct", "address": "223.5.5.5", "detour": "direct"},
          {"tag": "dns-proxy", "address": "https://1.1.1.1/dns-query", "detour": "proxy"},
          {"tag": "dns-block", "address": "rcode://success"}
        ],
        "rules": [
          {"outbound": "any", "server": "dns-direct"},
          {"clash_mode": "direct", "server": "dns-direct"},
          {"clash_mode": "global", "server": "dns-proxy"}
        ],
        "final": "dns-proxy",
        "strategy": "prefer_ipv4",
        "disable_cache": false,
        "disable_expire": false,
        "independent_cache": true
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "interface_name": "tun0",
          "inet4_address": "172.19.0.1/30",
          "mtu": 1420,
          "auto_route": true,
          "strict_route": true,
          "stack": "mixed",
          "sniff": true,
          "sniff_override_destination": true
        }
      ],
      "outbounds": [
        {
          "type": "selector",
          "tag": "proxy",
          "outbounds": _buildSelectorOutbounds(hy2, ss, mode), // ✅ Pass mode
          "default": "auto"
        },
        {
          "type": "urltest",
          "tag": "auto",
          "outbounds": _buildAutoOutbounds(hy2, ss, mode), // ✅ Pass mode
          "url": "https://www.gstatic.com/generate_204",
          "interval": "10m",
          "tolerance": 50
        },
        {
          "type": "wireguard",
          "tag": "wireguard_1",
          "server": wg['server_ip'].toString(),
          "server_port": int.parse(wg['server_port'].toString()),
          "system_interface": false,
          "interface_name": "wg0",
          "local_address": ["${wg['client_ip']}/32"],
          "private_key": wg['client_private_key'].toString(),
          "peer_public_key": wg['server_public_key'].toString(),
          "pre_shared_key": wg['client_preshared_key'].toString(),
          "mtu": 1420,
        },
        if (ss != null) {
          "type": "shadowsocks",
          "tag": "ss-out",
          "server": ss['server'].toString(),
          "server_port": int.parse(ss['port'].toString()),
          "method": ss['method'].toString(),
          "password": ss['password'].toString(),
          "multiplex": {
            "enabled": true,
            "protocol": "h2mux",
            "max_connections": 4,
            "min_streams": 4,
            "padding": true
          },
          "tcp_fast_open": true
        },
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          "type": "hysteria2",
          "tag": "hysteria2",
          "server": hy2['server'].toString(),
          "server_port": int.parse(hy2['port'].toString()),
          "password": hy2['password'].toString(),
          "tls": {
            "enabled": true,
            "server_name": "www.cloudflare.com",
            "alpn": ["h3"],
            "insecure": true
          },
          "up_mbps": 100,
          "down_mbps": 100,
          "obfs": {
            "type": hy2['obfs_type'].toString(),
            "password": hy2['obfs_password'].toString()
          }
        },
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
        {"type": "dns", "tag": "dns-out"}
      ],
      "route": {
        "rules": [
          {"protocol": "dns", "outbound": "dns-out"},
          {"ip_is_private": true, "outbound": "direct"}
        ],
        "auto_detect_interface": true,
        "final": "proxy"
      },
      "experimental": {
        "cache_file": {
          "enabled": true,
          "path": "cache.db",
          "store_fakeip": true
        },
        "clash_api": {
          "external_controller": "127.0.0.1:9090",
          "secret": "",
          "default_mode": "rule"
        }
      }
    };
  }

  // ✅ UPDATED: Add ss and mode parameters
  static List<String> _buildSelectorOutbounds(
    Map<String, dynamic>? hy2,
    Map<String, dynamic>? ss,
    ConnectionMode mode,
  ) {
    final outbounds = ["auto"];

    // Add individual protocols for manual selection based on mode
    switch (mode) {
      case ConnectionMode.stealth:
        // Stealth mode: SS and Hysteria2 only
        if (ss != null) outbounds.add("ss-out");
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          outbounds.add("hysteria2");
        }
        // NO WireGuard in stealth mode
        break;

      case ConnectionMode.standard:
      case ConnectionMode.balanced:
        // Standard/Balanced: All protocols available
        if (ss != null) outbounds.add("ss-out");
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          outbounds.add("hysteria2");
        }
        outbounds.add("wireguard_1");
        break;
    }

    outbounds.add("direct");
    return outbounds;
  }

  // ✅ UPDATED: Mode-based protocol ordering
  static List<String> _buildAutoOutbounds(
    Map<String, dynamic>? hy2,
    Map<String, dynamic>? ss,
    ConnectionMode mode,
  ) {
    final outbounds = <String>[];

    switch (mode) {
      case ConnectionMode.stealth:
        // China/restrictive - SS first (port 443), no WireGuard
        if (ss != null) {
          outbounds.add("ss-out");
        }
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          outbounds.add("hysteria2");
        }
        // NO WireGuard - will be blocked
        break;

      case ConnectionMode.standard:
        // Speed priority - WireGuard first
        outbounds.add("wireguard_1");
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          outbounds.add("hysteria2");
        }
        if (ss != null) {
          outbounds.add("ss-out");
        }
        break;

      case ConnectionMode.balanced:
        // Firewall-friendly first - SS → Hysteria2 → WireGuard
        if (ss != null) {
          outbounds.add("ss-out");
        }
        if (hy2 != null && hy2['server']?.toString().isNotEmpty == true) {
          outbounds.add("hysteria2");
        }
        outbounds.add("wireguard_1");
        break;
    }

    return outbounds;
  }

  static String toJsonString(Map<String, dynamic> config) {
    return const JsonEncoder.withIndent('  ').convert(config);
  }
}

import 'dart:convert';
import 'dart:io';

class VpnConfigService {
  // Build sing-box config dynamically from credentials
  static Map<String, dynamic> buildConfig({
    required Map<String, dynamic> wireguard,
    required Map<String, dynamic>? hysteria2,
    required Map<String, dynamic>? shadowsocks,
  }) {
    // Platform-specific config structure
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return _buildDesktopConfig(wireguard, hysteria2, shadowsocks);
    } else {
      return _buildMobileConfig(wireguard, hysteria2, shadowsocks);
    }
  }

  // DESKTOP (Windows/macOS/Linux) - Uses "endpoints" array
  static Map<String, dynamic> _buildDesktopConfig(
    Map<String, dynamic> wg,
    Map<String, dynamic>? hy2,
    Map<String, dynamic>? ss,
  ) {
    return {
      "log": {
        "level": "debug",
        "timestamp": true
      },
      "dns": {
        "servers": [
          {
            "type": "udp",
            "tag": "dns-direct",
            "server": "223.5.5.5"
          },
          {
            "type": "https",
            "tag": "dns-proxy",
            "server": "1.1.1.1",
            "path": "/dns-query",
            "detour": "proxy"
          }
        ],
        "rules": [
          {
            "clash_mode": "direct",
            "server": "dns-direct"
          },
          {
            "clash_mode": "global",
            "server": "dns-proxy"
          }
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
          "tag": "wireguard",
          "address": ["${wg['client_ip']}/32"],
          "private_key": wg['client_private_key'],
          "preshared_key": wg['client_preshared_key'],
          "mtu": 1420,
          "peers": [
            {
              "address": wg['server_ip'],
              "port": wg['server_port'],
              "public_key": wg['server_public_key'],
              "allowed_ips": ["0.0.0.0/0", "::/0"]
            }
          ]
        }
      ],
      "outbounds": [
        {
          "type": "selector",
          "tag": "proxy",
          "outbounds": _buildSelectorOutbounds(hy2),
          "default": "auto"
        },
        {
          "type": "urltest",
          "tag": "auto",
          "outbounds": _buildAutoOutbounds(hy2),
          "url": "https://www.gstatic.com/generate_204",
          "interval": "10m",
          "tolerance": 50
        },
        if (ss != null) {
          "type": "shadowsocks",
          "tag": "ss-out",
          "server": ss['server'],
          "server_port": ss['port'],
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
        if (hy2 != null) {
          "type": "hysteria2",
          "tag": "hysteria2",
          "server": hy2['server'],
          "server_port": hy2['port'],
          "password": hy2['password'],
          "tls": {
            "enabled": true,
            "server_name": hy2['tls_server_name']?.isNotEmpty == true
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
        {
          "type": "direct",
          "tag": "direct"
        }
      ],
      "route": {
        "default_domain_resolver": "dns-direct",
        "rules": [
          {
            "protocol": "dns",
            "action": "hijack-dns"
          },
          {
            "ip_is_private": true,
            "action": "route",
            "outbound": "direct"
          }
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

  // MOBILE (Android/iOS) - Uses "outbounds" array, WireGuard chains through Shadowsocks
  static Map<String, dynamic> _buildMobileConfig(
    Map<String, dynamic> wg,
    Map<String, dynamic>? hy2,
    Map<String, dynamic>? ss,
  ) {
    return {
      "log": {
        "level": "info",
        "timestamp": true
      },
      "dns": {
        "servers": [
          {
            "tag": "dns-direct",
            "address": "223.5.5.5",
            "detour": "direct"
          },
          {
            "tag": "dns-proxy",
            "address": "https://1.1.1.1/dns-query",
            "detour": "proxy"
          },
          {
            "tag": "dns-block",
            "address": "rcode://success"
          }
        ],
        "rules": [
          {
            "outbound": "any",
            "server": "dns-direct"
          },
          {
            "clash_mode": "direct",
            "server": "dns-direct"
          },
          {
            "clash_mode": "global",
            "server": "dns-proxy"
          }
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
          "outbounds": _buildSelectorOutbounds(hy2),
          "default": "auto"
        },
        {
          "type": "urltest",
          "tag": "auto",
          "outbounds": _buildAutoOutbounds(hy2),
          "url": "https://www.gstatic.com/generate_204",
          "interval": "10m",
          "tolerance": 50
        },
        {
          "type": "wireguard",
          "tag": "wireguard",
          "server": wg['server_ip'],
          "server_port": wg['server_port'],
          "system_interface": false,
          "interface_name": "wg0",
          "local_address": ["${wg['client_ip']}/32"],
          "private_key": wg['client_private_key'],
          "preshared_key": wg['client_preshared_key'],
          "peer_public_key": wg['server_public_key'],
          "mtu": 1420,
          if (ss != null) "detour": "ss-out"
        },
        if (ss != null) {
          "type": "shadowsocks",
          "tag": "ss-out",
          "server": ss['server'],
          "server_port": ss['port'],
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
        if (hy2 != null) {
          "type": "hysteria2",
          "tag": "hysteria2",
          "server": hy2['server'],
          "server_port": hy2['port'],
          "password": hy2['password'],
          "tls": {
            "enabled": true,
            "server_name": hy2['tls_server_name']?.isNotEmpty == true
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
        {
          "type": "direct",
          "tag": "direct"
        },
        {
          "type": "block",
          "tag": "block"
        },
        {
          "type": "dns",
          "tag": "dns-out"
        }
      ],
      "route": {
        "rules": [
          {
            "protocol": "dns",
            "outbound": "dns-out"
          },
          {
            "ip_is_private": true,
            "outbound": "direct"
          }
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

  // Helper: Build selector outbounds list
  static List<String> _buildSelectorOutbounds(Map<String, dynamic>? hy2) {
    final outbounds = ["auto"];
    if (hy2 != null) outbounds.add("hysteria2");
    outbounds.add("direct");
    return outbounds;
  }

  // Helper: Build auto-test outbounds list
  static List<String> _buildAutoOutbounds(Map<String, dynamic>? hy2) {
    final outbounds = ["wireguard"];
    if (hy2 != null) outbounds.add("hysteria2");
    return outbounds;
  }

  // Convert config to JSON string
  static String toJsonString(Map<String, dynamic> config) {
    return const JsonEncoder.withIndent('  ').convert(config);
  }
}

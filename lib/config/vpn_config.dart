# lib/config/vpn_config.dart
# VPN configuration template for WireGuard and Hysteria2
const String vpnConfig = '''
{
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
      "address": ["10.155.0.2/32"],
      "private_key": "QNfDN54TBS7znkepTc5DTyKJZbOb/Wo3j8gExmfTTGc=",
      "mtu": 1420,
      "peers": [
        {
          "address": "51.75.126.238",
          "port": 53050,
          "public_key": "ldvntMa1jvroOvcHXeg73/PTKvp/SJs3i4EuiG1Mq0o=",
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ]
    },
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": ["auto", "hysteria2", "direct"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["wireguard", "hysteria2"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "10m",
      "tolerance": 50
    },
    {
      "type": "shadowsocks",
      "tag": "ss-out",
      "server": "51.75.126.238",
      "server_port": 443,
      "method": "2022-blake3-aes-256-gcm",
      "password": "yK8mN3pQ7vR2xT9wU5hJ6kL1mN4oP8qS3tV7wX0yZ2a=",
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 4,
        "min_streams": 4,
        "padding": true
      },
      "tcp_fast_open": true
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "server": "51.75.126.238",
      "server_port": 8443,
      "password": "kvAsyCT3ZsYAz22J/fC5T6i35jmxNvEfZcmRpWBCm40=",
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "alpn": ["h3"],
        "insecure": true
      },
      "up_mbps": 100,
      "down_mbps": 100,
      "obfs": {
        "type": "salamander",
        "password": "AYo3SryNibASrSRyMwzyBLxA45YsASzrSr7c8DSMUU0="
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
}
''';

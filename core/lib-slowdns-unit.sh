#!/bin/bash
# VPN-Starter-Kit :: core/lib-slowdns-unit.sh
# Shared helper: (re)writes /etc/systemd/system/slowdns.service and
# reloads systemd. Source this file; it is not meant to be executed
# directly. Used by menu/menu-settings.sh (NS domain change) and
# core/ssh-engine.sh (tunnel target change) so the unit's content can't
# drift out of sync between the two call sites.
write_slowdns_unit() {
  local ns_domain="$1" target_port="$2"
  cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=SlowDNS (DNSTT) Server (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/etc/vpn-script/slowdns/dnstt-server \\
  -udp :5300 \\
  -privkey-file /etc/vpn-script/slowdns/server.key \\
  ${ns_domain} \\
  127.0.0.1:${target_port}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

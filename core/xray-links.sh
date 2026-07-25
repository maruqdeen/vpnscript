#!/bin/bash
# VPN-Starter-Kit :: core/xray-links.sh
# Share-link builders for vmess/vless/trojan/shadowsocks, used by both
# add-user.sh (right after creating a client) and generate-xray-config.sh
# (reprinting an existing client's card later). Kept in one place instead
# of duplicated across both — this is exactly the kind of link-format
# detail that already caused one real production bug (Shadowsocks' link
# silently didn't work with real clients), so there is only one copy to
# fix if that ever happens again.
# Source this file; it is not meant to be executed directly.

# vmess:// share-link JSON (v2rayN standard schema — "path", not "bpath").
# host = WS Host header, sni = TLS SNI: both set to $add (the domain) so
# the WS upgrade and the TLS handshake both present the real hostname
# instead of going out blank/as the bare IP.
# base64'd with no line wrapping: `base64 | tr -d '\n'` is portable across
# GNU/BSD base64 (unlike relying on a `-w0` flag that not all builds have).
vmess_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" tls="$7" json
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"%s","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s"}' \
    "$ps" "$add" "$port" "$id" "$net" "$add" "$path" "$tls" "$add")
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

# vless:// share link — a query-string URI, not base64 JSON like vmess.
# net=ws: host+path set (host = domain, same host/sni fix as vmess).
# net=grpc: serviceName set instead of host/path. sni added whenever TLS
# is used. "flow"/"fp" (XTLS/REALITY fingerprinting) deliberately omitted
# — those only apply over raw TCP, not the WS/gRPC transports we run.
vless_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" security="$7" q
  q="encryption=none&security=${security}&type=${net}"
  if [[ "$net" == "grpc" ]]; then
    q="${q}&serviceName=${path}"
  else
    q="${q}&host=${add}&path=$(printf '%s' "$path" | sed 's|/|%2F|g')"
  fi
  [[ "$security" == "tls" ]] && q="${q}&sni=${add}"
  printf 'vless://%s@%s:%s?%s#%s' "$id" "$add" "$port" "$q" "$ps"
}

# trojan:// share link. Same query-string shape as vless, minus
# encryption= (not a Trojan concept) and always security=tls — Trojan's
# entire design is disguising itself as ordinary HTTPS, so we don't offer
# a plaintext mode the way vmess/vless's "none TLS" link works.
trojan_link() {
  local ps="$1" add="$2" port="$3" password="$4" net="$5" path="$6" q
  q="security=tls&type=${net}"
  if [[ "$net" == "grpc" ]]; then
    q="${q}&serviceName=${path}"
  else
    q="${q}&host=${add}&path=$(printf '%s' "$path" | sed 's|/|%2F|g')"
  fi
  q="${q}&sni=${add}"
  printf 'trojan://%s@%s:%s?%s#%s' "$password" "$add" "$port" "$q" "$ps"
}

# ss:// share link — plain SIP002 form only (base64(method:password)@host:port#tag).
# An earlier version of this added type=/host=/path=/security=/sni= query
# params mirroring vless://'s convention, on the assumption Shadowsocks
# could ride the same WS/gRPC+TLS transport behind nginx as the other
# protocols. It can't, in practice: the SIP002 spec explicitly says any
# query param other than plugin= must be ignored, and real clients (incl.
# v2rayNG) follow that — they silently drop those params and speak plain
# Shadowsocks straight to host:port, which nginx then rejects (wrong
# handshake), producing an opaque "Fail to detect internet connection:
# EOF" with no indication why. Genuine SS-over-WS+TLS needs the separate
# v2ray-plugin mechanism on both ends, not Xray streamSettings — out of
# scope here, so Shadowsocks instead gets its own plain, direct port.
ss_link() {
  local ps="$1" add="$2" port="$3" method="$4" password="$5" userinfo
  userinfo="$(printf '%s' "${method}:${password}" | base64 | tr -d '\n')"
  printf 'ss://%s@%s:%s#%s' "$userinfo" "$add" "$port" "$ps"
}

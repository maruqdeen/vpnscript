# Changelog

A narrative record of what's been built in this repo and why, organized by
feature area rather than strict commit order — meant to be the first thing
you check when something breaks or behaves unexpectedly. Each section
explains the current design AND the bugs that shaped it, since the "why"
usually matters more than the diff when debugging.

Repo: `maruqdeen/vpnscript` · Timeline: 2026-07-09 → 2026-07-20

---

## If you're updating an existing (older) server

`install/update.sh` only refreshes files in `core/`, `menu/`, and installs
new `.py`/`.sh` files — it **never** creates new systemd units, never
touches `/usr/local/etc/xray/config.json`, and never runs an `enable` step.
Several features below need a one-time migration script instead. Run the
ones relevant to your install age, in this order, then `update.sh` last:

| Script | What it does | Needed if... |
|---|---|---|
| `install/migrate-vmess-grpc.sh` | Adds VMess gRPC inbound + nginx route | Installed before gRPC support existed |
| `install/migrate-vless-grpc.sh` | Adds VLESS gRPC inbound + nginx route | Installed before gRPC support existed |
| `install/migrate-trojan.sh` | Adds Trojan WS+gRPC inbounds + nginx routes | Installed before Trojan existed |
| `install/remove-shadowsocks.sh` | Removes ss-ws/ss-grpc inbounds | Ran `migrate-shadowsocks.sh` before SS was pulled |
| `install/enable-defaults.sh` | Enables HAProxy/SSLH/OpenVPN/Proxy | Installed before these defaulted to on |
| `install/migrate-xray-stats-api.sh` | Adds Xray Stats API (api/stats/policy) config | Want real per-account Xray bandwidth tracking |
| `install/migrate-ohp.sh` | Installs + starts `ohp-proxy.service` | Installed before OHP support existed |

All of these are non-destructive (existing inbounds/clients/config
untouched), take a timestamped backup before writing where they touch
`config.json`, and are safe to re-run (idempotent — a second run is a no-op
if already applied).

---

## SSH / SlowDNS tunneling

**SSH-WS** (`core/ws.py`, systemd unit `ws-proxy`) is the core tunnel: a
minimal Python proxy that doesn't actually validate the client's WebSocket
handshake — it just reads and discards whatever the client sends, replies
with a hardcoded `HTTP/1.1 101 Switching Protocols`, then bridges raw bytes
to Dropbear/OpenSSH on loopback. Fronted by nginx on 80/8080/443 (catch-all
`location /`).

**SSH-OHP** (`core/ohp.py`, systemd unit `ohp-proxy`, port **8181**,
added 2026-07-12) is a sibling to ws.py for client apps (HTTP Injector,
HTTP Custom, KPN Tunnel) in "HTTP Proxy" mode — same relay trick, but
answers with the standard proxy-CONNECT response
(`HTTP/1.1 200 Connection Established`) instead of the WS one, since those
clients expect that exact line. Runs on its own public port, bypassing
nginx entirely (same reasoning as SlowDNS/HAProxy/SSLH/OpenVPN/WireGuard/
Proxy below — nginx is only needed where path-based routing on a shared
port actually helps). Both ws.py and ohp.py read the same
`/etc/vpn-script/ssh-target-port` file (written by Settings → SSH Tunnel
Engine) so switching Dropbear/OpenSSH/both affects both tunnel types at
once.

**"Check Active Users" — the debugging saga (2026-07-10):**
This went through three attempts before landing correctly:
1. First implementation used `who`/utmp — always showed 0, because Dropbear
   may not even be built with utmp support, and every connection reaches
   it from `127.0.0.1` anyway (ws.py/HAProxy/SSLH all proxy over loopback),
   so utmp's remote-host field can't distinguish devices regardless.
2. Second attempt counted live Dropbear/sshd processes by UID — still
   showed 0 for Dropbear. Root cause: **Dropbear only calls `setuid()` when
   it execs a shell for the user.** Our tunnel accounts have shell
   `/bin/false` (pure port-forwarding, no shell ever exec'd), so Dropbear
   never drops privileges — every child process stays owned by root
   regardless of who's connected. (OpenSSH's branch was never affected —
   it setuid()s for every session, shell or not.)
3. Final fix: Dropbear's own journal log records the username per
   connection (`Password auth succeeded for 'user'`), tagged with the PID
   that services that connection for its entire lifetime. Map live PIDs to
   usernames via the log, count a PID only if it's still alive. This is a
   raw connection count, not a verified distinct-device count (Dropbear
   never sees the real client IP through the loopback proxies) — which is
   also why autokill-multilogin's default limit is 2, not 1.

**Multi-login lockout** (`core/autokill-check.sh`, cron every 2 min): if a
user exceeds their configured device limit, they get `passwd -l`'d and
killed. Configurable from SSH menu → Setup Autokill Multi Login.

**Connection + bandwidth limits** (2026-07-12, `core/ssh-limits.sh` /
`core/ssh-limits-check.sh`): account creation now prompts for a connection
limit and a bandwidth limit (entered in **GB**, converted ×1024 to MB for
internal storage). Exceeding either locks the account via the same
`passwd -l` mechanism. Bandwidth tracking is explicitly best-effort:
since Dropbear never setuid()s for these accounts (see above), there's no
clean per-UID iptables-owner-match hook — it samples `/proc/<pid>/io`
(rchar+wchar) for live Dropbear PIDs every 2 minutes and accumulates the
delta. A connection that starts and fully finishes between two samples
would be missed; fine for sustained tunnel sessions, not exact.

**Check Locked Users** (2026-07-12, replaced the old multi-login-only
check): shows every locked account with *why* it was locked
(`core/lock-reasons.sh` tracks this), and offers a reason-appropriate fix
— a bandwidth lock needs the limit actually raised (in GB) or the next
2-minute enforcement pass just re-locks it.

**60-second SSH-WS timeout** (2026-07-11): nginx's `location /` blocks
(both plain and TLS) got their `proxy_read_timeout`/`proxy_send_timeout`
cut from 300s to 60s, specifically so a silently-dead connection (phone
drops off network without a clean close) stops counting toward "Active
Users" quickly. Trade-off: a truly idle connection (zero bytes either
direction, not just no app activity) now gets disconnected after 60s —
most tunnel apps ping periodically to survive this. Xray/gRPC routes were
left untouched.

---

## Xray protocols (VMess / VLESS / Trojan)

All three share `/usr/local/etc/xray/config.json`, each with a **WS
inbound and a separate gRPC inbound** (same protocol tag, same client
list) — meaning any code that iterates `.inbounds[]` without deduping by
email will double-count or double-list every account. This bit multiple
places before being fixed everywhere: the dashboard's ACTIVE ACCOUNT count,
and the "Current X users" listings in `renew-user.sh`/`del-user.sh`
(2026-07-12, fixed with jq's `unique`). The actual add/renew/delete writes
were always correct — they target `.inbounds[]` directly so both inbounds
update together — only counting/display paths had the bug.

**VMess (2026-07-10):** was "not working" because `add-user.sh` never
generated an actual `vmess://` share link — just printed username/UUID as
plain text, which no client can import. Fixed with a real `vmess_link()`
builder (standard v2rayN JSON schema), plus a `vmess-grpc` inbound
(port 10003) and matching nginx `/vmess-grpc` route (requires `http2` on
the TLS server block). Also corrected a `bpath` → `path` typo carried over
from the original reference template — real clients don't recognize
`bpath`.

**VLESS (2026-07-10):** same fix pattern, own `vless_link()` (query-string
URI, not base64 JSON) since VLESS's share-link format is completely
different from VMess's. gRPC inbound on port 10004. `encryption=none` is
mandatory per spec; XTLS/REALITY fingerprint params deliberately omitted
since they don't apply over WS/gRPC.

**Trojan (2026-07-10):** WS (10005) + gRPC (10006) inbounds. Deliberately
**no plaintext port-80 variant** — Trojan's entire design premise is
disguising itself as ordinary HTTPS, so a plaintext Trojan isn't really
Trojan.

**Shadowsocks:** implemented 2026-07-10, then **removed the same day** —
didn't work as wanted, no longer needed. `install/remove-shadowsocks.sh`
exists for any server that ran the short-lived `migrate-shadowsocks.sh`.

**The `nobody`-user permission bug (2026-07-10):** Xray's official
installer runs `xray.service` as user `nobody`, not root. Every script
that edited `config.json` used `tmp=$(mktemp); jq ... > "$tmp" && mv
"$tmp" "$CONFIG"` — `mktemp` creates files mode 600 (root-only), and `mv`
carries that mode into the replacement, so `nobody` loses read access to
its own config on the very next restart. Confirmed live via journalctl:
`permission denied`, exit code 23. Fixed in every script with this
pattern (`chmod 644 "$tmp"` before the `mv`) — `add-user.sh`,
`del-user.sh`, `renew-user.sh`, trial scripts, migration scripts. A
sibling bug: `/var/log/vpn-script` was root-only, but Xray needs to
*write* its own log files there on startup — fixed by chowning it to
`nobody:<nobody's real group>` in `setup.sh`.

**Check Active User for Xray (2026-07-12), version 1 → 2:** Xray has no
login concept to hook into. First attempt enabled Xray's Stats API
(`api`/`stats`/`policy` config blocks) and diffed per-user traffic
counters twice a few seconds apart — a nonzero delta meant "active." This
got replaced almost immediately: Stats API only reports cumulative bytes,
not concurrent session *count*, and per-user "how many sessions" was what
was actually wanted. The Stats API config was pulled back out (nothing
used it anymore) and replaced with counting "accepted" connection lines in
Xray's own access log carrying that user's email tag, within the last 60s
(matches the SSH-WS timeout window). One nuance: Xray sits behind nginx on
loopback, so its access log's source IP is *always* `127.0.0.1` — distinct-
IP counting (the SSH approach) doesn't work here, so this counts log-line
volume instead, a session-count approximation rather than a verified
distinct-device count.

The Stats API got re-added a third time (2026-07-12) for a completely
different reason — see **Bandwidth Dashboard** below — since real
per-account Xray bandwidth genuinely does need it.

---

## WireGuard

Implemented 2026-07-10 as its own menu (`menu-wireguard.sh`) — a
fundamentally different technology from the Xray protocols (kernel-level
UDP service, no nginx routing, no Xray inbound). `core/wireguard.sh` is
the shared library: `wg_ensure_server()` lazily bootstraps the server
keypair + `wg0` interface the first time an account is created (no
separate enable step), and `wg_sync_peers()` regenerates `wg0.conf`'s
`[Peer]` blocks from `clients.json` (the authoritative store) and
hot-reloads via `wg syncconf` so adding/removing one peer never drops
another's connection.

**Check Active User (2026-07-11):** unlike SSH, WireGuard has a
purpose-built tool for this — `wg show <iface> dump` reports each peer's
last handshake timestamp directly. A handshake within 180s (peers
re-handshake roughly every 2 minutes while active) counts as Active. Later
simplified from a per-peer table to just an aggregate count/total, per
follow-up request. A real bug caught while rewriting: the original used
`jq ... | while read`, and a piped `while` runs in a subshell in bash, so
an `ACTIVE++` counter inside it silently resets before the loop exits —
fixed with process substitution (`done < <(jq ...)`).

WireGuard peers carry an `.expiry` field for display/tracking, but
WireGuard itself has no native expiry enforcement — same limitation Xray
has, closed for both by the Clean Expired User feature below.

---

## Optional services (HAProxy / SSLH / BadVPN / OpenVPN / Proxy)

All lazy-installed on first `enable`, each with its own `enabled` flag
file and Settings-menu toggle. HAProxy, SSLH, OpenVPN, and Proxy ship
**enabled by default** on fresh installs (`install/setup.sh` step
`[9/10]`); BadVPN stays off unless explicitly enabled.

- **HAProxy** (port 444): SSH-over-SSL, TLS-terminates and forwards to
  whatever the current SSH tunnel engine target is. Own unit
  (`vpn-haproxy`), never touches nginx.
- **SSLH** (port 446): multiplexes one port between raw SSH (→ tunnel
  engine) and TLS (→ HAProxy:444 — so this branch only works if HAProxy
  is *also* enabled). Own unit (`vpn-sslh`).
- **BadVPN UDPGW**: bound to `127.0.0.1:7300` only — no auth of its own,
  so exposing it publicly would make the server an open UDP relay. Reached
  via SSH local port-forward from the client.
- **OpenVPN**: TCP/1194, UDP/1194, UDP/443 (TCP/443 skipped on purpose —
  nginx already owns TCP 443). One shared client identity for everyone
  (easy-rsa PKI generated once), since the account card hands out a
  single static `.ovpn` download link rather than per-user certs.
- **Proxy**: Squid (HTTP, 3128) + Dante (SOCKS5, 1080), both
  authenticating via PAM against the same system accounts SSH uses —
  proxy credentials always match SSH credentials automatically.

### SSLH: two real bugs, both traced with live journalctl (2026-07-12)

1. **Wrong binary path.** The Debian/Ubuntu `sslh` package resolves which
   binary variant (`sslh-fork` vs `sslh-select`) gets symlinked to
   `/usr/sbin/sslh` via `update-alternatives`, a debconf question — under
   a noninteractive frontend this doesn't reliably land, so `ExecStart`
   could point at nothing. Fixed by resolving the real installed binary
   directly instead of assuming the symlink exists.
2. **Wrong CLI flags entirely.** Confirmed via real `sslh --help` output
   on a live Ubuntu 22.04 box (`sslh 1.20-1+deb11u1build0.22.04.1`): this
   build has no `--foreground` or `--config` long options at all, only
   short ones. The unit was silently falling through to sslh's own
   *default* config search paths instead of ours, failing with
   `status=4/NOPERMISSION` on every restart. Fixed: `-f -F<path>` (no
   space before the path — sslh's own help text explicitly warns about
   this).
3. Also: `systemctl enable --now` failing didn't stop the script from
   touching the enabled-flag and printing success. Added a post-start
   `is-active` check that fails loudly with the exact `journalctl` command
   to run, instead of lying that it's enabled. This "verify before
   claiming success" pattern was then applied to OpenVPN too.

### OpenVPN: ta.key never generated on Ubuntu 20.04 (2026-07-12)

Confirmed via live journalctl: `cannot stat file
'/etc/openvpn/easy-rsa/pki/ta.key'`. `openvpn --genkey secret <file>` is
the OpenVPN 2.5+ CLI syntax (what 22.04/24.04 ship); OpenVPN 2.4.x
(20.04's shipped version) needs `--genkey --secret <file>` instead, and
the newer syntax silently produced no file at all under 2.4. Fixed by
trying the new syntax first and falling back to the old one, rather than
pinning an exact version cutoff. Also moved `ta.key` generation out of the
main PKI-build guard (which only checks for `server.crt`) into its own
independent check, so a box with a partial PKI from an earlier failed
attempt — like the one that reported this — self-heals on the next
`enable` instead of skipping past the fix.

### Ubuntu 20.04/22.04/24.04 compatibility, broadly (2026-07-12)

`NEEDRESTART_MODE=a` added everywhere `DEBIAN_FRONTEND=noninteractive`
already is (10 files). Ubuntu 22.04+ ships `needrestart` as a separate apt
hook (not a debconf prompt, so `DEBIAN_FRONTEND` doesn't cover it) that
can pop an interactive "restart services?" TUI mid-install — left
unhandled, this can silently hang a non-interactive `wget | sudo bash`
run, which looks exactly like "the script just died." `install/setup.sh`'s
os-release check now also recognizes 20.04 without a warning.

### Squid HTTP proxy: auth always rejecting credentials (2026-07-20)

Reported symptom: HTTP proxy connects fine but rejects every
username/password, while SOCKS5 (same credentials) works. Root cause:
`basic_pam_auth` isn't setuid — it runs as Squid's own effective user
(`proxy`), which by default can't read `/etc/shadow`, so `pam_unix.so`'s
password check silently fails for every login even though the helper
itself runs without error. Dante/SOCKS5 authenticates through a different
path entirely, so it was unaffected. Fixed by adding the `proxy` user to
the `shadow` group (read access, not a setuid-root binary) and setting
`cache_effective_user` explicitly so there's no ambiguity about which user
that needs to be. Also switched `enable --now` to `enable` + `restart`,
since a re-run against an already-running Squid wouldn't otherwise pick up
the new group membership — that only applies on process (re)start.

---

## Bandwidth dashboard

Three different designs, each replacing the last:

1. **v1 (2026-07-11):** `vnstat`-based, interface-wide Today/Yesterday/
   Month totals.
2. **v2 (2026-07-12), accuracy pass:** the vnstat query trusted array
   *position* (`[-1]`/`[-2]`) for "today"/"yesterday" instead of matching
   actual calendar dates — risky if vnstat's JSON ordering ever didn't
   match that assumption. Fixed to match by real date instead. Also added
   a TB tier and fixed unit casing (was `Gb`/`Mb` — lowercase "b"
   conventionally means *bits*, mislabeling byte counts).
3. **v3 (2026-07-12), the actual fix:** even accurate, vnstat measures
   *all* interface traffic — SSH admin access, apt/package installs,
   background system chatter — not just VPN client usage. Confirmed live:
   a 24-minute-old box with **zero accounts created** already showed
   40.76MB "used." Replaced entirely with real per-account totals:
   - **SSH:** already tracked per-account (`bw_used_bytes` in
     `ssh-limits.json`, from the connection/bandwidth-limit feature).
   - **WireGuard:** native kernel rx/tx via `wg show <iface> dump` — no
     new instrumentation needed.
   - **Xray:** re-added the Stats API (third time this config's been
     added/removed across the session) to sum uplink+downlink per client.

   These are running totals (since account creation / since the WG tunnel
   came up / since Stats API was enabled) with no native calendar-day
   bucketing. To keep the original Today/Yesterday/Month *display* shape,
   a daily cron snapshot (`core/bandwidth-snapshot.sh`, 23:59) records the
   combined total once a day; the dashboard diffs the live total against
   that history. Clamped at 0 — an SSH renewal resets that account's
   `bw_used_bytes`, and deleting an account drops its bytes from the sum,
   so the combined total can legitimately *decrease* between snapshots,
   which would otherwise show as a nonsensical negative "used" figure.

   **Needs the Xray Stats API migration** (`install/migrate-xray-stats-api.sh`)
   for Xray accounts to contribute to the total — without it, Xray always
   reports 0 (not an error, just untracked).

---

## Security Mgt (2026-07-12)

Four toggles under a new menu, added alongside a **Bot & Api Setup** shell
(Connect to TelegramBot / Setup Web Api — both intentionally stubbed
"not built yet," functionality deferred until specified in detail):

- **Fail2ban** (default **off**): protects OpenSSH port 22. Only overrides
  `enabled`/`maxretry`/`findtime`/`bantime` in a `jail.d` drop-in —
  deliberately leaves port/filter/logpath to fail2ban's own `[sshd]`
  defaults rather than hardcoding an auth-log path that could drift across
  Ubuntu versions. 1-hour ban, not permanent, so an accidental self-lockout
  self-clears.
- **Anti-Torrent** (default **off**): heuristic BitTorrent/DHT signature
  string-matching on the `FORWARD` chain only — i.e. traffic being routed
  *through* the box by OpenVPN/WireGuard clients, not traffic to the box
  itself. Can't touch the admin's own SSH session, and can't see inside
  the encrypted Xray/SSH-WS tunnels (no plaintext signature to match
  there anyway).
- **DDoS Protection** (default **off**): SYN cookies + deliberately
  generous rate limiting (100 new connections/sec burst 200; ICMP 10/s
  burst 20). No `connlimit` rule at all — this box's normal traffic
  (multiple protocols, proxy usage) is legitimately bursty and
  high-connection-count by design, so a tight per-IP cap would end up
  DDoS-ing the VPN's own users.
- **Clean All Expired User** (default **on**, auto-enabled in `setup.sh`
  like the other optional services): daily cron sweep (00:30) that
  *deletes* SSH, Xray, and WireGuard accounts past their tracked expiry
  date. Closes a real gap — OpenSSH/Dropbear already refuse login past
  expiry via PAM, but the account itself just lingered forever; Xray and
  WireGuard had **no expiry enforcement at all** before this (accounts
  stayed fully usable past their tagged date indefinitely).

---

## Dashboard / menu structure

- Main dashboard redesigned in stages: SERVER INFO → ACTIVE SERVICE →
  ACTIVE ACCOUNT → CONTROL MANAGER → BANDWITH USAGE (that exact order and
  placement took two follow-up fixes to get right — it originally sat in
  the wrong spot, between the Control Manager header and its menu items).
- Section dividers (`line()` helper) were originally built from a fixed
  equals-count on each side, so total line length varied with title length
  (SERVER INFO came out 43 chars, CONTROL MANAGER 47, neither matching the
  plain 51-char divider used elsewhere). Rewritten to a fixed total width
  with the title centered, so every header is exactly the same length.
- A recurring formatting bug worth remembering: **padding an
  already-color-wrapped string to a fixed width miscounts the invisible
  ANSI escape bytes and misaligns the column.** Hit on the WireGuard
  active-check screen and the SSH limits table — fixed both times by
  padding the plain text first, then wrapping in color as a separate
  `printf` argument (or keeping colored fields last/unpadded).
- A recurring shell bug worth remembering: **`jq ... | while read` (or
  any piped `while`) runs the loop in a subshell**, so a counter
  incremented inside it doesn't survive past the loop. Fixed with process
  substitution (`done < <(...)`) everywhere this was caught (WireGuard
  active count, autokill-check).

# Product

## Register

product

## Users

The server's own operator — typically a solo admin or small team running this
box as VPN/proxy infrastructure (SSH tunneling, Xray VMess/VLESS/Trojan/
Shadowsocks, WireGuard), sometimes reselling access to end customers. They
already manage the server day-to-day via SSH + a bash menu, or via Telegram
bots. The admin panel (`core/admin-panel.py`) is a browser-based alternative
reachable over HTTPS for when they'd rather not use a terminal client
(Termius etc.) — same account-management/service-toggle capabilities, same
underlying scripts, different front end. Used in short, task-focused
sessions: create an account, check what's active, flip a service on/off,
check server health — not long browsing sessions.

## Product Purpose

Full parity with the bash Control Manager menu, in a browser: create/renew/
delete/view-config for SSH and Xray accounts (VMess/VLESS/Trojan/
Shadowsocks), WireGuard peers, service toggles (HAProxy/SSLH/BadVPN/OpenVPN/
Proxy/Stunnel/UDP-Custom), security tooling (Fail2ban/Anti-Torrent/DDoS
protection/expired-account cleanup), and Telegram bot setup — so the operator
never strictly needs SSH access to run the box. Success looks like: an
action (e.g. "create a VMess account") takes the same few seconds and same
number of decisions it would take in the bash menu, just from a browser tab
instead of a terminal.

## Brand Personality

Clean, precise, calm. A quiet control-room feel: nothing shouts, status and
data are easy to scan at a glance, actions feel deliberate rather than
playful. This is infrastructure tooling, not a marketing surface — polish
should read as competence, not decoration.

## Anti-references

No specific named anti-references given. Two things to actively avoid:
generic "AI SaaS dashboard" scaffolding (gradient hero metrics, tiny
tracked-uppercase eyebrows, identical icon+heading+text card grids); and the
surface being replaced — an undifferentiated dark-navy-everywhere theme with
no light mode and flat, low-contrast cards.

## Design Principles

- **Status at a glance.** Service/account state (active, locked, expired,
  enabled/disabled) should be readable from color and position alone,
  without reading every label.
- **Deliberate actions.** Destructive or high-consequence actions (delete an
  account, disable a service, disconnect a bot) should never be reachable by
  an accidental click — but shouldn't be buried either; the operator knows
  what they're doing and needs to move fast.
- **One consistent pattern, repeated.** SSH, VMess, VLESS, Trojan,
  Shadowsocks, and WireGuard all follow the same account-management shape
  (create form → table of accounts → per-row actions). Keep that pattern
  visually and structurally identical everywhere it appears so the tool
  stays predictable as it grows.
- **Dark mode is first-class.** This gets used at odd hours managing a
  live server, sometimes in a dark room. Light and dark are both real,
  finished themes — not a light theme with an inverted afterthought.
- **No unnecessary flourish.** Motion and color exist to clarify state
  changes (a toggle flipping, an action completing), not to decorate. This
  is a utility, not a portfolio piece.

## Accessibility & Inclusion

WCAG AA baseline: sufficient color contrast in both themes (body text ≥4.5:1,
large text ≥3:1), full keyboard navigability, and a `prefers-reduced-motion`
alternative for any transition/animation. No additional accommodations
specified beyond that baseline.

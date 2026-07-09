#!/bin/bash
# VPN-Starter-Kit :: core/slowdns.sh
# Install DNSTT (SlowDNS) by BUILDING FROM SOURCE.
# (Prebuilt-binary mirrors get deleted/DMCA'd — that was the old 404. Source doesn't rot.)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

SLOWDNS_DIR="/etc/vpn-script/slowdns"
BUILD_DIR="/tmp/dnstt-build"
mkdir -p "$SLOWDNS_DIR"

# A 0-byte binary can linger from an earlier failed download — purge it so the
# build actually runs instead of trying to execute an empty file.
if [[ -e "$SLOWDNS_DIR/dnstt-server" && ! -s "$SLOWDNS_DIR/dnstt-server" ]]; then
  echo ">>> Removing broken/empty dnstt-server from a previous run..."
  rm -f "$SLOWDNS_DIR/dnstt-server"
fi

# --- 1. Ensure a MODERN Go + git are present (only if we still need to build) ---
# -s = exists AND non-empty; rebuild whenever that's not true.
if [[ ! -s "$SLOWDNS_DIR/dnstt-server" ]]; then

  # git for the canonical clone (curl fallback covers it if git is missing)
  command -v git >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y git; }

  # dnstt's deps use the Go 1.21 `clear` builtin. Ubuntu 22.04's apt Go is 1.18
  # (too old — build fails with "undefined: clear"), so install an official
  # Go toolchain to /usr/local/go and prefer it on PATH.
  GO_MIN_MINOR=21
  need_go=1
  if command -v go >/dev/null 2>&1; then
    gv=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | head -1 | sed 's/go//')
    if [[ -n "$gv" ]]; then
      gmaj=${gv%%.*}; gmin=${gv##*.}
      if (( gmaj > 1 || (gmaj == 1 && gmin >= GO_MIN_MINOR) )); then need_go=0; fi
    fi
  fi

  if (( need_go )); then
    echo ">>> Installing modern Go toolchain (apt version too old)..."
    GO_VER="1.22.5"
    case "$(uname -m)" in
      x86_64)  GO_ARCH="amd64" ;;
      aarch64) GO_ARCH="arm64" ;;
      *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    wget -qO /tmp/go.tar.gz "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" \
      || { echo "Go download failed. Check network settings."; exit 1; }
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
  fi
  export PATH="/usr/local/go/bin:$PATH"

  # --- 2. Fetch source: canonical bamsoftware first, GitHub mirror as fallback ---
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
  echo ">>> Fetching dnstt source..."
  if command -v git >/dev/null 2>&1 && \
     git clone --depth 1 https://www.bamsoftware.com/git/dnstt.git src 2>/dev/null; then
    echo "    source: bamsoftware.com (canonical)"
  else
    echo "    canonical unreachable — using GitHub mirror..."
    curl -fsSL -o dnstt.tar.gz \
      "https://codeload.github.com/gh4rib/dnstt/tar.gz/refs/heads/main" \
      || { echo "Source download failed. Check network settings."; exit 1; }
    mkdir -p src && tar -xzf dnstt.tar.gz -C src --strip-components=1
  fi

  # --- 3. Build the server binary ---
  echo ">>> Building dnstt-server (first build downloads Go modules, ~1 min)..."
  cd src/dnstt-server
  go build -o "$SLOWDNS_DIR/dnstt-server" \
    || { echo "Build failed. See output above."; exit 1; }
  chmod +x "$SLOWDNS_DIR/dnstt-server"
  cd / && rm -rf "$BUILD_DIR"
  echo "    built: $SLOWDNS_DIR/dnstt-server"
fi

# Belt-and-suspenders: make sure it's executable before we run it.
chmod +x "$SLOWDNS_DIR/dnstt-server"

# --- 4. Generate the server keypair (only once) ---
if [[ ! -f "$SLOWDNS_DIR/server.key" ]]; then
  echo ">>> Generating DNSTT keypair..."
  "$SLOWDNS_DIR/dnstt-server" -gen-key \
    -privkey-file "$SLOWDNS_DIR/server.key" \
    -pubkey-file "$SLOWDNS_DIR/server.pub"
fi

echo "============================================"
echo " SlowDNS core installed (built from source)."
echo "   Listen : UDP 5300  (iptables redirects :53 here)"
echo "   Target : 127.0.0.1:143  (Dropbear)"
echo ""
echo " PUBLIC KEY (give this to clients):"
cat "$SLOWDNS_DIR/server.pub"
echo "============================================"

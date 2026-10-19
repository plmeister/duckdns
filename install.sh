#!/usr/bin/env bash
#
# Install (or remove) the DuckDNS updater on a systemd Debian/Ubuntu host.
#
# From a checkout:   sudo ./install.sh
# Piped from GitHub: curl -fsSL <raw-url>/install.sh | sudo bash
#   ...with args:    curl -fsSL <raw-url>/install.sh | sudo bash -s -- --uninstall
#
# When piped there are no sibling files, so the repo tarball is fetched into a
# temporary directory. Only the install path needs the payload: --help and
# --uninstall never download anything. Override the source with:
#   DUCKDNS_REPO=owner/duckdns   (default below)
#   DUCKDNS_REF=<branch|tag|commit>
#   DUCKDNS_TARBALL_URL=<full url>  (any host; beats the two above)
#
# An existing env file is never overwritten.
#
# Overridables (mainly for testing): DESTDIR, BIN_DIR, UNIT_DIR, ENV_DIR.
#
set -euo pipefail

REPO=${DUCKDNS_REPO:-plmeister/duckdns}
REF=${DUCKDNS_REF:-main}
TARBALL_URL=${DUCKDNS_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/$REF}

DESTDIR=${DESTDIR:-}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
ENV_DIR=${ENV_DIR:-/etc}

SCRIPT=duckdns-update.sh
UNITS=(duckdns-update.service duckdns-update.timer)
ENV_FILE=$ENV_DIR/duckdns.env

usage() {
  cat <<EOF
Usage: install.sh [--uninstall | --purge]

  (no args)    install the updater and start the timer
  --uninstall  stop the timer, remove units and script, keep the config file
  --purge      as above, and delete $ENV_FILE

Environment:
  DUCKDNS_REPO=owner/duckdns   repo to fetch when piped (default $REPO)
  DUCKDNS_REF=<git ref>        branch, tag or commit (default $REF)
  DUCKDNS_TARBALL_URL=<url>    full tarball URL, overrides the two above
  DESTDIR=<dir>                staging prefix for testing
EOF
}

# --- Arguments (parsed first, so --help/--uninstall need no download) ------
mode=install
purge=0
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --purge)     mode=uninstall; purge=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; echo "ERROR: unknown argument: $a" >&2; exit 1 ;;
  esac
done

if [[ -z $DESTDIR && $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo $0 $*)" >&2
  exit 1
fi

have_systemd=0
if [[ -z $DESTDIR ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  have_systemd=1
fi

# --- uninstall (no payload required) --------------------------------------
if [[ $mode == uninstall ]]; then
  if (( have_systemd )); then
    systemctl disable --now duckdns-update.timer 2>/dev/null || true
  fi
  rm -f "$DESTDIR$UNIT_DIR"/duckdns-update.{service,timer} "$DESTDIR$BIN_DIR/$SCRIPT"
  if (( purge )); then
    rm -f "$DESTDIR$ENV_FILE"
    echo "removed $ENV_FILE"
  else
    echo "kept $ENV_FILE (use --purge to delete it)"
  fi
  (( have_systemd )) && systemctl daemon-reload
  echo "uninstalled."
  exit 0
fi

# --- Locate the payload, fetching it when piped ---------------------------
tmp=""
cleanup() { [[ -n $tmp ]] && rm -rf "$tmp"; }
trap cleanup EXIT

SRC=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SRC=$PWD
if [[ ! -f $SRC/$SCRIPT ]]; then
  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { echo "ERROR: tar is required" >&2;  exit 1; }

  tmp=$(mktemp -d)
  echo "fetching $TARBALL_URL"
  if ! curl -fsSL "$TARBALL_URL" | tar -xz -C "$tmp" --strip-components=1; then
    echo "ERROR: could not download or unpack $TARBALL_URL" >&2
    echo "       set DUCKDNS_TARBALL_URL or DUCKDNS_REPO/DUCKDNS_REF" >&2
    exit 1
  fi
  SRC=$tmp
fi

missing=()
for f in "$SCRIPT" "${UNITS[@]}" "$(basename "$ENV_FILE").example"; do
  [[ -f $SRC/$f ]] || missing+=("$f")
done
if (( ${#missing[@]} )); then
  echo "ERROR: missing files in $SRC: ${missing[*]}" >&2
  exit 1
fi

# --- install ---------------------------------------------------------------
if (( have_systemd )); then
  deps=()
  for c in curl dig; do
    command -v "$c" >/dev/null 2>&1 || deps+=("$c")
  done
  if (( ${#deps[@]} )); then
    echo "ERROR: missing required command(s): ${deps[*]}" >&2
    echo "       install with: sudo apt-get update && sudo apt-get install -y curl dnsutils" >&2
    exit 1
  fi
fi

install -D -m 0755 "$SRC/$SCRIPT" "$DESTDIR$BIN_DIR/$SCRIPT"
install -D -m 0644 "$SRC/${UNITS[0]}" "$DESTDIR$UNIT_DIR/${UNITS[0]}"
install -D -m 0644 "$SRC/${UNITS[1]}" "$DESTDIR$UNIT_DIR/${UNITS[1]}"
echo "installed $BIN_DIR/$SCRIPT and ${#UNITS[@]} units in $UNIT_DIR"

if [[ -e $DESTDIR$ENV_FILE ]]; then
  echo "kept existing $ENV_FILE"
else
  install -D -m 0600 "$SRC/$(basename "$ENV_FILE").example" "$DESTDIR$ENV_FILE"
  echo "created $ENV_FILE from the template — EDIT IT before relying on this:"
  echo "  sudoedit $ENV_FILE"
fi

if grep -q 'replace-me' "$DESTDIR$ENV_FILE" 2>/dev/null; then
  echo "WARNING: $ENV_FILE still contains a placeholder token; no update will succeed."
fi

if (( have_systemd )); then
  systemctl daemon-reload
  systemctl enable --now duckdns-update.timer
  echo
  echo "timer enabled. Check it with:"
  echo "  systemctl list-timers duckdns-update.timer"
  echo "  journalctl -u duckdns-update.service -n 20 --no-pager"
  echo "Dry run (no API calls):"
  echo "  DUCKDNS_DRY_RUN=1 sudo $BIN_DIR/$SCRIPT"
else
  echo
  echo "systemd not available here; files placed under $DESTDIR. On the target host run:"
  echo "  sudo systemctl daemon-reload && sudo systemctl enable --now duckdns-update.timer"
fi

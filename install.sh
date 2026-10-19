#!/usr/bin/env bash
#
# Install (or remove) the DuckDNS updater on a systemd Debian/Ubuntu host.
#
# Scope is chosen automatically:
#   root  -> system-wide: /usr/local/bin, /etc/systemd/system, config dir /etc/duckdns.d
#   other -> user:        ~/.local/bin, ~/.config/systemd/user, config dir ~/.config/duckdns
# Use --system or --user to override. DESTDIR enables test mode.
#
# If no config files exist, it will create an example config file.
#
# Options:
#   --system                force system-wide
#   --user                  force user mode
#   --uninstall             stop timer, remove units + script, keep configs
#   --purge                 as above, and remove config dir + files
#   -h|--help
#
set -euo pipefail

DESTDIR=${DESTDIR:-}

SCRIPT=duckdns-update.sh
UNITS=(duckdns-update.service duckdns-update.timer)

usage() {
  cat <<EOF
Usage: install.sh [--system | --user] [--uninstall | --purge]

  (no args)    install the updater, create a config example if needed
  --uninstall  stop timer, remove units + script, keep configs
  --purge      as above, and remove config dir/files
  --system     install system-wide (root); default when running as root
  --user       install for the current user (systemctl --user)
EOF
}

mode=install
purge=0
scope=auto
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --purge)     mode=uninstall; purge=1 ;;
    --system)    scope=system ;;
    --user)      scope=user ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; echo "ERROR: unknown argument: $a" >&2; exit 1 ;;
  esac
done

if [[ $scope == auto ]]; then
  if (( EUID == 0 )); then scope=system; else scope=user; fi
fi

testing=0; [[ -n $DESTDIR ]] && testing=1

if (( ! testing )); then
  if [[ $scope == system && $EUID -ne 0 ]]; then
    echo "ERROR: --system needs root (sudo $0 $*)" >&2
    exit 1
  fi
  if [[ $scope == user && $EUID -eq 0 ]]; then
    echo "ERROR: run --user as the target user (not root/sudo)" >&2
    exit 1
  fi
fi

if [[ $scope == system ]]; then
  BIN_DIR=${BIN_DIR:-/usr/local/bin}
  UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
  CONF_DIR=${CONF_DIR:-/etc/duckdns.d}
  UNIT_MODE=0644
else
  BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
  UNIT_DIR=${UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
  CONF_DIR=${CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/duckdns}
  UNIT_MODE=0644
fi

have_systemd=0
if (( ! testing )); then
  if [[ $scope == system ]]; then
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && have_systemd=1
  else
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1 && have_systemd=1
  fi
fi
ctl() { if [[ $scope == system ]]; then systemctl "$@"; else systemctl --user "$@"; fi; }

# payload
tmp=""
cleanup() { [[ -n $tmp ]] && rm -rf "$tmp"; }
trap cleanup EXIT
SRC=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SRC=$PWD
if [[ ! -f $SRC/$SCRIPT ]]; then
  command -v curl >/dev/null 2>&1 || fail_missing_curl() { echo "curl required" >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { echo "tar required" >&2; exit 1; }
  tmp=$(mktemp -d)
  REPO=${DUCKDNS_REPO:-plmeister/duckdns}
  REF=${DUCKDNS_REF:-main}
  TARBALL_URL=${DUCKDNS_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/$REF}
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$tmp" --strip-components=1
  SRC=$tmp
fi

missing=()
for f in "$SCRIPT" "${UNITS[@]}" example.env.example; do
  [[ -e $SRC/$f ]] || missing+=("$f")
done
(( ${#missing[@]} )) && { echo "ERROR: missing $missing" >&2; exit 1; }

if [[ $mode == uninstall ]]; then
  (( have_systemd )) && ctl disable --now duckdns-update.timer 2>/dev/null || true
  rm -f "$DESTDIR$UNIT_DIR"/duckdns-update.{service,timer} "$DESTDIR$BIN_DIR/$SCRIPT"
  if (( purge )); then
    rm -rf "$DESTDIR$CONF_DIR"
    echo "removed $CONF_DIR"
  else
    echo "kept $CONF_DIR (use --purge to delete it)"
  fi
  (( have_systemd )) && ctl daemon-reload
  echo "uninstalled ($scope scope)."
  exit 0
fi

# install
if (( have_systemd )); then
  for c in curl dig; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing $c; apt install curl dnsutils" >&2; exit 1; }
  done
fi

install -D -m 0755 "$SRC/$SCRIPT" "$DESTDIR$BIN_DIR/$SCRIPT"
install -D -m "$UNIT_MODE" "$SRC/${UNITS[0]}" "$DESTDIR$UNIT_DIR/${UNITS[0]}"
install -D -m "$UNIT_MODE" "$SRC/${UNITS[1]}" "$DESTDIR$UNIT_DIR/${UNITS[1]}"

# config
mkdir -p "$DESTDIR$CONF_DIR"
shopt -s nullglob
have_conf=0; for f in "$DESTDIR$CONF_DIR"/*.env; do have_conf=1; break; done
if (( ! have_conf )); then
  example=$(ls "$SRC"/example.env.example "$SRC"/duckdns.env.example 2>/dev/null | head -1)
  [[ -n $example ]] && install -D -m 0600 "$example" "$DESTDIR$CONF_DIR/example.env"
  echo "created $CONF_DIR/example.env — edit it and rename to *.env"
else
  echo "kept existing configs in $CONF_DIR"
fi

# user unit env
if [[ $scope == user ]]; then
  unit_env=$CONF_DIR
  if [[ $unit_env == "$HOME"/* ]]; then
    unit_env="%h/${unit_env#"$HOME"/}"
  fi
  sed -i "/^\[Service\]/a Environment=DUCKDNS_CONFIG_DIR=$unit_env" "$DESTDIR$UNIT_DIR/${UNITS[0]}"
fi

if (( have_systemd )); then
  ctl daemon-reload
  ctl enable --now duckdns-update.timer
  echo "enabled ($scope scope)"
  ctl list-timers duckdns-update.timer 2>&1 | tail -2
else
  echo "systemd not available; files placed under $DESTDIR"
fi

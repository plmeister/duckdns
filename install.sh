#!/usr/bin/env bash
#
# Install (or remove) the DuckDNS updater on a systemd Debian/Ubuntu host.
#
set -euo pipefail

DESTDIR=${DESTDIR:-}

SCRIPT=duckdns-update.sh

usage() {
  cat <<EOF
Usage: install.sh [--system | --user] [--uninstall | --purge] [-h|--help]
EOF
}

mode=install; purge=0; scope=auto
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --purge) mode=uninstall; purge=1 ;;
    --system) scope=system ;;
    --user) scope=user ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

if [[ $scope == auto ]]; then
  if (( EUID == 0 )); then scope=system; else scope=user; fi
fi

testing=0; [[ -n $DESTDIR ]] && testing=1
if (( ! testing )); then
  if [[ $scope == system && $EUID -ne 0 ]]; then echo "ERROR: need root for --system" >&2; exit 1; fi
  if [[ $scope == user && $EUID -eq 0 ]]; then echo "ERROR: run --user as the target user" >&2; exit 1; fi
fi

if [[ $scope == system ]]; then
  BIN_DIR=${BIN_DIR:-/usr/local/bin}
  UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
  CONF_DIR=${CONF_DIR:-/etc/duckdns.d}
  UNIT_MODE=0644
  ctl() { systemctl "$@"; }
  have_systemd=0
  if (( ! testing )) && command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then have_systemd=1; fi
else
  BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
  UNIT_DIR=${UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
  CONF_DIR=${CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/duckdns}
  UNIT_MODE=0644
  ctl() { systemctl --user "$@"; }
  have_systemd=0
  if (( ! testing )) && command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then have_systemd=1; fi
fi

tmp=""; cleanup() { [[ -n $tmp ]] && rm -rf "$tmp"; }; trap cleanup EXIT
SRC=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SRC=$PWD
if [[ ! -f $SRC/$SCRIPT ]]; then
  command -v curl >/dev/null && command -v tar >/dev/null || { echo "curl/tar required" >&2; exit 1; }
  tmp=$(mktemp -d)
  REPO=${DUCKDNS_REPO:-plmeister/duckdns}
  REF=${DUCKDNS_REF:-main}
  TARBALL_URL=${DUCKDNS_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/$REF}
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$tmp" --strip-components=1 && SRC=$tmp
fi

for f in "$SCRIPT" example.env.example; do [[ -e $SRC/$f ]] || { echo "missing $f" >&2; exit 1; }; done

if [[ $mode == uninstall ]]; then
  (( have_systemd )) && ctl disable --now duckdns-update.timer 2>/dev/null || true
  rm -f "$DESTDIR$UNIT_DIR"/duckdns-update.{service,timer} "$DESTDIR$BIN_DIR/$SCRIPT"
  if (( purge )); then rm -rf "$DESTDIR$CONF_DIR"; echo "removed $CONF_DIR"; else echo "kept $CONF_DIR"; fi
  (( have_systemd )) && ctl daemon-reload
  echo "uninstalled ($scope)"
  exit 0
fi

if (( have_systemd )); then
  for c in curl dig; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
fi

install -D -m 0755 "$SRC/$SCRIPT" "$DESTDIR$BIN_DIR/$SCRIPT"
mkdir -p "$DESTDIR$UNIT_DIR"

# write service
cat > "$DESTDIR$UNIT_DIR/duckdns-update.service" <<EOF
[Unit]
Description=DuckDNS IP updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/duckdns-update.sh
EOF
if [[ $scope == system ]]; then
  echo "Environment=DUCKDNS_CONFIG_DIR=$CONF_DIR" >> "$DESTDIR$UNIT_DIR/duckdns-update.service"
else
  unit_conf=%h/.config/duckdns
  if [[ $CONF_DIR == "$HOME"/* ]]; then
    unit_conf="%h/${CONF_DIR#"$HOME"/}"
  fi
  echo "Environment=DUCKDNS_CONFIG_DIR=$unit_conf" >> "$DESTDIR$UNIT_DIR/duckdns-update.service"
fi

install -D -m "$UNIT_MODE" "$SRC/duckdns-update.timer" "$DESTDIR$UNIT_DIR/duckdns-update.timer"

mkdir -p "$DESTDIR$CONF_DIR"
shopt -s nullglob; have_conf=0; for f in "$DESTDIR$CONF_DIR"/*.env; do have_conf=1; break; done
if (( ! have_conf )); then
  example="$SRC/example.env.example"
  [[ -e "$example" ]] && install -D -m 0600 "$example" "$DESTDIR$CONF_DIR/example.env"
  echo "created $CONF_DIR/example.env — edit it and rename to *.env"
else
  echo "kept existing configs in $CONF_DIR"
fi

if (( have_systemd )); then
  ctl daemon-reload
  ctl enable --now duckdns-update.timer
  echo "enabled ($scope)"
else
  echo "files placed under $DESTDIR"
fi

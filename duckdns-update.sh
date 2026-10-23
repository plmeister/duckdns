#!/usr/bin/env bash
#
# Keep DuckDNS A records in sync with this host's public IP.
#
# Each group is defined by an env file in the config directory
# (DUCKDNS_CONFIG_DIR). A group file contains:
#
#   DUCKDNS_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   DUCKDNS_DOMAINS=mydomain,otherdomain
#
# Defaults:
#   - /etc/duckdns.d (system-wide)
#   - ~/.config/duckdns (user, used if system dir missing and it exists)
#
# Optional overrides: DUCKDNS_IP_URL, DUCKDNS_DNS_SERVER, DUCKDNS_UPDATE_URL,
# DUCKDNS_IP (skip lookup), DUCKDNS_DRY_RUN=1, DUCKDNS_FORCE=1,
# DUCKDNS_VERBOSE=1 (extra diagnostic lines; never includes tokens).
#
# Only domains whose DNS answer differs from the public IP are updated.
#
set -euo pipefail

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
# Diagnostic lines, only when DUCKDNS_VERBOSE=1. Never log the token.
vlog() { if [[ ${DUCKDNS_VERBOSE:-0} == 1 ]]; then log "DEBUG: $*"; fi; }

if [[ -n ${DUCKDNS_CONFIG_DIR:-} ]]; then
  conf_dir=$DUCKDNS_CONFIG_DIR
elif [[ -d /etc/duckdns.d ]]; then
  conf_dir=/etc/duckdns.d
elif [[ -n ${XDG_CONFIG_HOME:-} && -d "${XDG_CONFIG_HOME}/duckdns" ]]; then
  conf_dir="${XDG_CONFIG_HOME}/duckdns"
elif [[ -d "$HOME/.config/duckdns" ]]; then
  conf_dir="$HOME/.config/duckdns"
else
  conf_dir=/etc/duckdns.d
fi
vlog "config dir: $conf_dir"

IP_URL=${DUCKDNS_IP_URL:-https://api.ipify.org}
DNS_SERVER=${DUCKDNS_DNS_SERVER:-1.1.1.1}
UPDATE_URL=${DUCKDNS_UPDATE_URL:-https://www.duckdns.org/update}

shopt -s nullglob

# Collect groups ("domains|token|file")
groups=()
if [[ -d $conf_dir ]]; then
  for f in "$conf_dir"/*.env; do
    [[ -r $f ]] || continue
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
    token=${DUCKDNS_TOKEN:-${TOKEN:-}}
    domains=${DUCKDNS_DOMAINS:-${DOMAINS:-}}
    if [[ -z $domains || -z $token ]]; then
      log "WARNING: skipping $f (missing DUCKDNS_TOKEN or DUCKDNS_DOMAINS)" >&2
      unset DUCKDNS_TOKEN DUCKDNS_DOMAINS TOKEN DOMAINS
      continue
    fi
    groups+=("$domains|$token|$f")
    vlog "group $f: domains=$domains"
    unset DUCKDNS_TOKEN DUCKDNS_DOMAINS TOKEN DOMAINS
  done
fi

# Backward compat: single /etc/duckdns.env
if (( ${#groups[@]} == 0 )) && [[ -r /etc/duckdns.env ]]; then
  set -a; . /etc/duckdns.env; set +a
  token=${DUCKDNS_TOKEN:-}
  domains=${DUCKDNS_DOMAINS:-}
  if [[ -n $domains && -n $token ]]; then
    groups+=("$domains|$token|/etc/duckdns.env")
  fi
  unset DUCKDNS_TOKEN DUCKDNS_DOMAINS
fi

(( ${#groups[@]} )) || fail "no groups found in $conf_dir/*.env or /etc/duckdns.env"

# Public IP
ip=${DUCKDNS_IP:-}
if [[ -n $ip ]]; then
  ip_src="DUCKDNS_IP override"
else
  ip=$(curl -fsS --max-time 15 "$IP_URL") || fail "could not determine public IP from $IP_URL"
  ip_src=$IP_URL
fi
[[ $ip =~ ^[0-9a-fA-F:.]{7,45}$ ]] || fail "implausible public IP: '$ip'"
vlog "public IP: $ip (source: $ip_src)"
vlog "dns server: $DNS_SERVER; groups: ${#groups[@]}"

rc=0
for group in "${groups[@]}"; do
  domains=${group%%|*}; rest=${group#*|}
  token=${rest%%|*}; file=${rest##*|}
  drifted=()
  IFS=, read -r -a list <<<"${domains//[[:space:]]/}"
  for d in "${list[@]}"; do
    [[ -n $d ]] || continue
    dns=$(dig +short "$d.duckdns.org" "@$DNS_SERVER" | tail -n1) || true
    vlog "lookup $d.duckdns.org @$DNS_SERVER -> ${dns:-<no answer>}"
    if [[ -z $dns ]]; then
      log "ERROR: no DNS answer for $d.duckdns.org ($file)" >&2
      rc=1
    elif [[ ${DUCKDNS_FORCE:-0} == 1 || $dns != "$ip" ]]; then
      drifted+=("$d")
    else
      log "$d already points at $dns ($file)"
    fi
  done
  (( ${#drifted[@]} )) || continue
  join=$(IFS=,; printf '%s' "${drifted[*]}")
  if [[ ${DUCKDNS_DRY_RUN:-0} == 1 ]]; then
    log "would update $join -> $ip (dry run, $file)"
    continue
  fi
  log "updating $join -> $ip ($file)"
  vlog "request: url=$UPDATE_URL domains=$join ip=$ip file=$file"
  resp=$(curl -fsS --max-time 15 --get \
      --data-urlencode "domains=$join" \
      --data-urlencode "token=$token" \
      --data-urlencode "ip=$ip" \
      "$UPDATE_URL") || { log "ERROR: update request failed for $join ($file)" >&2; rc=1; continue; }
  vlog "response: '${resp:-<empty>}'"
  if [[ $resp == OK ]]; then
    log "update OK ($join, $file)"
  else
    log "ERROR: update rejected for $join: '${resp:-<empty>}' ($file)" >&2
    rc=1
  fi
done
vlog "finished: groups=${#groups[@]} rc=$rc"
exit "$rc"

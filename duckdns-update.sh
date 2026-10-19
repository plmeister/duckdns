#!/usr/bin/env bash
#
# Keep DuckDNS A records in sync with this host's public IP.
#
# Config comes from an env file (DUCKDNS_ENV_FILE, default /etc/duckdns.env);
# nothing is hard-coded. A "group" is one DuckDNS token plus the domains that
# share it. Groups are numbered from 1 and must be contiguous:
#
#   DUCKDNS_1_DOMAINS=mydomain,otherdomain
#   DUCKDNS_1_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   DUCKDNS_2_DOMAINS=example
#   DUCKDNS_2_TOKEN=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
#
# Optional overrides: DUCKDNS_IP_URL, DUCKDNS_DNS_SERVER, DUCKDNS_UPDATE_URL,
# DUCKDNS_IP (skip the lookup), DUCKDNS_DRY_RUN=1, DUCKDNS_FORCE=1.
#
# Only domains whose DNS answer differs from the public IP are updated, so the
# script is safe to run on a short systemd timer.
#
set -euo pipefail

ENV_FILE=${DUCKDNS_ENV_FILE:-/etc/duckdns.env}

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

if [[ -r $ENV_FILE ]]; then
  set -a; . "$ENV_FILE"; set +a
else
  fail "env file $ENV_FILE not found or not readable"
fi

# Resolved after sourcing, so the env file can set these too.
IP_URL=${DUCKDNS_IP_URL:-https://api.ipify.org}
DNS_SERVER=${DUCKDNS_DNS_SERVER:-1.1.1.1}
UPDATE_URL=${DUCKDNS_UPDATE_URL:-https://www.duckdns.org/update}

# --- Collect groups ("domains|token") --------------------------------------
groups=()
i=1
while :; do
  d_var=DUCKDNS_${i}_DOMAINS
  t_var=DUCKDNS_${i}_TOKEN
  domains=${!d_var:-}
  token=${!t_var:-}
  [[ -n $domains || -n $token ]] || break
  [[ -n $domains && -n $token ]] || fail "group $i needs both $d_var and $t_var"
  groups+=("$domains|$token")
  i=$((i + 1))
done
(( ${#groups[@]} )) || fail "no DUCKDNS_1_DOMAINS/DUCKDNS_1_TOKEN in $ENV_FILE"

# A gap (1 and 3 set, 2 missing) would silently drop later groups.
while IFS= read -r var; do
  if [[ $var =~ ^DUCKDNS_([0-9]+)_ ]] && (( BASH_REMATCH[1] > ${#groups[@]} )); then
    fail "config gap: $var is set but group ${#groups[@]} is missing"
  fi
done < <(compgen -v DUCKDNS_ || true)

# --- Public IP -------------------------------------------------------------
ip=${DUCKDNS_IP:-}
[[ -n $ip ]] || ip=$(curl -fsS --max-time 15 "$IP_URL") ||
  fail "could not determine public IP from $IP_URL"
[[ $ip =~ ^[0-9a-fA-F:.]{7,45}$ ]] || fail "implausible public IP: '$ip'"

# --- Reconcile -------------------------------------------------------------
rc=0
for group in "${groups[@]}"; do
  domains=${group%%|*}
  token=${group##*|}

  drifted=()
  IFS=, read -r -a list <<<"${domains// /}"
  for d in "${list[@]}"; do
    [[ -n $d ]] || continue
    dns=$(dig +short "$d.duckdns.org" "@$DNS_SERVER" | tail -n1) || true
    if [[ -z $dns ]]; then
      log "ERROR: no DNS answer for $d.duckdns.org" >&2
      rc=1
    elif [[ ${DUCKDNS_FORCE:-0} == 1 || $dns != "$ip" ]]; then
      drifted+=("$d")
    else
      log "$d already points at $dns"
    fi
  done
  (( ${#drifted[@]} )) || continue

  join=$(IFS=,; printf '%s' "${drifted[*]}")
  if [[ ${DUCKDNS_DRY_RUN:-0} == 1 ]]; then
    log "would update $join -> $ip (dry run)"
    continue
  fi

  log "updating $join -> $ip"
  resp=$(curl -fsS --max-time 15 --get \
      --data-urlencode "domains=$join" \
      --data-urlencode "token=$token" \
      --data-urlencode "ip=$ip" \
      "$UPDATE_URL") || { log "ERROR: update request failed for $join" >&2; rc=1; continue; }

  if [[ $resp == OK ]]; then
    log "update OK ($join)"
  else
    log "ERROR: update rejected for $join: '${resp:-<empty>}'" >&2
    rc=1
  fi
done

exit "$rc"

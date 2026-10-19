# duckdns

Keeps DuckDNS A records in sync with the host's public IP. Configuration is
entirely file-driven (no hard-coded domains or tokens) and supports any number
of domains and tokens.

Only domains whose current DNS answer differs from the public IP are updated,
so the script is safe to run on a short timer. No CLI arguments; everything is
controlled by the env file.

## Files

| File | Purpose |
|------|---------|
| `duckdns-update.sh` | The updater. Reads config from an env file. |
| `duckdns-update.service` | `Type=oneshot` unit that runs the script. |
| `duckdns-update.timer` | Runs the service 1 min after boot, then every 15 min. |
| `duckdns.env.example` | Template config. |
| `install.sh` | Installs/removes the above on a systemd host. |

## Configuration

`/etc/duckdns.env` (root-owned, mode `0600`). A *group* is one DuckDNS token
plus every domain updated with it:

```sh
DUCKDNS_1_DOMAINS=mydomain,otherdomain
DUCKDNS_1_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
DUCKDNS_2_DOMAINS=example
DUCKDNS_2_TOKEN=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

- Groups are numbered from `1` and must be contiguous. A gap (`1` and `3` set,
  `2` missing) is a fatal error rather than a silent skip.
- Domains are written without the `.duckdns.org` suffix.
- A group with domains but no token (or vice versa) is a fatal error.
- A missing or unreadable env file is a fatal error.

Optional overrides, readable from the env file: `DUCKDNS_IP_URL`,
`DUCKDNS_DNS_SERVER`, `DUCKDNS_UPDATE_URL`, `DUCKDNS_IP` (skip the lookup and
use this address), `DUCKDNS_DRY_RUN=1` (report only), `DUCKDNS_FORCE=1` (update
even when DNS already matches).

Set a different config path with `DUCKDNS_ENV_FILE=/path/to/file`.

## Install

### One-liner (piped from GitHub)

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/main/install.sh | sudo bash
```

Piping to a shell executes remote code, so read the script first if the host
matters to you — same URL, no `| sudo bash`:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/main/install.sh | less
```

To pin to an exact revision instead of whatever `main` is today, use a tag or
commit hash:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/main/install.sh \
  | sudo DUCKDNS_REF=<commit-sha> bash
```

Arguments go after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/main/install.sh \
  | sudo bash -s -- --uninstall
```

### From a checkout

Copy this directory to the box and run the installer as root:

```sh
sudo ./install.sh
```

Both paths install the script to `/usr/local/bin`, the units to
`/etc/systemd/system`, create `/etc/duckdns.env` from the template (never
overwriting an existing one), then `daemon-reload` and `enable --now` the timer.
They check for `curl` and `dig` first and print the apt line if either is
missing (`curl`, `dnsutils` — or `bind9-dnsutils` on newer releases).

```sh
sudo ./install.sh --uninstall   # stop timer, remove units + script, keep config
sudo ./install.sh --purge       # also delete /etc/duckdns.env
```

`--help`, `--uninstall` and `--purge` need no download; only the install path
fetches the repo tarball.

Manual equivalent, if you prefer to see every step:

```sh
sudo install -m 0755 duckdns-update.sh /usr/local/bin/duckdns-update.sh
sudo install -m 0600 duckdns.env.example /etc/duckdns.env
sudoedit /etc/duckdns.env                 # real domains + tokens
sudo install -m 0644 duckdns-update.service duckdns-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now duckdns-update.timer
```

## Verify

```sh
systemctl list-timers duckdns-update.timer
sudo systemctl start duckdns-update.service    # run once now
journalctl -u duckdns-update.service -n 20 --no-pager
```

Dry run without touching the API:

```sh
DUCKDNS_ENV_FILE=/etc/duckdns.env DUCKDNS_DRY_RUN=1 /usr/local/bin/duckdns-update.sh
```

Exit status is non-zero if the config is invalid, any DNS lookup failed, or any
update was rejected. Other groups are still processed after a failure.

## Notes

- `After=network-online.target` only blocks if a wait-online service is active
  (`systemctl is-enabled NetworkManager-wait-online` or
  `systemd-networkd-wait-online`). The script is idempotent, so a race just
  costs one no-op run.
- Logging goes to journald; no log file or rotation to manage.
- `Persistent=true` fires one catch-up run if the host was down across a
  scheduled tick.
- Tokens are never written to the log.
- Only IPv4 `A` records are managed. IPv6 would need a second lookup and the
  `ipv6=` parameter.
- To change the interval, edit `OnUnitActiveSec` in the timer and
  `systemctl daemon-reload`.

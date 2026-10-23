# duckdns

Keeps DuckDNS A records in sync with the host's public IP. Configuration is
file-driven (no hard-coded domains or tokens) and supports any number of
domains and tokens across multiple accounts.

Only records whose DNS answer differs from the public IP are updated, so the
script is safe to run on a short timer. There are no CLI arguments; everything
is controlled by config files and environment overrides.

## Files

| File | Purpose |
|------|---------|
| `duckdns-update.sh` | The updater. Reads groups from config files. |
| `duckdns-update.timer` | Runs the service every 15 min (calendar-based), with catch-up after downtime. |
| `example.env.example` | Example group config file. |
| `install.sh` | Installs/removes for user or system scope, generating the service unit. |

## Configuration

The updater reads every `*.env` file in a config directory. Each file defines
one group: one DuckDNS token plus the domains updated with it.

Defaults:

- **System scope**: `/etc/duckdns.d/` — e.g. `/etc/duckdns.d/mydomain.env`
- **User scope**: `~/.config/duckdns/` — e.g. `~/.config/duckdns/mydomain.env`

Override with `DUCKDNS_CONFIG_DIR`.

Each group file contains:

```sh
DUCKDNS_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
DUCKDNS_DOMAINS=mydomain,otherdomain
```

- Domains are written without the `.duckdns.org` suffix.
- A file missing either value is skipped with a warning, so the remaining groups
  still run.
- Backward compatibility: if the config directory yields no groups and
  `/etc/duckdns.env` exists, that file is read as a single group.
- The log says which file each group came from.

Optional overrides, from the environment or a group file: `DUCKDNS_IP_URL`,
`DUCKDNS_DNS_SERVER`, `DUCKDNS_UPDATE_URL`, `DUCKDNS_IP` (skip the lookup and
use this address), `DUCKDNS_DRY_RUN=1` (report only), `DUCKDNS_FORCE=1` (update
even when DNS already matches), `DUCKDNS_VERBOSE=1` (extra `DEBUG:` lines:
config dir, groups, IP source, per-domain lookup result, update request and
response). Tokens are never logged, verbose or not.

### Enabling verbose logging under systemd

The units pass the environment through untouched, so use a drop-in (it
survives `install.sh` upgrades, which rewrite the `.service` file):

```bash
mkdir -p ~/.config/systemd/user/duckdns-update.service.d
printf '[Service]\nEnvironment=DUCKDNS_VERBOSE=1\n' \
  > ~/.config/systemd/user/duckdns-update.service.d/verbose.conf
systemctl --user daemon-reload
```

For system scope use `/etc/systemd/system/duckdns-update.service.d/verbose.conf`
and `sudo systemctl daemon-reload`. Then read the output with
`journalctl --user-unit=duckdns-update.service -o cat` (for system scope use
`journalctl -u duckdns-update.service -o cat`). Remove the drop-in to go back
to the quiet log.

`--user-unit=` is not the same as `--user -u`: the former matches user-unit
entries in whatever journal is readable, the latter restricts journalctl to your
own `user-<uid>.journal` file. Hosts running journald with `SplitMode=none`
(no per-user journal file) only work with `--user-unit=`.

## Quick install

User scope, the default when not running as root:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/v1.2.1/install.sh | bash -s -- --user
```

System scope, needs root:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/v1.2.1/install.sh | sudo bash -s -- --system
```

Piping to a shell runs remote code, so read it first if the host matters —
same URL, without the `| bash`:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/v1.2.1/install.sh | less
```

To pin to an exact revision instead of whatever `main` is today, keep `main` in
the URL but set the ref in the environment of the `bash` on the right-hand side
of the pipe. It is an environment variable, not a CLI argument:

```sh
curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/main/install.sh \
  | DUCKDNS_REF=<tag-or-commit> bash -s -- --user

curl -fsSL https://raw.githubusercontent.com/plmeister/duckdns/main/install.sh \
  | sudo DUCKDNS_REF=<tag-or-commit> bash -s -- --system
```

From a checkout, `./install.sh` behaves the same and uses the local files.

What the installer does:

- Picks scope: `--system` or `--user`, defaulting by whether you are root.
- Installs `duckdns-update.sh` to `/usr/local/bin` (system) or `~/.local/bin` (user).
- Generates `duckdns-update.service` with the right `ExecStart` and
  `DUCKDNS_CONFIG_DIR`, and installs it with `duckdns-update.timer` into
  `/etc/systemd/system` or `~/.config/systemd/user`.
- Creates the config directory and drops `example.env` only if no `*.env` files
  exist; existing configs are never overwritten.
- Enables and starts the timer with `systemctl` or `systemctl --user`.
- Does **not** enable lingering. Without lingering a user manager only exists
  while you are logged in, so the timer runs nothing before login or after
  logout. Enable it yourself if that matters:

  ```sh
  loginctl enable-linger $USER
  loginctl show-user $USER -p Linger    # Linger=yes
  ```

Checks for `curl` and `dig` (only when systemd is present) and aborts with
`missing curl` or `missing dig` if either is absent. Install them with
`sudo apt install curl dnsutils` (`bind9-dnsutils` on newer releases).

`--help` needs no download. `--uninstall` and `--purge` still fetch the repo
tarball when piped, because the script can only see its own repo when it is run
from a file; run them from a checkout to stay offline.

## Uninstall

```sh
# stop timer, remove units and script, keep configs
./install.sh --user --uninstall

# same, and delete the config directory
./install.sh --user --purge
```

## Verify

User scope:

```sh
systemctl --user list-timers duckdns-update.timer
systemctl --user start duckdns-update.service
journalctl --user-unit=duckdns-update.service -n 20 --no-pager
```

Confirm the timer is actually armed (a wedged timer shows `elapsed` and no
next run, so nothing fires):

```sh
systemctl --user show duckdns-update.timer -p SubState,NextElapseUSecRealtime
# want: SubState=waiting  and a non-empty NextElapseUSecRealtime=
```

System scope:

```sh
systemctl list-timers duckdns-update.timer
sudo systemctl start duckdns-update.service
journalctl -u duckdns-update.service -n 20 --no-pager
```

Dry run, no API calls:

```sh
DUCKDNS_CONFIG_DIR=~/.config/duckdns DUCKDNS_DRY_RUN=1 ~/.local/bin/duckdns-update.sh
DUCKDNS_CONFIG_DIR=/etc/duckdns.d DUCKDNS_DRY_RUN=1 /usr/local/bin/duckdns-update.sh
```

Exit status is non-zero if any DNS lookup failed or any update was rejected.
Remaining groups are still processed after a failure.

## Notes

- `After=network-online.target` only blocks if a wait-online service is active
  (`systemctl is-enabled NetworkManager-wait-online` or
  `systemd-networkd-wait-online`). The script is idempotent, so a race just
  costs one no-op run.
- Logging goes to journald; no log file or rotation to manage.
- Log lines carry no timestamp of their own. Under systemd journald prefixes
  every entry, and two timestamps per line made the log harder to read. Manual
  runs therefore print bare messages; add one back with
  `./duckdns-update.sh | ts '%Y-%m-%d %H:%M:%S%z'` (moreutils) or `awk` if you
  want times in a terminal.
- `Persistent=true` fires one catch-up run if the host was down across a
  scheduled tick.
- Timing is calendar-based rather than `OnBootSec=` + `OnUnitActiveSec=`:
  in a *user* timer `OnBootSec` is measured from system boot, so any
  restart of the timer mid-session leaves it `active (elapsed)` with no
  next run scheduled.
- Tokens are never written to the log.
- Only IPv4 `A` records are managed. IPv6 would need a second lookup and the
  `ipv6=` parameter.
- To change the interval, edit `OnCalendar` in the timer and reload
  (`systemctl --user daemon-reload` or `sudo systemctl daemon-reload`).

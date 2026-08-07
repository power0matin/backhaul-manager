<div align="center">

# Backhaul Manager

**Safe, interactive installer and operations manager for [power0matin/Backhaul](https://github.com/power0matin/Backhaul) and [Musixal/Backhaul](https://github.com/Musixal/Backhaul)**

One script for both the Iran-side server and the foreign client, with profiles, source migration, verified backups, health metrics, rollback, and service management built in.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%205%2B-4EAA25?logo=gnu-bash&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20systemd-lightgrey)](#requirements)
[![Transports](https://img.shields.io/badge/transports-7-informational)](#transports)

[English](./README.md) • [فارسی](./README.fa.md)

</div>

---

Backhaul Manager is designed for reverse-tunnel deployments used with Xray, V2Ray, Marzban, 3x-ui/Sanaei, Hiddify, and similar services. It keeps the two Backhaul roles consistent while avoiding the most common setup mistakes: malformed TOML, invalid ports, mismatched transport settings, unsafe secret handling, broken upgrades, and manual systemd work.

## Features

| Feature | What it does |
| --- | --- |
| 🔁 **Both roles** | Configures either the Iran/server side or foreign/client side from the same script |
| 📦 **Selectable Backhaul source** | Pick `power0matin/Backhaul` (recommended) or the official `Musixal/Backhaul` upstream by number during setup |
| 🔄 **Source migration** | Migrate every managed profile between PowerMatin and Musixal with schema checks, downgrade guards, backup, restart verification, and automatic rollback |
| 🚚 **All upstream transports** | `tcp`, `tcpmux`, `udp`, `ws`, `wss`, `wsmux`, and `wssmux`; `wsmux` remains the recommended default |
| 🎛️ **Standard + Advanced modes** | Advanced setup adds Backhaul port ranges/mappings, safe/balanced/throughput auto-tuning, PROXY protocol, TCP UDP-over-tunnel, and fork-specific controls |
| 🧩 **Named profiles** | Run independent configs/services such as `backhaul-edge-1.service` while sharing one validated Backhaul binary/source |
| ✅ **Validated input** | Validates ports, versions, hosts, transport choices, required files, and rejects unsafe values before touching the installation |
| 🔐 **Safer secrets** | Generates a 48-character cryptographic token, hides token input, escapes TOML values, stores secrets as `0600`, and keeps the token out of run logs |
| 🛡️ **Transactional changes** | Backs up config/unit/binary state, writes files atomically, verifies the service, and rolls back after a failed install/reconfigure |
| ⬆️ **Safe multi-profile upgrades** | Downloads the correct architecture, validates it, snapshots the full installation, verifies every previously-running profile, and rolls everything back on failure |
| 💾 **Backup + host migration** | Full checksummed backups, hardened portable import/export, and guided SSH migration include all profiles, service state, binary, source state, and readable TLS material |
| 🩺 **Health + metrics** | Status, diagnostics, systemd resource/restart metrics, protected PowerMatin `/stats`, recent logs, and live logs are built in |
| 🛠️ **Global manager command** | Installs/updates a validated `backhaul-manager` command in `/usr/local/sbin` with downgrade protection |
| 🧹 **Targeted conflict cleanup** | Detects likely tunnel services and only allows selecting detected candidates, with a confirmation before disabling them |
| 🔥 **Firewall aware** | Detects active `ufw`/`firewalld` and prints the ports to allow; it never changes firewall policy itself |
| 🌐 **IPv4/IPv6/hostnames** | Client endpoints accept IPv4, IPv6, or DNS names; WebSocket transports can optionally use an edge/CDN host |
| 🧯 **Safer uninstall** | Removes the service/binary first and asks separately before permanently deleting config, credentials, and backups |
| 🤖 **CLI operations** | Common maintenance actions can be called directly with flags, making routine administration faster |

## Requirements

- Linux with `systemd`
- Bash 5+
- `x86_64`/AMD64 or `arm64`/AArch64
- Root access for install and service operations
- `curl`, `tar`, `systemctl`, `journalctl`, `ss`, `awk`, `grep`, `sed`, and standard GNU/coreutils tools
- `nc`/netcat is optional and is only used for client reachability probes
- `ssh` and `scp` are optional and only required for guided server-to-server migration; custom SSH ports/keys should be configured in `~/.ssh/config`
- `jq` is optional and prettifies PowerMatin `/stats` output when available
- TLS transports (`wss`, `wssmux`) require an existing certificate and private key on the server side

## Quick Start

If you are logged in as `root`, run the manager with one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh)
```

If you are not root, use:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh | sudo bash
```

`-f` makes HTTP errors fail instead of being executed, `-sS` keeps normal output quiet while still showing errors, and `-L` follows GitHub redirects.

> Do not prepend `sudo` to the process-substitution form (`sudo bash <(curl ...)`). `sudo` may close its `/dev/fd/...` descriptor. Use the pipe-to-sudo form above when privilege elevation is required.

To review the script before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh -o backhaul-manager.sh
chmod +x backhaul-manager.sh
sudo ./backhaul-manager.sh
```

## Interactive Manager

```text
  1) Configure Iran server
  2) Configure foreign client
  3) Status
  4) Diagnostics
  5) Restart service
  6) Start / stop service
  7) Backhaul maintenance
  8) Profiles
  9) Backup & migration
 10) Health & logs
 11) Manager install / update
 12) Uninstall / purge
  0) Exit
```

Re-running option 1 or 2 is safe for an existing managed installation: previous files are snapshotted first, new files are written atomically, and a failed service start triggers rollback.

During server or client setup, choose which Backhaul release source to install. Pressing Enter accepts the recommended fork:

```text
Backhaul source:
  1) power0matin/Backhaul [recommended]
  2) Musixal/Backhaul [official upstream]
Source [1]:
```

The selected source is saved with the managed installation, shown by Status, and reused by future upgrades. Because profiles share one Backhaul binary, changing source/version is an installation-wide maintenance operation rather than a per-profile change.

## Transports

The choices match the transport types currently exposed by Backhaul itself.

| Transport | Use case | Extra server input |
| --- | --- | --- |
| `wsmux` | Multiplexed WebSocket; good general default | none |
| `tcpmux` | Multiplexed TCP | none |
| `tcp` | Simple TCP transport | none |
| `ws` | WebSocket transport | none |
| `wssmux` | TLS-encrypted multiplexed WebSocket | certificate + private key |
| `wss` | TLS-encrypted WebSocket | certificate + private key |
| `udp` | UDP transport | none |

Standard mode accepts direct tunnel ports such as `443,2052,2082`. Advanced mode supports Backhaul rules such as `4000-4100`, `4000=5000`, `443=127.0.0.1:8443`, and bracketed IPv6 remote mappings, with control-port conflict validation.

For `ws`, `wss`, `wsmux`, and `wssmux`, the client can optionally set Backhaul's `edge_ip` value.

## Advanced Mode and Auto-Tuning

Standard mode keeps conservative, portable defaults and is recommended for most installations. Advanced mode offers three resource profiles: `safe`, `balanced`, and `throughput`; Auto chooses between them from CPU count and installed RAM.

Advanced mode also exposes only options known to exist in the selected release family. PowerMatin-specific bounded pool/UDP queue settings and authenticated loopback metrics are never written into a Musixal config. The Musixal v0.7.2 web monitor is intentionally kept disabled because that release cannot configure a loopback-only bind/auth policy. PowerMatin metrics bind to `127.0.0.1` and require generated or validated credentials.

## Profiles, Backups, and Migration

- The legacy/default profile remains `/root/backhaul/config.toml` + `backhaul.service` for backward compatibility.
- Named profiles live under `/root/backhaul/profiles/<name>/` and use `backhaul-<name>.service`.
- Existing root-level Backhaul configs such as `/root/backhaul/config-2087.toml` are auto-detected and listed as **legacy tunnels** instead of being silently omitted. Unrelated TOML files and timestamped `.bak.*` files are ignored.
- Legacy discovery is read-only. Use **Profiles → Adopt legacy tunnel** to explicitly convert a detected config into a native named profile; the Manager preserves a detected service's active/enabled state and rolls back if the replacement cannot be verified. If no service references the file, the original is retained and the adopted profile stays stopped until you start it.
- `*` means the profile currently selected for Manager actions, not the only running tunnel. Every managed profile reports its own `active`, `stopped`, `no-unit`, or `mismatch` service state.
- Service actions refuse `mismatch` rows, and shared binary/source upgrade, migration, and uninstall operations refuse to proceed while a detected legacy tunnel is still active outside profile management. This prevents Manager operations from silently restarting or replacing the wrong tunnel.
- Create, select, clone, and delete named profiles from the Profiles menu. TLS clones copy their certificate/key into the new profile so they do not depend on the original profile.
- A full backup captures every configured profile, service enable/active state, the shared binary/source, and readable TLS files. `CHECKSUMS` validates accidental corruption.
- Portable `.tar.gz` import rejects traversal paths, links/devices, excessive member counts, oversized compressed members, and excessive expanded data before root extraction. Bundles contain secrets and are not authenticated/signed, so import only bundles you trust.
- Server-to-server migration exports the same bundle, sends it over SSH, forces the remote copy to mode `0600`, and can run a verified restore remotely.
- Source migration checks all profiles before changing the shared binary. Moving PowerMatin → Musixal can explicitly remove only known fork-specific keys; unsafe Musixal web metrics are disabled during adaptation. Downgrades always require interactive confirmation.

## Direct CLI Operations

The interactive menu is the default, but routine maintenance does not require it:

```bash
sudo ./backhaul-manager.sh --status
sudo ./backhaul-manager.sh --diagnose
sudo ./backhaul-manager.sh --metrics
sudo ./backhaul-manager.sh --profile edge-1 --status
sudo ./backhaul-manager.sh --restart
sudo ./backhaul-manager.sh --start
sudo ./backhaul-manager.sh --stop
sudo ./backhaul-manager.sh --upgrade
sudo ./backhaul-manager.sh --migrate-source Musixal/Backhaul
sudo ./backhaul-manager.sh --compat power0matin/Backhaul
sudo ./backhaul-manager.sh --list-profiles
sudo ./backhaul-manager.sh --select-profile edge-1
sudo ./backhaul-manager.sh --backup
sudo ./backhaul-manager.sh --list-backups
sudo ./backhaul-manager.sh --export /root/backhaul-portable.tar.gz
sudo ./backhaul-manager.sh --import /root/backhaul-portable.tar.gz
sudo ./backhaul-manager.sh --restore-backup backup-YYYYMMDD-HHMMSS-label-PID
sudo ./backhaul-manager.sh --self-update
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
./backhaul-manager.sh --version
./backhaul-manager.sh --help
```

`--upgrade` defaults to the latest release from the selected Backhaul source. A pinned release tag can be supplied. Non-interactive `--migrate-source` deliberately refuses downgrades and configs that require adaptation; use the interactive migration flow when you want to explicitly approve either operation. Legacy Manager installs without source state are treated as Musixal installations.

## Files and Backups

| Path | Purpose |
| --- | --- |
| `/opt/backhaul/backhaul` | Installed Backhaul binary |
| `/root/backhaul/config.toml` | Active Backhaul config (`0600`) |
| `/root/backhaul/backhaul-info.txt` | Local connection/setup summary (`0600`) |
| `/root/backhaul/profiles/<name>/config.toml` | Named profile config (`0600`) |
| `/etc/systemd/system/backhaul.service` | Managed systemd unit |
| `/etc/systemd/system/backhaul-<name>.service` | Named profile systemd unit |
| `/var/lib/backhaul-manager/backups/` | Timestamped rollback snapshots |
| `/var/lib/backhaul-manager/backhaul-source` | Selected Backhaul release repository |
| `/var/lib/backhaul-manager/active-profile` | Currently selected profile |
| `/var/log/backhaul-manager/` | Per-run manager logs (`0600`) |
| `/usr/local/sbin/backhaul-manager` | Optional globally installed Manager command |

The web monitor is disabled in Standard mode (`web_port = 0`). PowerMatin Advanced mode can enable it safely on loopback with authentication.

## Safety Model

- Installation directories are created before config is written, so clean installs do not fail on a missing `/root/backhaul` directory.
- Token generation avoids pipelines that can fail under `set -o pipefail`.
- Custom tokens are entered without terminal echo and are TOML-escaped before being written.
- The token is shown only on the terminal and in the root-only info/config files; it is not printed into the manager run log.
- Release downloads use HTTPS, validate the gzip/tar structure, extract only the expected `backhaul` member, execute its `-v` sanity check, and verify pinned-version matches.
- Binary replacement and config writes use temporary files plus `mv` instead of partially overwriting live files.
- A failed configure/start restores the previous config, systemd unit, binary, service state, and enablement state where applicable.
- Full upgrade/source migration snapshots all profiles and verifies all services that were active before the operation before declaring success.
- Portable restore validates a checksummed backup tree and regenerates trusted systemd unit templates instead of trusting unit files from the archive.
- Import limits archive type, path, member count, individual size, compressed size, and total expanded size before extraction as root.
- Manager self-update downloads only the repository's HTTPS `main` script, caps its size, validates Bash syntax and a single semantic Manager version declaration, and refuses downgrades. It is not a cryptographically signed update channel.
- Uninstall preserves config/backups unless a second purge confirmation is explicitly accepted.
- Firewall rules are never modified automatically.

## Configuration Defaults

The manager uses conservative defaults close to the upstream Backhaul configuration model:

| Setting | Default |
| --- | --- |
| Control port | `8080` |
| Tunnel ports | `2052,2082,8002,443` |
| Transport | `wsmux` |
| Backhaul source | `power0matin/Backhaul` (recommended) |
| `keepalive_period` | `20` (non-UDP) |
| Server `heartbeat` | `20` |
| `channel_size` | `2048` |
| `connection_pool` | `8` |
| `mux_con` | `8` (mux server transports) |
| `mux_version` | `1` (mux transports) |
| `web_port` | `0` (disabled) |
| `log_level` | `info` |

Advanced tuning adjusts channel/pool/mux buffer/concurrency values. `safe` reduces resource use, `balanced` matches the defaults above, and `throughput` raises concurrency/buffer limits for larger hosts.

Client configs intentionally do not write a `heartbeat` key because current Backhaul `ClientConfig` does not expose that field.

## Troubleshooting

Run the built-in health check first:

```bash
sudo ./backhaul-manager.sh --diagnose
```

Then inspect logs if needed:

```bash
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
```

Common causes of a failed setup are:

- the Iran control port is blocked by a firewall/security group;
- another process already owns a configured port;
- the server and client use different tokens, transports, or control ports;
- a TLS transport points to a missing/unreadable certificate or key;
- the requested Backhaul release tag or architecture has no matching upstream asset.

## Development

Local checks:

```bash
bash -n backhaul-manager.sh tests/test.sh
shellcheck backhaul-manager.sh tests/test.sh
bash tests/test.sh
```

GitHub Actions runs the same syntax, ShellCheck, and helper-test checks for pushes and pull requests.

## Roadmap

- [x] All seven upstream Backhaul transports
- [x] Safe token generation and secret handling
- [x] Transactional config/binary changes with rollback
- [x] Status, diagnostics, logs, service control, and upgrade commands
- [x] CLI maintenance operations
- [x] Automated syntax/lint/helper tests
- [x] First-class advanced port ranges and mapping rules
- [x] Standard/advanced configuration with resource-aware tuning
- [x] Multiple named tunnel profiles/services
- [x] Transactional PowerMatin ↔ Musixal source migration with compatibility checks
- [x] Full backup/restore, portable import/export, and guided SSH host migration
- [x] Health metrics and protected PowerMatin `/stats` integration
- [x] Global Manager install/self-update command
- [ ] Fully unattended server/client configuration flags

## Contributing

Issues and pull requests are welcome. For larger behavioral changes, opening an issue first helps keep the manager aligned with Backhaul's upstream configuration model. See [CHANGELOG.md](./CHANGELOG.md) for release history.

## License

MIT — see [LICENSE](./LICENSE). Backhaul itself is a separate upstream project with its own license.

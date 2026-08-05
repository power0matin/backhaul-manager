<div align="center">

# Backhaul Manager

**Safe, interactive installer and operations manager for [Musixal/Backhaul](https://github.com/Musixal/Backhaul)**

One script for both the Iran-side server and the foreign client, with install, upgrade, health checks, logs, rollback, and service management built in.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%205%2B-4EAA25?logo=gnu-bash&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20systemd-lightgrey)](#requirements)
[![Transports](https://img.shields.io/badge/transports-7-informational)](#transports)

[English](./README.md) • [فارسی](./README.fa.md)

</div>

---

Backhaul Manager is designed for reverse-tunnel deployments used with Xray, V2Ray, Marzban, 3x-ui/Sanaei, Hiddify, and similar services. It keeps the two Backhaul roles consistent while avoiding the most common setup mistakes: malformed TOML, invalid ports, mismatched transport settings, unsafe secret handling, broken upgrades, and manual systemd work.

## Features

| Feature                          | What it does                                                                                                                                        |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| 🔁 **Both roles**                | Configures either the Iran/server side or foreign/client side from the same script                                                                  |
| 🚚 **All upstream transports**   | `tcp`, `tcpmux`, `udp`, `ws`, `wss`, `wsmux`, and `wssmux`; `wsmux` remains the recommended default                                                 |
| ✅ **Validated input**           | Validates ports, versions, hosts, transport choices, required files, and rejects unsafe values before touching the installation                     |
| 🔐 **Safer secrets**             | Generates a 48-character cryptographic token, hides token input, escapes TOML values, stores secrets as `0600`, and keeps the token out of run logs |
| 🛡️ **Transactional changes**     | Backs up config/unit/binary state, writes files atomically, verifies the service, and rolls back after a failed install/reconfigure                 |
| ⬆️ **Safe upgrades**             | Downloads the correct architecture, validates the archive and binary version, installs atomically, and rolls back a bad upgrade                     |
| 🩺 **Operations toolkit**        | Status, diagnostics, start/stop/restart, recent logs, live logs, and upgrades are available without hand-written commands                           |
| 🧹 **Targeted conflict cleanup** | Detects likely tunnel services and only allows selecting detected candidates, with a confirmation before disabling them                             |
| 🔥 **Firewall aware**            | Detects active `ufw`/`firewalld` and prints the ports to allow; it never changes firewall policy itself                                             |
| 🌐 **IPv4/IPv6/hostnames**       | Client endpoints accept IPv4, IPv6, or DNS names; WebSocket transports can optionally use an edge/CDN host                                          |
| 🧯 **Safer uninstall**           | Removes the service/binary first and asks separately before permanently deleting config, credentials, and backups                                   |
| 🤖 **CLI operations**            | Common maintenance actions can be called directly with flags, making routine administration faster                                                  |

## Requirements

- Linux with `systemd`
- Bash 5+
- `x86_64`/AMD64 or `arm64`/AArch64
- Root access for install and service operations
- `curl`, `tar`, `systemctl`, `journalctl`, `ss`, `awk`, `grep`, `sed`, and standard GNU/coreutils tools
- `nc`/netcat is optional and is only used for client reachability probes
- TLS transports (`wss`, `wssmux`) require an existing certificate and private key on the server side

## Quick Start

Downloading first is the easiest way to review exactly what will run:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh -o backhaul-manager.sh
chmod +x backhaul-manager.sh
sudo ./backhaul-manager.sh
```

Direct interactive execution also works because prompts read from `/dev/tty`:

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh | sudo bash
```

> Avoid `sudo bash <(curl ...)`. `sudo` may close the file descriptor backing process substitution, producing `/dev/fd/...: No such file or directory`. Use one of the forms above instead.

## Interactive Manager

```text
  1) Configure Iran server
  2) Configure foreign client
  3) Status
  4) Diagnostics
  5) Restart service
  6) Start / stop service
  7) Upgrade Backhaul
  8) Recent logs
  9) Follow live logs
 10) Uninstall / purge
  0) Exit
```

Re-running option 1 or 2 is safe for an existing managed installation: previous files are snapshotted first, new files are written atomically, and a failed service start triggers rollback.

## Transports

The choices match the transport types currently exposed by Backhaul itself.

| Transport | Use case                                    | Extra server input        |
| --------- | ------------------------------------------- | ------------------------- |
| `wsmux`   | Multiplexed WebSocket; good general default | none                      |
| `tcpmux`  | Multiplexed TCP                             | none                      |
| `tcp`     | Simple TCP transport                        | none                      |
| `ws`      | WebSocket transport                         | none                      |
| `wssmux`  | TLS-encrypted multiplexed WebSocket         | certificate + private key |
| `wss`     | TLS-encrypted WebSocket                     | certificate + private key |
| `udp`     | UDP transport                               | none                      |

The manager currently accepts a list of direct tunnel ports such as `443,2052,2082`. Advanced Backhaul port-mapping/range rules can still be configured manually in `config.toml` if needed.

For `ws`, `wss`, `wsmux`, and `wssmux`, the client can optionally set Backhaul's `edge_ip` value.

## Direct CLI Operations

The interactive menu is the default, but routine maintenance does not require it:

```bash
sudo ./backhaul-manager.sh --status
sudo ./backhaul-manager.sh --diagnose
sudo ./backhaul-manager.sh --restart
sudo ./backhaul-manager.sh --start
sudo ./backhaul-manager.sh --stop
sudo ./backhaul-manager.sh --upgrade
sudo ./backhaul-manager.sh --upgrade v0.7.2
sudo ./backhaul-manager.sh --logs 100
sudo ./backhaul-manager.sh --follow-logs
./backhaul-manager.sh --version
./backhaul-manager.sh --help
```

`--upgrade` defaults to the latest upstream Backhaul release. A pinned release tag may be supplied when reproducibility matters.

## Files and Backups

| Path                                   | Purpose                                 |
| -------------------------------------- | --------------------------------------- |
| `/opt/backhaul/backhaul`               | Installed Backhaul binary               |
| `/root/backhaul/config.toml`           | Active Backhaul config (`0600`)         |
| `/root/backhaul/backhaul-info.txt`     | Local connection/setup summary (`0600`) |
| `/etc/systemd/system/backhaul.service` | Managed systemd unit                    |
| `/var/lib/backhaul-manager/backups/`   | Timestamped rollback snapshots          |
| `/var/log/backhaul-manager/`           | Per-run manager logs (`0600`)           |

The generated web dashboard is disabled by default (`web_port = 0`) to avoid unintentionally exposing another listening service. Enable it manually only when you need it and understand the exposure.

## Safety Model

- Installation directories are created before config is written, so clean installs do not fail on a missing `/root/backhaul` directory.
- Token generation avoids pipelines that can fail under `set -o pipefail`.
- Custom tokens are entered without terminal echo and are TOML-escaped before being written.
- The token is shown only on the terminal and in the root-only info/config files; it is not printed into the manager run log.
- Release downloads use HTTPS, validate the gzip/tar structure, extract only the expected `backhaul` member, execute its `-v` sanity check, and verify pinned-version matches.
- Binary replacement and config writes use temporary files plus `mv` instead of partially overwriting live files.
- A failed configure/start restores the previous config, systemd unit, binary, service state, and enablement state where applicable.
- Uninstall preserves config/backups unless a second purge confirmation is explicitly accepted.
- Firewall rules are never modified automatically.

## Configuration Defaults

The manager uses conservative defaults close to the upstream Backhaul configuration model:

| Setting            | Default                     |
| ------------------ | --------------------------- |
| Control port       | `8080`                      |
| Tunnel ports       | `2052,2082,8002,443`        |
| Transport          | `wsmux`                     |
| `keepalive_period` | `20` (non-UDP)              |
| Server `heartbeat` | `20`                        |
| `channel_size`     | `2048`                      |
| `connection_pool`  | `8`                         |
| `mux_con`          | `8` (mux server transports) |
| `mux_version`      | `1` (mux transports)        |
| `web_port`         | `0` (disabled)              |
| `log_level`        | `info`                      |

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
- [ ] First-class advanced port ranges and mapping rules
- [ ] Fully unattended server/client configuration flags
- [ ] Multiple named tunnel profiles/services on the same host

## Contributing

Issues and pull requests are welcome. For larger behavioral changes, opening an issue first helps keep the manager aligned with Backhaul's upstream configuration model. See [CHANGELOG.md](./CHANGELOG.md) for release history.

## License

MIT — see [LICENSE](./LICENSE). Backhaul itself is a separate upstream project with its own license.

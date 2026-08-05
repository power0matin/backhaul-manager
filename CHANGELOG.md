# Changelog

[![Keep a Changelog](https://img.shields.io/badge/Keep%20a%20Changelog-1.1.0-orange)](https://keepachangelog.com/en/1.1.0/)
[![Semantic Versioning](https://img.shields.io/badge/SemVer-2.0.0-blue)](https://semver.org/)

All notable changes to **Backhaul Manager** are documented in this file.

## [Unreleased]

### Added

- Full transport selection for `tcp`, `tcpmux`, `udp`, `ws`, `wss`, `wsmux`, and `wssmux`, including TLS certificate/key prompts and optional WebSocket `edge_ip` support where applicable.
- Direct operations CLI: `--status`, `--diagnose`, `--start`, `--stop`, `--restart`, `--upgrade`, `--logs`, `--follow-logs`, `--help`, and `--version`.
- Built-in status and diagnostic views, live/recent journal access, service controls, and in-place Backhaul upgrades.
- Transactional snapshots and rollback for config, systemd unit, and binary changes when a reconfiguration or upgrade fails.
- IPv4, IPv6, and hostname handling for client endpoints.
- Automated Bash syntax, ShellCheck, and helper tests through GitHub Actions.

### Changed

- Reworked the interactive menu into a full operations manager instead of an install/uninstall-only workflow.
- Backhaul downloads now happen in a private temporary directory, extract only the expected binary, validate `backhaul -v`, verify pinned versions, and replace the live binary atomically.
- Config files are written through temporary files and atomically moved into place.
- Old-service cleanup now only accepts numbered services from the detected tunnel-related candidate list and asks for confirmation before disabling them.
- systemd now waits for `network-online.target`, uses `Restart=on-failure`, and applies `UMask=0077`.
- Backhaul's web interface is disabled by default with `web_port = 0` instead of exposing ports 2060/2061 automatically.
- Uninstall preserves config/backups by default and requires a second confirmation for a permanent purge.
- Run logs moved to `/var/log/backhaul-manager/` and are created with mode `0600`.

### Fixed

- Create `/root/backhaul` before first-time config writes; the previous clean-install path could fail because the directory did not exist.
- Replace the token-generation pipelines that could fail under `set -o pipefail` when `head` closed the pipe early.
- Validate and normalize control/tunnel ports, reject control-port collisions, deduplicate tunnel ports, and validate version/host input.
- Escape custom token and address values before writing TOML instead of interpolating unchecked input.
- Remove the unsupported `heartbeat` key from generated client config; the current upstream `ClientConfig` does not define that field.
- Correctly bracket IPv6 remote endpoints.
- Roll back service enablement/active state as well as files after a failed configuration.

### Security

- Token prompts no longer echo typed secrets.
- Generated tokens use 24 cryptographically random bytes encoded as 48 hexadecimal characters without a `pipefail`-sensitive truncation pipeline.
- Tokens are no longer printed through the manager's tee-based run logger; final secret output is written directly to the controlling TTY.
- Config, info, backup directory, and run-log permissions are restrictive by default.
- User input that reaches TOML or release URLs is validated/escaped before use.

## [1.0.0] - 2026-08-04

Initial public release.

### Added

- Single unified, fully interactive script covering both server (Iran) and client (kharej) roles for Backhaul reverse tunnels.
- Interactive prompts with sensible defaults for control port, tunnel ports, Backhaul version, and token — Enter accepts the default.
- Automatic secure token generation (server side) when the token prompt is left empty.
- Detection and listing of currently running `systemd` services, with heuristic highlighting of likely old tunnel services (Paqet, GOST, Chisel, Rathole, wstunnel, frp, V2Ray/Xray, sing-box, Hysteria, Shadowsocks, WireGuard, OpenVPN, nps, ngrok, udp2raw, Ligolo), and an interactive prompt to stop/disable one or more of them by number or exact name (comma-separated).
- Automatic architecture detection (`x86_64` / `arm64`) and download of the matching Backhaul release asset, with tarball integrity validation before extraction.
- Config backup (timestamped) before any overwrite of an existing `config.toml`.
- Post-install verification: confirms the systemd service is active, checks that all configured ports are listening (server), and performs a connectivity test to the Iran server (client).
- Firewall awareness: detects active `ufw` or `firewalld` and prints the exact commands needed to open the relevant ports (does not modify firewall rules automatically).
- Built-in uninstall option that removes the binary, config directory, and systemd unit.
- All prompts read from `/dev/tty`, so the script works correctly even when piped directly via `curl -fsSL ... | bash`.
- Per-run log file at `/var/log/backhaul-manager-<timestamp>.log`.
- Local info file (`/root/backhaul/backhaul-info.txt`, `chmod 600`) summarizing the generated token, ports, and IP for quick reference.
- English and Persian README documentation.

### Security

- Config and info files are written with `chmod 600`.
- No secrets are hardcoded; the token is either user-supplied or randomly generated per run.

### Planned

See the [Roadmap](./README.md#roadmap) for `tcp`, `tcpmux`, `ws`/`wss`, `udp` transport support and a non-interactive/flag-driven mode.

[1.0.0]: https://github.com/power0matin/backhaul-manager/releases/tag/v1.0.0
[Unreleased]: https://github.com/power0matin/backhaul-manager/compare/v1.0.0...HEAD

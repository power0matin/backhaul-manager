# Changelog

[![Keep a Changelog](https://img.shields.io/badge/Keep%20a%20Changelog-1.1.0-orange)](https://keepachangelog.com/en/1.1.0/)
[![Semantic Versioning](https://img.shields.io/badge/SemVer-2.0.0-blue)](https://semver.org/)

All notable changes to **Backhaul Manager** are documented in this file.

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

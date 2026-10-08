# Changelog

[![Keep a Changelog](https://img.shields.io/badge/Keep%20a%20Changelog-1.1.0-orange)](https://keepachangelog.com/en/1.1.0/)
[![Semantic Versioning](https://img.shields.io/badge/SemVer-2.0.0-blue)](https://semver.org/)

All notable changes to **Backhaul Manager** are documented in this file.

## [Unreleased]

### Added

- Manager v3.1.0 operation lock (`flock`) so concurrent interactive/CLI writers cannot mutate the shared Backhaul state at the same time.
- Explicit current-source recording (`--set-source` and **Backhaul maintenance → Record current source**) for installations whose existing binary provenance is not recorded.
- PID-aware tunnel health verification: server health requires the configured listener to belong to the current service PID, while client health tracks the live peer/control-channel state instead of accepting `systemctl active` alone.
- Schema-2 backups that include detected root-level legacy configs, their restorable service state, and TLS material in addition to managed profiles.
- Failure-injection regressions for systemd enable/stop failures, effective `ExecStart` overrides, transaction rollback, stale client control channels, TOML comments/literal strings, and managed+legacy backup validation.
- Automatic discovery of valid root-level legacy Backhaul TOML configs (for example `config-2087.toml`) plus explicit, rollback-aware adoption into native named profiles.
- Manager v3 operations suite with Standard/Advanced configuration modes and resource-aware `safe`, `balanced`, and `throughput` tuning profiles.
- First-class advanced Backhaul port rules including ranges, local remaps, remote host/IPv4 mappings, and bracketed IPv6 targets with control-port conflict checks.
- Multiple named profiles with independent root-only config/info files and `backhaul-<profile>.service` units, plus select/create/clone/delete operations.
- Transactional migration between `power0matin/Backhaul` and `Musixal/Backhaul`, including all-profile compatibility checks, explicit downgrade/adaptation approval, service verification, and full rollback.
- Release-specific config compatibility engine for Musixal v0.7.2 and PowerMatin v0.8.0, including safe removal of known fork-only options when explicitly migrating to Musixal.
- Full-installation backups covering all profiles, shared binary/source state, service enable/active state, and readable TLS certificate/key material.
- Checksummed portable backup export/import plus guided server-to-server migration over SSH.
- Health/metrics view with systemd PID, memory, task, restart and optional process metrics, plus loopback `/stats` integration.
- Optional authenticated loopback web metrics for PowerMatin configurations; Musixal v0.7.2 metrics stay disabled because that release cannot configure a safe loopback bind/auth policy.
- Optional global `/usr/local/sbin/backhaul-manager` install/self-update command with syntax/version validation and downgrade protection.
- CLI operations for metrics, profiles, compatibility, source migration, backup/list/export/import/restore, and Manager self-update.
- Numbered Backhaul release-source selection during server/client setup, with `power0matin/Backhaul` as the recommended default and `Musixal/Backhaul` as the official upstream option.
- Persistent Backhaul source state so Status reports the selected repository and later upgrades reuse it.
- Full transport selection for `tcp`, `tcpmux`, `udp`, `ws`, `wss`, `wsmux`, and `wssmux`, including TLS certificate/key prompts and optional WebSocket `edge_ip` support where applicable.
- Direct operations CLI: `--status`, `--diagnose`, `--start`, `--stop`, `--restart`, `--upgrade`, `--logs`, `--follow-logs`, `--help`, and `--version`.
- Built-in status and diagnostic views, live/recent journal access, service controls, and in-place Backhaul upgrades.
- Transactional snapshots and rollback for config, systemd unit, and binary changes when a reconfiguration or upgrade fails.
- IPv4, IPv6, and hostname handling for client endpoints.
- Automated Bash syntax, ShellCheck, and helper tests through GitHub Actions.

### Changed

- Bumped the Manager runtime version to `3.1.0` with lifecycle, transaction, source-provenance, and legacy-backup hardening.
- Missing source metadata is now reported as `unknown` instead of being guessed as `Musixal/Backhaul`; source-dependent upgrades require an explicitly recorded source.
- Upgrade/source migration now stage the candidate binary/config set before cutover, stop each previously-active managed service once, and require tunnel-level health before committing source/version state.
- Shared-binary maintenance now blocks on any detected legacy tunnel, including stopped ones, until it is adopted into profile management.
- Effective systemd `ExecStart` (including drop-in overrides) now takes precedence over stale static unit contents when determining service/config ownership.
- Removed the old heuristic tunnel-service stop/disable prompt from configure paths; Manager now mutates only services it can map to a managed/explicitly adopted Backhaul config.
- Backhaul upgrades now snapshot the complete managed installation and restart/verify every profile that was active before the shared binary changed.
- Named-profile TLS clones now copy cert/key material into the cloned profile instead of depending on the source profile's paths.
- Portable restore validates saved unit command/config ownership and rejects executable/environment hooks that are unsafe to restore as root; included TLS files are relocated into root-only managed directories.
- Portable archive validation now caps compressed, per-member, and total expanded sizes in addition to validating member paths/types/count.
- Remote migration forces the transferred secret bundle to mode `0600` before offering remote restore.
- Version downgrade checks now use SemVer precedence, including prerelease identifiers and build metadata, instead of GNU version sort behavior.
- Reworked the interactive menu into a full operations manager instead of an install/uninstall-only workflow.
- Backhaul downloads now happen in a private temporary directory, extract only the expected binary, validate `backhaul -v`, verify pinned versions, and replace the live binary atomically.
- Config files are written through temporary files and atomically moved into place.
- systemd now waits for `network-online.target`, uses `Restart=on-failure`, and applies `UMask=0077`.
- Backhaul's web interface is disabled by default with `web_port = 0` instead of exposing ports 2060/2061 automatically.
- Uninstall preserves config/backups by default and requires a second confirmation for a permanent purge.
- Run logs moved to `/var/log/backhaul-manager/` and are created with mode `0600`.
- Interactive actions now clear and redraw the full banner/menu after the user presses Enter, without writing terminal-control sequences into run logs.

### Fixed

- Stop/disable/daemon-reload failures can no longer be masked by Bash conditional `errexit` semantics during configure, service actions, profile deletion, uninstall, backup restore, upgrade, or source migration.
- Interrupting an active transactional operation with `SIGINT`/`SIGTERM` now invokes its rollback handler; legacy adoption commits before archiving the old config so rollback can never reference a path already moved away.
- Full restore now checks every filesystem/systemd mutation explicitly instead of continuing after a failed write/remove while called from a conditional context.
- Legacy/profile discovery and service actions now honor effective systemd `ExecStart` and require the executable itself to be `/opt/backhaul/backhaul`, preventing config-path-only false ownership matches.
- TOML scalar/role parsing now handles inline comments and single-quoted literal strings without truncating `#` characters inside quoted data.
- Expected compatibility failures no longer emit a misleading global "unexpected error" banner.
- Profile create/clone/delete refuses systemd-unit ownership collisions instead of overwriting or deleting an unrelated existing unit.
- Source upgrade now rejects a resolved release older than the installed Backhaul version unless an explicit interactive downgrade is approved.
- Allow explicitly approved source migration to safely remove known server-only keys such as legacy `heartbeat` from client configs instead of aborting adaptation.
- Validate backup integrity independently from source-schema compatibility so a byte-for-byte rollback snapshot remains restorable even when a running legacy config contains decoder-ignored keys.
- Validate every newly created backup before reporting success, and remove an incomplete snapshot if its structure or checksums fail verification.
- Stage all profile adaptations before committing any of them, reducing partial-config mutation risk during multi-profile source migration.
- Resolve ShellCheck findings in legacy discovery, resource-aware tuning, profile validation, and interactive service controls without suppressing diagnostics.
- Stop treating the selected profile as the only tunnel: profile rows now report their own service state and flag a systemd unit whose `ExecStart` points at a different config as `mismatch`.
- Include additional valid root-level tunnel configs in Profiles and `--list-profiles` instead of showing only `/root/backhaul/config.toml`.
- Refuse service/config-mismatched actions and shared binary/source changes (upgrade, source migration, or uninstall) that could disrupt an active legacy tunnel not yet covered by profile rollback.
- Make the symlink-security regression portable to Git Bash/Windows: Linux still verifies rejection with a real symlink, while filesystems that cannot create one report an explicit skip instead of a false failure.
- Force LF line endings for shell scripts, CI YAML, and Markdown so Windows checkouts cannot turn executable Bash files into CRLF files.
- Fix a backup payload condition that incorrectly mixed a file test into Bash arithmetic and could break real backup creation.
- Fix PowerMatin → Musixal sanitization so web bind/auth keys are actually removed while `web_port` is forced to `0`.
- Prevent restore from recreating an empty stale named-profile directory from the pre-restore active context.
- Make profile cloning transactional when unit generation, daemon reload, or active-profile persistence fails.
- When deleting the active named profile, select another configured profile when available instead of leaving an unconfigured default context.
- Avoid redundant binary snapshots during downloads; configuration and full-operation rollback already own the required snapshots.
- Create `/root/backhaul` before first-time config writes; the previous clean-install path could fail because the directory did not exist.
- Replace the token-generation pipelines that could fail under `set -o pipefail` when `head` closed the pipe early.
- Validate and normalize control/tunnel ports, reject control-port collisions, deduplicate tunnel ports, and validate version/host input.
- Escape custom token and address values before writing TOML instead of interpolating unchecked input.
- Remove the unsupported `heartbeat` key from generated client config; the current upstream `ClientConfig` does not define that field.
- Correctly bracket IPv6 remote endpoints.
- Roll back service enablement/active state as well as files after a failed configuration.
- Make the entrypoint guard safe under `set -u` when the script is executed from stdin (`curl ... | sudo bash`) and `BASH_SOURCE[0]` is unset.

### Security

- Portable restore rejects saved service units with additional executable hooks or environment injection, and imported archives are copied into a private staging file before validation/extraction to close validation/extraction races.
- Remote SSH migration now allocates the destination bundle with remote `mktemp` rather than using a predictable filename.
- Portable imports reject absolute/traversal paths, symlinks, hardlinks/devices, excessive members, oversized members, oversized compressed archives, and excessive expanded data before root extraction.
- Imported backup trees are checksum-verified, staged with root-only permissions, and saved systemd units must pass strict Backhaul executable/config ownership checks before installation.
- PowerMatin web metrics bind to `127.0.0.1` with validated/generated credentials; Musixal v0.7.2 metrics are not exposed automatically.
- Manager and Backhaul downloads use HTTPS-only curl policy, timeouts/retries, and download size limits; Manager self-update validates syntax without pre-executing the downloaded script.
- Remote migration validates SSH targets, keeps options in SSH config instead of user-controlled command arguments, and protects transferred backup permissions.
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

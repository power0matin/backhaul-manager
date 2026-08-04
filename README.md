<div align="center">

# Backhaul Manager

**Interactive installer & manager for [Backhaul](https://github.com/Musixal/Backhaul) reverse tunnels**
One script for both the Iran-side server and the foreign (kharej) server.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%205%2B-4EAA25?logo=gnu-bash&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20systemd-lightgrey)](#requirements)
[![Transport](https://img.shields.io/badge/transport-wsmux-informational)](#roadmap)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#contributing)

[English](./README.md) • [فارسی](./README.fa.md)

</div>

---

Backhaul reverse tunnel manager for Xray, V2Ray, Marzban, 3x-ui/Sanaei, and Hiddify deployments running between an Iran-side server and a foreign (kharej) relay. Supports the **wsmux** transport today, with **tcp, tcpmux, ws, and udp** on the roadmap.

## Table of Contents

- [Why](#why)
- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Configuration Reference](#configuration-reference)
- [Roadmap](#roadmap)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Related Projects](#related-projects)
- [Contributing](#contributing)
- [Star History](#star-history)
- [License](#license)

## Why

Setting up Backhaul by hand means SSH-ing into two different servers, hand-editing two different `config.toml` files, keeping a shared token in sync, writing your own systemd unit, remembering to kill whatever old tunnel (Paqet, GOST, Chisel...) is still holding the port, and hoping you didn't typo the IP.

**Backhaul Manager turns all of that into one script and a handful of prompts** — same tool, same UX, on either side of the tunnel.

## Features

|                               |                                                                                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 🔁 **One script, both roles** | Interactively choose Iran/server or kharej/client mode — no separate scripts to keep in sync                                                                                                                             |
| ⌨️ **Sensible defaults**      | Every prompt has a working default; press Enter to accept it, or type your own value                                                                                                                                     |
| 🔐 **Auto-generated token**   | Leave the token prompt empty on the server side and a random 40-character token is generated for you                                                                                                                     |
| 🧹 **Old-tunnel cleanup**     | Scans running `systemd` services, flags likely old tunnels (Paqet, GOST, Chisel, Rathole, wstunnel, frp, V2Ray/Xray, sing-box, Hysteria, WireGuard, OpenVPN, ngrok...), and lets you stop/disable them by number or name |
| 💾 **Safe by default**        | Backs up any existing `config.toml` before overwriting, validates the downloaded archive before extracting, verifies the service actually started before declaring success                                               |
| 🔥 **Firewall aware**         | Detects an active `ufw`/`firewalld` and prints the exact commands to open the ports it configured — never changes firewall rules on its own                                                                              |
| 📡 **`curl \| bash` ready**   | All prompts read from `/dev/tty`, so piping the script straight from `curl` still works interactively                                                                                                                    |
| 🗑️ **Built-in uninstall**     | Removes the binary, config, and systemd unit cleanly in one menu option                                                                                                                                                  |
| 📝 **Full run log**           | Every execution is logged to `/var/log/backhaul-manager-<timestamp>.log`                                                                                                                                                 |

## Requirements

- A systemd-based Linux distribution (Ubuntu, Debian, CentOS, etc.), `x86_64` or `arm64`
- Root access (`sudo`)
- `curl`, `tar`, `systemctl`, `ss` (from `iproute2`) — the script checks for these and tells you what's missing
- `nc` (netcat) — optional, only used for the client-side connectivity test

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh -o backhaul-manager.sh
chmod +x backhaul-manager.sh
sudo ./backhaul-manager.sh
```

Or run it directly without saving the file:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/power0matin/backhaul-manager/main/backhaul-manager.sh)
```

## How It Works

The script opens a menu:

```
1) Install/configure as the Iran server (Server side)
2) Install/configure as the kharej server (Client side)
3) Fully remove Backhaul from this server (Uninstall)
0) Exit
```

**Option 1 — Iran server** asks for the control port, tunnel ports, a shared token (or auto-generates one), and the Backhaul version. It then lists running services so you can retire an old tunnel, downloads Backhaul, writes `/root/backhaul/config.toml`, installs the systemd unit, starts it, and verifies every configured port is actually listening.

**Option 2 — kharej/client** asks for the Iran server's IP, control port, the same shared token, and the Backhaul version. It installs, starts the service, and runs a connectivity test back to the Iran server.

**Option 3 — Uninstall** cleanly removes the service, binary, and config from whichever server you run it on.

All generated values (token, ports, IP) are also saved to `/root/backhaul/backhaul-info.txt` (`chmod 600`) so you don't have to scroll back through the terminal.

## Configuration Reference

Values the script writes into `config.toml`, with the prompts that control them:

| Field                           | Side        | Prompted?         | Default                           |
| ------------------------------- | ----------- | ----------------- | --------------------------------- |
| `bind_addr` / `remote_addr`     | both        | control port + IP | `8080`                            |
| `transport`                     | both        | fixed for now     | `wsmux`                           |
| `token`                         | both        | yes               | auto-generated (server)           |
| `ports`                         | server only | yes               | `2052,2082,8002,443`              |
| `keepalive_period`, `heartbeat` | both        | no                | `20`                              |
| `mux_con`                       | server      | no                | `8`                               |
| `connection_pool`               | client      | no                | `8`                               |
| `nodelay`                       | both        | no                | `true`                            |
| `web_port`                      | both        | no                | `2060` (server) / `2061` (client) |
| `log_level`                     | both        | no                | `info`                            |

Values not exposed as prompts are tuned defaults suitable for most setups; edit `/root/backhaul/config.toml` directly if you need to fine-tune mux/buffer sizes.

## Roadmap

- [x] `wsmux` transport (server + client)
- [x] Auto token generation
- [x] Old-service detection & cleanup
- [x] Built-in uninstall
- [ ] `tcp` transport
- [ ] `tcpmux` transport
- [ ] `ws` / `wss` transport
- [ ] `udp` transport
- [ ] Non-interactive / flag-driven mode for automated deployments
- [ ] Multi-port-group profiles

Have a transport or feature you need? [Open an issue](https://github.com/power0matin/backhaul-manager/issues) or a PR.

## Troubleshooting

<details>
<summary><strong>Service won't start</strong></summary>

Check the live logs:

```bash
journalctl -u backhaul -n 50 --no-pager
```

Common causes: a port from `TUNNEL_PORTS` is already in use (rerun the script and use the old-service cleanup step), or the token/IP doesn't match between the two sides.

</details>

<details>
<summary><strong>Client can't reach the Iran server</strong></summary>

- Confirm the control port is open on the Iran server's firewall (`ufw status` / `firewall-cmd --list-ports`).
- Confirm the token in both `config.toml` files matches exactly, character for character.
- Re-run the script's connectivity test, or manually: `nc -zv <iran-ip> <control-port>`.
</details>

<details>
<summary><strong>Ports show "not listening yet"</strong></summary>

Backhaul can take a few seconds to bind all configured ports after a restart. Re-check with:

```bash
ss -tlnp | grep backhaul
```

</details>

## Security

- The token is stored with `chmod 600` in both `config.toml` and the info file — still, treat it like a password.
- This script never modifies firewall rules automatically; it only prints the commands you'd need.
- Always review a script before piping it into `sudo bash`, including this one.

## Related Projects

Built and maintained by [power0matin](https://github.com/power0matin) alongside other Iran-network / VPN-infrastructure tooling — check the [profile](https://github.com/power0matin) for a Telegram-based 3x-ui reseller bot, a multi-panel VPN backup tool, and more.

## Contributing

Issues and PRs are welcome — especially for the transports listed in [Roadmap](#roadmap). Please open an issue first for larger changes so we can discuss the approach. See [CHANGELOG.md](./CHANGELOG.md) for release history.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=power0matin/backhaul-manager&type=Date)](https://star-history.com/#power0matin/backhaul-manager&Date)

## License

MIT — see [LICENSE](./LICENSE).

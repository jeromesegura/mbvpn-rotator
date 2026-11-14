# mbvpn-rotator

A menu-driven front end, auto-reconnect watchdog and health checker for the [Malwarebytes VPN Linux client](https://github.com/Malwarebytes/mbvpn-linux) (`mbvpn`).

It is inspired by [VPN Rotator](https://github.com/malwareinfosec/VPNrotator), but works with `mbvpn` (WireGuard) instead of `.ovpn` files. It is a single bash script with no dependencies beyond standard tools.

<img width="660" height="521" alt="image" src="https://github.com/user-attachments/assets/795a2aee-9b21-4058-93a4-7a67b5d08ab0" />

> **Unofficial.** This is a community project. It is not affiliated with, endorsed by or supported by Malwarebytes, and `mbvpn` itself is a separate project that describes itself as experimental. Use at your own risk.

## Features

- **Menu** to connect by country, city, specific server or favorite, and to rotate to a random server (any country, or the current one). Country and city names and flags come live from `mbvpn cities`, so new locations appear automatically.
- **Live header** that refreshes in place every 10 seconds without clearing the screen or disturbing what you are typing: connection status, public IP, how long you have been connected, and traffic. The last header is cached, so the menu appears instantly even though `mbvpn status` itself is slow, and live data then replaces it in place.
- **Auto-reconnect watchdog** that restores the tunnel if it drops or stops passing traffic, and that leaves it alone when you stop the VPN on purpose. It can run as a systemd service, so it also reconnects after a reboot.
- **Health and leak check** for the "Linux VM as a VPN gateway" setup: forwarding, kill-switch firewall rules, NAT, DNS and the public IPv4/IPv6 address.
- **Scriptable**: every action is also a command-line subcommand, for cron or systemd timers.

## Requirements

| Needed | For |
|---|---|
| Linux, `bash` 4.4 or newer | everything |
| `mbvpn`, installed and logged in | everything (see the [mbvpn README](https://github.com/Malwarebytes/mbvpn-linux)) |
| `curl`, `ip` (iproute2), `flock` (util-linux), `tput` (ncurses) | status, watchdog, checks |
| `dig` (Debian/Ubuntu: `bind9-dnsutils`) | DNS checks |
| `systemd` | optional background watchdog service |
| `sudo` | health check (reads firewall rules), service install, `mbvpn` updates |
| A UTF-8 locale | country flags (everything else works without) |

Run it as your normal user, not as root.

## Install

```bash
git clone https://github.com/<your-user>/mbvpn-rotator.git
cd mbvpn-rotator
sudo install -m 755 mbvpn-menu.sh /usr/local/bin/mbvpn-menu
mbvpn-menu
```

If `mbvpn` is installed with Homebrew and your shell can't find it, load Homebrew first:
`eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`.

## Usage

### Menu

| # | Action |
|---|---|
| 1 | Show the full `mbvpn status` output |
| 2 | Connect to a saved favorite |
| 3 | Connect to a random server in a country you pick |
| 4 | Connect to a random server in a city you pick |
| 5 | Connect to a specific server |
| 6 | Rotate: random server from any country, or from the current country |
| 7 | Manage favorites |
| 8 | Stop the VPN |
| 9 | Health and leak check |
| 10 | Switch auto-reconnect on or off |
| 11 | Update `mbvpn` with Homebrew and reapply its capabilities |
| 12 | Quit and stop the VPN |

After a successful connect the menu returns straight to the main screen, where the header shows the new server. Errors and warnings wait for Enter so you can read them.

Closing the terminal or losing an SSH session does **not** stop the VPN, so a dropped connection can't cut off the machines behind it.

### Command line

```bash
mbvpn-menu status               # connection status
mbvpn-menu rotate [country]     # random other server (same country if "country")
mbvpn-menu connect <server>     # e.g. us-sea-1
mbvpn-menu stop                 # disconnect on purpose
mbvpn-menu list                 # all known servers
mbvpn-menu check                # health and leak check
mbvpn-menu auto on|off|status   # auto-reconnect switch
mbvpn-menu watchdog             # run the watchdog in the foreground
mbvpn-menu install-service      # install and start the watchdog as a systemd service
mbvpn-menu service              # print the systemd unit instead of installing it
mbvpn-menu log                  # last watchdog events
```

## Auto-reconnect

The switch (menu option 10, or `mbvpn-menu auto on|off`) is saved, so you only set it once. What does the watching depends on how you run it:

- **Menu only:** the watchdog runs while the menu is open and idle. Quit the menu and nobody is watching.
- **Service (recommended):** `mbvpn-menu install-service` installs `mbvpn-watchdog.service`, which keeps watching in the background and reconnects after a reboot. The menu then works as a control panel. The service uses the same on/off switch.

How it behaves:

- It reconnects only if the last thing you asked for was "up". Stopping from the menu, `mbvpn-menu stop` or Quit counts as "on purpose" and it will not fight you.
- It checks every 15 seconds. A tunnel that says "connected" but fails the traffic probe (an HTTPS request to Cloudflare's `1.1.1.1`) three times in a row is restarted.
- Reconnect attempts 1 to 2 use your server, 3 to 4 use another server in the same country, and 5 onwards any server. After 5 failed attempts it slows down.
- A lock keeps it out of the way while you are switching servers yourself.
- Events are logged to `~/.config/mbvpn-menu/events.log`.

## Health and leak check

`mbvpn-menu check` (or menu option 9) tests, on the gateway machine:

- tunnel up and passing traffic, and which interface forwarded traffic would leave through
- IPv4 and IPv6 forwarding, dnsmasq, LAN clients seen
- the kill-switch firewall: `FORWARD` policy `DROP`, LAN traffic allowed only through the tunnel, nothing leaking via the real connection, NAT, restricted input, IPv6, rules saved for boot (needs `sudo`)
- DNS: dnsmasq answers, its upstream resolvers, and which address they see your queries come from
- the public IPv4 exit address and country compared with what `mbvpn` reports, and any IPv6 path

It cannot see inside the other machine. For that side, open a leak-test site there and confirm the IP and DNS servers belong to the VPN.

## Use as a VPN gateway for another VM

The LAN lines in the header and most of the health check assume this setup: one Linux VM connects to the VPN, and other VMs on a private network use it as their only way out, with a firewall kill switch so they lose connectivity if the tunnel drops. A step-by-step guide (VMware Fusion, Debian 13, iptables and dnsmasq) is in [docs/gateway-setup.md](docs/gateway-setup.md).

The script does not create firewall rules itself, and "kill switch" here refers to the rules in that guide. If you only want the menu on a normal machine, ignore the LAN lines: they show "none seen" or "OFF".

## Configuration

Set these as environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `LAN_IF` | `enp26s0` | Interface facing the other VMs (change this to yours) |
| `MBVPN_MENU_REFRESH` | `10` | Seconds between header refreshes, `0` to turn off |
| `MBVPN_MENU_WATCH_INTERVAL` | `15` | Seconds between watchdog checks |
| `DNSMASQ_DIR` | `/etc/dnsmasq.d` | Where the health check looks for dnsmasq settings |
| `XDG_CONFIG_HOME` | `~/.config` | Location of the state directory |

Auto-refresh needs a terminal at least 29 rows tall and is switched off in smaller ones.

State lives in `~/.config/mbvpn-menu/`: `favorites`, `state` (when the current connection started), `want` (up or down), `watchdog` (on or off), `events.log`, `lock` and `header.cache` (the last header drawn, shown instantly on the next start). No credentials are stored. `mbvpn` keeps its own session in `~/.config/mbvpn/`.

## Privacy and security

- The script stores and sends no credentials. Your login is handled entirely by `mbvpn`.
- The health check and watchdog contact Cloudflare (`1.1.1.1`) to find the exit address and test the tunnel, and the health check also asks your dnsmasq upstream resolvers which address they see your queries come from. Nothing else leaves the machine except what `mbvpn` itself sends.
- `sudo` is used only for the health check (reading firewall rules), `install-service` (writing the systemd unit), and updating `mbvpn`.
- Do not commit `~/.config/mbvpn/`, login codes or screenshots that show them.

## Troubleshooting

| Problem | What to try |
|---|---|
| `mbvpn not found in PATH` | Load Homebrew first (see Install) |
| "Could not get the server list" | Run `mbvpn servers`. If it errors, log in again with `mbvpn login --code <code>` |
| No flags | Your locale is not UTF-8. Check `locale charmap` |
| Menu is slow to appear | `mbvpn status` is slow because it looks up your IP and location. The first start after an install waits for it once; later starts show a cached header instantly. Time it with `time mbvpn status` |
| Header doesn't refresh | Terminal shorter than 29 rows, or `MBVPN_MENU_REFRESH=0` |
| Watchdog does not reconnect | Check `mbvpn-menu auto status` and `mbvpn-menu log`. It stays idle after a deliberate stop |
| Country or city names look odd | The parsing depends on `mbvpn cities` and `mbvpn servers` output. Open an issue with the output |

## Limitations

- It parses the human-readable output of `mbvpn status`, `servers` and `cities`. If `mbvpn` changes that format, parts of the menu may need updating.
- Developed on Debian 13 (arm64) in VMware Fusion. Other distributions and architectures should work but are less tested.
- The gateway features cover IPv4 on the LAN; the other VMs get no IPv6.

## Uninstall

```bash
sudo systemctl disable --now mbvpn-watchdog 2>/dev/null
sudo rm -f /etc/systemd/system/mbvpn-watchdog.service /usr/local/bin/mbvpn-menu
sudo systemctl daemon-reload
rm -rf ~/.config/mbvpn-menu
```

## License

[MIT](LICENSE)

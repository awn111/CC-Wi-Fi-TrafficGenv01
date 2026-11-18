# CC-Wi-Fi-TrafficGen

A Linux Wi-Fi **test client** that simulates many distinct clients from one
radio, so a Network Management System (NMS) populates client-count and traffic
graphs quickly for demos and lab validation.

It only joins networks whose PSK you already hold — i.e. networks you are
authorised to use. It does not scan, crack, or attack anything. Run it against
lab/demo infrastructure you own or administer.

## What it does, per cycle

1. Takes the next MAC from the pool and sets it on the interface.
2. Associates to a configured SSID using the PSK you supply.
3. Gets a DHCP lease, sending a per-client hostname (DHCP option 12).
4. Performs N successful randomised downloads from a URL list.
5. Holds the connection for a randomised duration (within limits), then
   releases the lease and tears down.

Every cycle is appended to `used_macs.csv`
(`timestamp,mac,ssid,hostname,result`).

## Static vs transient clients

The MAC file mixes two kinds of client:

- **Static / returning users** — explicit MACs in the file. They recur every
  pass (loop modes wrap the pool), so the NMS sees the same client connect and
  disconnect over time. They get the `--static-prefix` hostname (default `su-`).
- **Transient clients** — each `random` line is a slot that mints a fresh
  locally-administered MAC every time it's drawn. They get the
  `--hostname-prefix` (default `wtg-`).

MAC reuse is allowed and **not** deduplicated — returning users recurring is the
point, and repeated clients look more natural to the NMS.

## Requirements

Root, plus: `ip`, `iw`, `wpa_supplicant`, `wpa_cli`, `wpa_passphrase`, `curl`,
and a DHCP client (`dhclient` | `dhcpcd` | `udhcpc`).

## Usage

```bash
# copy the examples and fill in your own values
cp examples/networks.conf networks.conf
cp examples/macs.txt macs.txt
cp examples/urls.txt urls.txt

# plan only, no radio changes
./wifi-traffic-gen.sh --dry-run -v

# run for real
sudo ./wifi-traffic-gen.sh -i wlan0 -n networks.conf -m macs.txt -u urls.txt
```

Key flags (`--help` for the full list):

| Flag | Meaning | Default |
|------|---------|---------|
| `-i IFACE` | wireless interface | `wlan0` |
| `--session-min` / `--session-max` | random connected-time window (s) | `30` / `120` |
| `--downloads N` | successful downloads per cycle | `3` |
| `--order seq\|random` | SSID pick order | `seq` |
| `--hostname-prefix P` | hostname prefix for transient clients | `wtg` |
| `--static-prefix P` | hostname prefix for static users | `su` |
| `-L FILE` / `--log FILE` | syslog-format event log | `wifi-traffic-gen.log` |
| `--no-log` | disable the event log | — |
| `--dry-run` | parse + plan only | off |

`--min-secs` / `--max-secs` are kept as aliases of `--session-min` /
`--session-max`.

### Run length

Pick one; the default runs each unused pool MAC once:

| Flag | Meaning |
|------|---------|
| `--repeats N` | run exactly N cycles then stop |
| `--duration T` | run until T elapses — `90s`, `30m`, `2h`, or plain seconds |
| `--continuous` | run until interrupted (Ctrl-C) |
| `--cycles N` | hard cap on total cycles in any mode (`0` = no cap) |

`--repeats` / `--duration` / `--continuous` **wrap around the file pool**: each
pass replays the static users (same MACs, same hostnames) and re-mints the
transient slots with fresh MACs. So a continuous run keeps the returning users
reconnecting while a stream of new one-off clients comes and goes. Add or remove
`random` lines to change the ratio of transient to static traffic.

### Logging

Two records are written:

- **`used_macs.csv`** — one row per cycle: `timestamp,mac,ssid,hostname,result`.
  A full ledger of every client session (maps hostname ↔ MAC ↔ SSID).
- **`wifi-traffic-gen.log`** — syslog-format (RFC3164) event log of
  associations, leases, downloads, errors and disconnects. `INFO` for normal
  actions, `WARNING`/`ERR` for problems, `DEBUG` with `-v`. Point it elsewhere
  with `-L`, or turn it off with `--no-log`.

### Hostnames

Each client sends a hostname as **DHCP option 12** so test clients are easy to
spot in the NMS. The hostname is `<prefix>-<hash>`, where `<hash>` is the first
6 hex of `sha1(MAC)`. Because the hash is deterministic, a given MAC **always**
maps to the same hostname — so a returning static user keeps one identity across
sessions and runs. Static users use `--static-prefix` (default `su`), transient
clients use `--hostname-prefix` (default `wtg`), e.g. `su-c98a83`, `wtg-1f0b7a`.
The host's own `/etc/hostname` is **never** changed — the name is injected into
each DHCP request only, so the impact on the machine is nil.

## Input files

- **networks.conf** — `SSID<TAB>PSK` or `SSID|PSK` per line. `#` comments ok.
- **macs.txt** — one MAC per line = a static/returning user; the token `random`
  = a transient slot minted fresh each pass. `#` comments ok.
- **urls.txt** — one URL per line. Point at your own test server for a closed
  demo, or at public speed-test files.

## Notes & limits

- Serial: one client at a time on a single radio. Good for populating NMS
  client/traffic graphs; it does not reproduce concurrent airtime contention.
- The driver must allow MAC changes in client mode — the script downs the link
  before changing the address, which most `mac80211` drivers accept.
- A failed cycle still records (and burns) its MAC, logged with the failure
  reason in `used_macs.csv`.

## Credentials hygiene

`networks.conf`, `macs.txt`, and `urls.txt` are git-ignored at the repo root so
your real PSKs don't get committed. Only the `examples/` copies are tracked.

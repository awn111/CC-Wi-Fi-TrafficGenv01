# CC-Wi-Fi-TrafficGen

A Linux Wi-Fi **test client** that simulates many distinct clients from one
radio, so a Network Management System (NMS) populates client-count and traffic
graphs quickly for demos and lab validation.

It only joins networks whose PSK you already hold — i.e. networks you are
authorised to use. It does not scan, crack, or attack anything. Run it against
lab/demo infrastructure you own or administer.

## What it does, per cycle

1. Takes the next **unused** MAC from the pool and sets it on the interface.
2. Associates to a configured SSID using the PSK you supply.
3. Gets a DHCP lease.
4. Performs N successful randomised downloads from a URL list.
5. Holds the connection for a randomised duration (within limits), then
   releases the lease and tears down.

Every MAC used is appended to `used_macs.csv` and **never reused** — across
runs, not just within one.

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
| `--min-secs` / `--max-secs` | connected-time window (s) | `30` / `120` |
| `--downloads N` | successful downloads per cycle | `3` |
| `--cycles N` | number of cycles; `0` = exhaust MAC pool | `0` |
| `--order seq\|random` | SSID pick order | `seq` |
| `--hostname-prefix P` | DHCP hostname prefix for test clients | `wtg` |
| `--dry-run` | parse + plan only | off |

### Hostnames

Each client sends a hostname as **DHCP option 12** so test clients are easy to
spot in the NMS. The hostname is `<prefix>-<last 3 octets of MAC>`, e.g.
`wtg-334401`. Set the prefix with `--hostname-prefix` (it's sanitised to valid
hostname characters). The host's own `/etc/hostname` is **never** changed — the
name is injected into each DHCP request only, so the impact on the machine is
nil. The chosen hostname is recorded per cycle in `used_macs.csv`.

## Input files

- **networks.conf** — `SSID<TAB>PSK` or `SSID|PSK` per line. `#` comments ok.
- **macs.txt** — one MAC per line; the token `random` expands to a
  locally-administered (`02:…`) address. Already-used MACs are skipped.
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

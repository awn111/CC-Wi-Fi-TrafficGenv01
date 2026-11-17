#!/usr/bin/env bash
# wifi-traffic-gen.sh
# Simulates many distinct Wi-Fi clients from one Linux box so a Network
# Management System (NMS) populates client-count and traffic graphs quickly
# for demos / lab validation.
#
# Each cycle:  assign a fresh (never-reused) MAC -> associate to a configured
# SSID using a PSK you supply -> DHCP -> perform N randomised downloads ->
# release lease -> tear down. Connected time is randomised within limits.
#
# This is a TEST CLIENT. It only joins networks whose PSK you already hold,
# i.e. networks you are authorised to use. It does not crack, scan, or attack
# anything. Use it on lab/demo infrastructure you own or administer.
#
# Requires root and: ip, iw, wpa_supplicant, wpa_cli, wpa_passphrase, curl,
# plus a DHCP client (dhclient | dhcpcd | udhcpc).

set -uo pipefail

# ---------------- defaults (override via flags) ----------------
IFACE="wlan0"
NETWORKS_FILE="./networks.conf"
MACS_FILE="./macs.txt"
URLS_FILE="./urls.txt"
USED_LOG="./used_macs.csv"
STATE_DIR="./.wtg-run"

MIN_SECS=30            # minimum connected time per cycle
MAX_SECS=120           # hard ceiling on connected time per cycle
MIN_DOWNLOADS=3        # successful downloads required before disconnecting
ASSOC_TIMEOUT=25       # seconds to reach wpa_state=COMPLETED
DHCP_TIMEOUT=20        # seconds to obtain a lease
DL_MAX_TIME=30         # per-download curl ceiling (seconds)
INTER_DL_MIN=1         # min gap between downloads (seconds)
INTER_DL_MAX=5         # max gap between downloads (seconds)
CYCLES=0               # 0 = keep going until the MAC pool is exhausted
NET_ORDER="seq"        # seq | random  (which SSID each cycle picks)
DRY_RUN=0              # 1 = parse + plan only, touch no hardware
VERBOSE=0

WPA_CONF=""            # temp per-cycle wpa_supplicant conf
WPA_PID=""
CUR_MAC=""
CUR_SSID=""
DHCP_CMD=""            # resolved by require_tools; kept defined for set -u

# ---------------- logging ----------------
log()  { printf '%(%Y-%m-%dT%H:%M:%S)T [%s] %s\n' -1 "${1}" "${2}"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
err()  { log ERR  "$*" >&2; }
dbg()  { [[ "$VERBOSE" -eq 1 ]] && log DBG "$*" || true; }
die()  { err "$*"; cleanup; exit 1; }

usage() {
    cat <<EOF
wifi-traffic-gen.sh - multi-client Wi-Fi traffic generator for NMS demos

Usage: sudo $0 [options]

  -i IFACE          wireless interface            (default: $IFACE)
  -n FILE           networks file (SSID + PSK)    (default: $NETWORKS_FILE)
  -m FILE           MAC address pool file         (default: $MACS_FILE)
  -u FILE           download URL list             (default: $URLS_FILE)
  -l FILE           used-MAC record (append)      (default: $USED_LOG)
  --min-secs N      min connected seconds         (default: $MIN_SECS)
  --max-secs N      max connected seconds         (default: $MAX_SECS)
  --downloads N     successful downloads/cycle    (default: $MIN_DOWNLOADS)
  --cycles N        number of cycles, 0=exhaust pool (default: $CYCLES)
  --order seq|random  SSID pick order             (default: $NET_ORDER)
  --dl-timeout N    per-download ceiling seconds  (default: $DL_MAX_TIME)
  --dry-run         parse and plan only; no radio changes
  -v, --verbose
  -h, --help

File formats:
  networks.conf : one "SSID<TAB>PSK" per line (or 'SSID|PSK'). # comments ok.
  macs.txt      : one MAC per line (AA:BB:CC:DD:EE:FF). Blank 'random' line
                  tokens are expanded to a locally-administered random MAC.
  urls.txt      : one URL per line. http(s) recommended.
EOF
}

# ---------------- arg parsing ----------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) IFACE="$2"; shift 2;;
        -n) NETWORKS_FILE="$2"; shift 2;;
        -m) MACS_FILE="$2"; shift 2;;
        -u) URLS_FILE="$2"; shift 2;;
        -l) USED_LOG="$2"; shift 2;;
        --min-secs) MIN_SECS="$2"; shift 2;;
        --max-secs) MAX_SECS="$2"; shift 2;;
        --downloads) MIN_DOWNLOADS="$2"; shift 2;;
        --cycles) CYCLES="$2"; shift 2;;
        --order) NET_ORDER="$2"; shift 2;;
        --dl-timeout) DL_MAX_TIME="$2"; shift 2;;
        --dry-run) DRY_RUN=1; shift;;
        -v|--verbose) VERBOSE=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown argument: $1 (see --help)";;
    esac
done

# ---------------- helpers ----------------
rand_between() {   # rand_between MIN MAX -> inclusive integer
    local lo=$1 hi=$2
    (( hi <= lo )) && { echo "$lo"; return; }
    echo $(( lo + RANDOM % (hi - lo + 1) ))
}

# A locally-administered, unicast MAC: 2nd-least-significant bit of byte0 set,
# least-significant (multicast) bit clear. Avoids clashing with real OUIs.
gen_random_mac() {
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
        $((RANDOM%256)) $((RANDOM%256))
}

normalise_mac() { tr 'A-F' 'a-f' <<<"${1// /}"; }

mac_already_used() {   # returns 0 if MAC present in USED_LOG
    local mac; mac="$(normalise_mac "$1")"
    [[ -f "$USED_LOG" ]] || return 1
    cut -d, -f2 "$USED_LOG" 2>/dev/null | grep -qiFx "$mac"
}

record_mac() {         # record_mac MAC SSID RESULT
    local mac ssid result ts
    mac="$(normalise_mac "$1")"; ssid="$2"; result="$3"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -f "$USED_LOG" ]] || echo "timestamp,mac,ssid,result" >"$USED_LOG"
    printf '%s,%s,%s,%s\n' "$ts" "$mac" "$ssid" "$result" >>"$USED_LOG"
}

require_tools() {
    local missing=()
    for t in ip iw wpa_supplicant wpa_cli wpa_passphrase curl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    DHCP_CMD=""
    for d in dhclient dhcpcd udhcpc; do
        command -v "$d" >/dev/null 2>&1 && { DHCP_CMD="$d"; break; }
    done
    [[ -z "$DHCP_CMD" ]] && missing+=("dhclient|dhcpcd|udhcpc")
    (( ${#missing[@]} )) && die "Missing tools: ${missing[*]}"
    dbg "DHCP client: $DHCP_CMD"
}

# ---------------- input loading ----------------
declare -a SSIDS PSKS URLS MAC_POOL

load_networks() {
    [[ -f "$NETWORKS_FILE" ]] || die "Networks file not found: $NETWORKS_FILE"
    local line ssid psk
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "${line// }" || "${line:0:1}" == "#" ]] && continue
        if [[ "$line" == *$'\t'* ]]; then
            ssid="${line%%$'\t'*}"; psk="${line#*$'\t'}"
        elif [[ "$line" == *"|"* ]]; then
            ssid="${line%%|*}"; psk="${line#*|}"
        else
            warn "Skipping malformed network line: $line"; continue
        fi
        ssid="${ssid#"${ssid%%[![:space:]]*}"}"; ssid="${ssid%"${ssid##*[![:space:]]}"}"
        [[ -z "$ssid" ]] && continue
        SSIDS+=("$ssid"); PSKS+=("$psk")
    done < "$NETWORKS_FILE"
    (( ${#SSIDS[@]} )) || die "No usable networks in $NETWORKS_FILE"
    info "Loaded ${#SSIDS[@]} network(s)."
}

load_urls() {
    [[ -f "$URLS_FILE" ]] || die "URLs file not found: $URLS_FILE"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"; line="${line// }"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        URLS+=("$line")
    done < "$URLS_FILE"
    (( ${#URLS[@]} )) || die "No usable URLs in $URLS_FILE"
    info "Loaded ${#URLS[@]} URL(s)."
}

load_macs() {
    [[ -f "$MACS_FILE" ]] || die "MAC file not found: $MACS_FILE"
    local line mac
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"; line="${line// }"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        if [[ "$line" == "random" ]]; then
            mac="$(gen_random_mac)"
        else
            mac="$(normalise_mac "$line")"
            [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || {
                warn "Skipping invalid MAC: $line"; continue; }
        fi
        mac_already_used "$mac" && { dbg "Skipping already-used MAC $mac"; continue; }
        MAC_POOL+=("$mac")
    done < "$MACS_FILE"
    (( ${#MAC_POOL[@]} )) || die "No unused MACs available in $MACS_FILE"
    info "MAC pool: ${#MAC_POOL[@]} unused address(es)."
}

# ---------------- radio control ----------------
set_mac() {
    local mac="$1"
    ip link set dev "$IFACE" down          || return 1
    ip link set dev "$IFACE" address "$mac" || { ip link set dev "$IFACE" up; return 1; }
    ip link set dev "$IFACE" up            || return 1
    local actual; actual="$(cat /sys/class/net/"$IFACE"/address 2>/dev/null)"
    [[ "$(normalise_mac "$actual")" == "$(normalise_mac "$mac")" ]]
}

associate() {
    local ssid="$1" psk="$2"
    WPA_CONF="$STATE_DIR/wpa.$$.conf"
    { echo "ctrl_interface=$STATE_DIR/wpa_ctrl"
      echo "ap_scan=1"
      wpa_passphrase "$ssid" "$psk"
    } >"$WPA_CONF" 2>/dev/null || return 1
    chmod 600 "$WPA_CONF"

    wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF" -P "$STATE_DIR/wpa.$$.pid" \
        >>"$STATE_DIR/wpa.log" 2>&1 || return 1
    WPA_PID="$(cat "$STATE_DIR/wpa.$$.pid" 2>/dev/null)"

    local waited=0 state
    while (( waited < ASSOC_TIMEOUT )); do
        state="$(wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p')"
        [[ "$state" == "COMPLETED" ]] && return 0
        sleep 1; ((waited++))
    done
    return 1
}

dhcp_up() {
    case "$DHCP_CMD" in
        dhclient) timeout "$DHCP_TIMEOUT" dhclient -1 "$IFACE" >/dev/null 2>&1;;
        dhcpcd)   timeout "$DHCP_TIMEOUT" dhcpcd -4 -t "$DHCP_TIMEOUT" "$IFACE" >/dev/null 2>&1;;
        udhcpc)   timeout "$DHCP_TIMEOUT" udhcpc -i "$IFACE" -n -q >/dev/null 2>&1;;
    esac
    ip -4 addr show dev "$IFACE" | grep -q 'inet '
}

dhcp_down() {
    case "$DHCP_CMD" in
        dhclient) dhclient -r "$IFACE" >/dev/null 2>&1;;
        dhcpcd)   dhcpcd -k "$IFACE" >/dev/null 2>&1;;
        udhcpc)   :;;
    esac
    ip -4 addr flush dev "$IFACE" >/dev/null 2>&1
}

teardown_link() {
    [[ -n "$WPA_PID" ]] && kill "$WPA_PID" >/dev/null 2>&1
    wpa_cli -i "$IFACE" terminate >/dev/null 2>&1
    WPA_PID=""
    [[ -n "$WPA_CONF" && -f "$WPA_CONF" ]] && rm -f "$WPA_CONF"
    WPA_CONF=""
}

# ---------------- traffic ----------------
do_downloads() {
    local target="$1" done_count=0 attempts=0 url rc
    local cap=$(( target * 4 + 4 ))   # give up after plenty of attempts
    while (( done_count < target && attempts < cap )); do
        ((attempts++))
        url="${URLS[$((RANDOM % ${#URLS[@]}))]}"
        dbg "GET $url"
        curl -fsS --max-time "$DL_MAX_TIME" --interface "$IFACE" \
             -o /dev/null "$url"
        rc=$?
        if (( rc == 0 )); then
            ((done_count++))
            info "  download $done_count/$target ok"
        else
            warn "  download failed (curl rc=$rc): $url"
        fi
        sleep "$(rand_between "$INTER_DL_MIN" "$INTER_DL_MAX")"
    done
    (( done_count >= target ))
}

# ---------------- one cycle ----------------
run_cycle() {
    local mac="$1" ssid="$2" psk="$3"
    local budget dls result="fail"
    budget="$(rand_between "$MIN_SECS" "$MAX_SECS")"
    info "Cycle: mac=$mac ssid=\"$ssid\" budget=${budget}s downloads=$MIN_DOWNLOADS"

    if (( DRY_RUN )); then
        info "  [dry-run] would set MAC, associate, DHCP, download, disconnect"
        record_mac "$mac" "$ssid" "dry-run"
        return 0
    fi

    CUR_MAC="$mac"; CUR_SSID="$ssid"
    local start now elapsed
    start="$(date +%s)"

    if ! set_mac "$mac";            then warn "  MAC set failed";    record_mac "$mac" "$ssid" "mac-fail";   return 1; fi
    if ! associate "$ssid" "$psk";  then warn "  association failed"; teardown_link; record_mac "$mac" "$ssid" "assoc-fail"; return 1; fi
    info "  associated"
    if ! dhcp_up;                   then warn "  DHCP failed";       dhcp_down; teardown_link; record_mac "$mac" "$ssid" "dhcp-fail"; return 1; fi
    info "  lease acquired: $(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | head -1)"

    do_downloads "$MIN_DOWNLOADS" && result="ok" || result="partial-dl"

    # honour the minimum connected time even if downloads finished early
    now="$(date +%s)"; elapsed=$(( now - start ))
    if (( elapsed < budget )); then
        dbg "  holding ${budget}s budget: sleeping $(( budget - elapsed ))s"
        sleep $(( budget - elapsed ))
    fi

    info "  disconnecting after $(( $(date +%s) - start ))s"
    dhcp_down; teardown_link
    CUR_MAC=""; CUR_SSID=""
    record_mac "$mac" "$ssid" "$result"
    return 0
}

# ---------------- cleanup / signals ----------------
cleanup() {
    [[ -n "${CUR_MAC:-}" ]] && warn "Interrupted mid-cycle (mac=$CUR_MAC); tearing down."
    dhcp_down 2>/dev/null
    teardown_link 2>/dev/null
}
trap 'err "Signal caught"; cleanup; exit 130' INT TERM

# ---------------- main ----------------
main() {
    (( DRY_RUN == 0 && EUID != 0 )) && die "Must run as root (needs ip/wpa_supplicant). Try: sudo $0 ..."
    (( MIN_SECS <= MAX_SECS )) || die "--min-secs must be <= --max-secs"
    mkdir -p "$STATE_DIR"
    (( DRY_RUN == 0 )) && require_tools

    load_networks
    load_urls
    load_macs

    local pool=("${MAC_POOL[@]}")
    local total=${#pool[@]}
    local planned=$total
    (( CYCLES > 0 && CYCLES < total )) && planned=$CYCLES
    info "Planned cycles: $planned (interface=$IFACE, order=$NET_ORDER, dry_run=$DRY_RUN)"

    local i ok=0 n=0 idx mac
    for (( i=0; i<planned; i++ )); do
        mac="${pool[$i]}"
        if [[ "$NET_ORDER" == "random" ]]; then
            idx=$(( RANDOM % ${#SSIDS[@]} ))
        else
            idx=$(( i % ${#SSIDS[@]} ))
        fi
        ((n++))
        if run_cycle "$mac" "${SSIDS[$idx]}" "${PSKS[$idx]}"; then
            ((ok++))
        fi
    done

    info "Done. $ok/$n cycle(s) succeeded. Used-MAC log: $USED_LOG"
    cleanup
    return 0
}

main
exit $?

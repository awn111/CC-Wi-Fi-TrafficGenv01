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
CYCLES=0               # cap on total cycles (0 = no cap); see run modes
NET_ORDER="seq"        # seq | random  (which SSID each cycle picks)
HOSTNAME_PREFIX="wtg"  # DHCP hostname prefix for TRANSIENT (random) clients
STATIC_PREFIX="su"     # DHCP hostname prefix for STATIC users (file MACs)
DRY_RUN=0              # 1 = parse + plan only, touch no hardware
VERBOSE=0

LOG_FILE="./wifi-traffic-gen.log"  # syslog-format event log; "" or --no-log disables
# Run length (pick one; default = one pass over the file pool):
RUN_MODE="pool"        # pool | repeats | duration | continuous
REPEATS=0              # repeats mode: number of cycles to run
DURATION=0             # duration mode: seconds of wall-clock to keep running
# Loop modes (repeats/duration/continuous) wrap around the file pool: static
# MACs recur (same returning client), 'random' slots re-mint a fresh MAC each
# pass. MAC reuse is allowed and NOT checked against the used-MAC log.

WPA_CONF=""            # temp per-cycle wpa_supplicant conf
WPA_PID=""
CUR_MAC=""
CUR_SSID=""
DHCP_CMD=""            # resolved by require_tools; kept defined for set -u
SYSLOG_TAG="wifi-traffic-gen"
HOSTN="${HOSTNAME:-$(hostname 2>/dev/null || echo localhost)}"

# ---------------- logging ----------------
# Console line: ISO-ish + [LEVEL]. File line: RFC3164 syslog-style, severities
# INFO (normal), WARNING (problems), ERR (fatal), DEBUG (verbose).
_log_file() {   # _log_file LEVEL MESSAGE
    [[ -n "$LOG_FILE" ]] || return 0
    printf '%s %s %s[%d]: %s: %s\n' \
        "$(date '+%b %e %H:%M:%S')" "$HOSTN" "$SYSLOG_TAG" "$$" "$1" "$2" \
        >>"$LOG_FILE" 2>/dev/null || true
}
log() {   # log LEVEL MESSAGE [STREAM]
    local level="$1" msg="$2" stream="${3:-1}"
    printf '%(%Y-%m-%dT%H:%M:%S)T [%s] %s\n' -1 "$level" "$msg" >&"$stream"
    _log_file "$level" "$msg"
}
info() { log INFO    "$*" 1; }
warn() { log WARNING "$*" 2; }
err()  { log ERR     "$*" 2; }
dbg()  { [[ "$VERBOSE" -eq 1 ]] && log DEBUG "$*" 1 || true; }
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
  -L FILE / --log FILE  syslog-format event log   (default: $LOG_FILE)
  --no-log          disable the event log file
  --session-min N   min connected seconds         (default: $MIN_SECS)
  --session-max N   max connected seconds         (default: $MAX_SECS)
  --min-secs N      alias of --session-min
  --max-secs N      alias of --session-max
  --downloads N     successful downloads/cycle    (default: $MIN_DOWNLOADS)
  --order seq|random  SSID pick order             (default: $NET_ORDER)
  --hostname-prefix P  prefix for TRANSIENT clients (default: $HOSTNAME_PREFIX)
  --static-prefix P    prefix for STATIC users      (default: $STATIC_PREFIX)
                       Hostname = "<prefix>-<hash of MAC>", sent as DHCP
                       option 12. It's a deterministic hash, so a given MAC
                       always maps to the same hostname. The host's own
                       /etc/hostname is NEVER changed.
  --dl-timeout N    per-download ceiling seconds  (default: $DL_MAX_TIME)

  Run length (choose one; default = one pass over the file pool):
  --repeats N       run exactly N cycles then stop
  --duration T      run cycles until T elapses (e.g. 90s, 30m, 2h, or plain secs)
  --continuous      run until interrupted (Ctrl-C)
  --cycles N        hard cap on total cycles in any mode (0 = no cap)

  --dry-run         parse and plan only; no radio changes
  -v, --verbose
  -h, --help

Notes:
  * Session time is randomised per cycle between --session-min and
    --session-max, e.g. --session-min 60 --session-max 300.
  * STATIC users are the explicit MACs in the MAC file: they recur (same
    returning client) and get the --static-prefix. TRANSIENT clients come
    from 'random' lines (and are re-minted fresh each pass) with the
    --hostname-prefix. MAC reuse is allowed and not deduplicated.
  * Loop modes wrap around the file pool; a continuous run therefore keeps
    the static users reconnecting while minting fresh transient clients.

File formats:
  networks.conf : one "SSID<TAB>PSK" per line (or 'SSID|PSK'). # comments ok.
  macs.txt      : one MAC per line (AA:BB:CC:DD:EE:FF) = a static/returning
                  user. The token 'random' = a transient client slot, minted
                  fresh (locally-administered) each pass. # comments ok.
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
        -L|--log) LOG_FILE="$2"; shift 2;;
        --no-log) LOG_FILE=""; shift;;
        --session-min|--min-secs) MIN_SECS="$2"; shift 2;;
        --session-max|--max-secs) MAX_SECS="$2"; shift 2;;
        --downloads) MIN_DOWNLOADS="$2"; shift 2;;
        --cycles) CYCLES="$2"; shift 2;;
        --repeats) RUN_MODE="repeats"; REPEATS="$2"; shift 2;;
        --duration) RUN_MODE="duration"; DURATION="$2"; shift 2;;
        --continuous) RUN_MODE="continuous"; shift;;
        --order) NET_ORDER="$2"; shift 2;;
        --hostname-prefix) HOSTNAME_PREFIX="$2"; shift 2;;
        --static-prefix) STATIC_PREFIX="$2"; shift 2;;
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

# parse_duration 90s|30m|2h|1d|N  ->  seconds
parse_duration() {
    local s="$1"
    [[ "$s" =~ ^([0-9]+)([smhd]?)$ ]] || die "Invalid duration: $s (use e.g. 90s, 30m, 2h)"
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    case "$u" in
        ""|s) echo "$n";;
        m)    echo $(( n * 60 ));;
        h)    echo $(( n * 3600 ));;
        d)    echo $(( n * 86400 ));;
    esac
}

# A locally-administered, unicast MAC: 2nd-least-significant bit of byte0 set,
# least-significant (multicast) bit clear. Avoids clashing with real OUIs.
gen_random_mac() {
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
        $((RANDOM%256)) $((RANDOM%256))
}

normalise_mac() { tr 'A-F' 'a-f' <<<"${1// /}"; }

# Build a DHCP hostname: "<prefix>-<hash>" where hash is the first 6 hex of
# sha1(MAC). Deterministic — a given MAC always yields the same hostname, so a
# returning client keeps one identity across sessions/runs. Sanitised to
# RFC-952/1123 label rules (lowercase a-z 0-9 '-', <=63 chars).
gen_hostname() {
    local mac="$1" prefix="$2" p h
    h="$(printf '%s' "${mac,,}" | sha1sum 2>/dev/null | cut -c1-6)"
    [[ -z "$h" ]] && h="${mac//:/}"; h="${h: -6}"   # fallback if sha1sum absent
    p="${prefix,,}"                          # lowercase
    p="${p//[^a-z0-9-]/-}"                    # invalid chars -> hyphen
    p="${p#-}"; p="${p%-}"                    # trim leading/trailing hyphens
    [[ -z "$p" ]] && p="wtg"
    (( ${#p} > 50 )) && p="${p:0:50}"         # keep total <= 63
    echo "${p}-${h}"
}

record_mac() {         # record_mac MAC SSID HOSTNAME RESULT
    local mac ssid hostname result ts
    mac="$(normalise_mac "$1")"; ssid="$2"; hostname="$3"; result="$4"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -f "$USED_LOG" ]] || echo "timestamp,mac,ssid,hostname,result" >"$USED_LOG"
    printf '%s,%s,%s,%s,%s\n' "$ts" "$mac" "$ssid" "$hostname" "$result" >>"$USED_LOG"
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
# Pool is a list of "slots". A static slot carries a fixed MAC (returning user);
# a random slot mints a fresh transient MAC each time it is drawn.
declare -a SSIDS PSKS URLS SLOT_MAC SLOT_KIND
POOL_IDX=0           # cursor into the slot list

# Set NEXT_MAC / NEXT_KIND to the next client and return 0, or non-zero when the
# pool is spent (pool mode only). MUST be called directly (not in $()), so its
# update to POOL_IDX persists in the current shell. Loop modes wrap the pool:
# static slots recur (same MAC), random slots re-mint fresh each pass.
NEXT_MAC=""
NEXT_KIND=""
next_mac() {
    local n=${#SLOT_MAC[@]}
    (( n == 0 )) && return 1
    if (( POOL_IDX >= n )); then
        [[ "$RUN_MODE" == "pool" ]] && return 1   # one pass only
        POOL_IDX=0                                 # wrap for loop modes
    fi
    NEXT_KIND="${SLOT_KIND[$POOL_IDX]}"
    if [[ "$NEXT_KIND" == "static" ]]; then
        NEXT_MAC="${SLOT_MAC[$POOL_IDX]}"          # same MAC every pass
    else
        NEXT_MAC="$(gen_random_mac)"               # fresh transient each draw
    fi
    ((POOL_IDX++))
    return 0
}

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
    local line mac nstatic=0 nrandom=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"; line="${line// }"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        if [[ "$line" == "random" ]]; then
            SLOT_MAC+=(""); SLOT_KIND+=("random"); ((nrandom++))
        else
            mac="$(normalise_mac "$line")"
            [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || {
                warn "Skipping invalid MAC: $line"; continue; }
            SLOT_MAC+=("$mac"); SLOT_KIND+=("static"); ((nstatic++))
        fi
    done < "$MACS_FILE"
    (( ${#SLOT_MAC[@]} )) || die "No usable entries in $MACS_FILE"
    info "MAC pool: $nstatic static user(s), $nrandom transient slot(s)."
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
    local hn="$1" cf
    case "$DHCP_CMD" in
        dhclient)
            # per-cycle conf injects DHCP option 12; system hostname untouched
            cf="$STATE_DIR/dhclient.$$.conf"
            printf 'send host-name "%s";\n' "$hn" >"$cf"
            timeout "$DHCP_TIMEOUT" dhclient -1 -cf "$cf" "$IFACE" >/dev/null 2>&1
            ;;
        dhcpcd)
            timeout "$DHCP_TIMEOUT" dhcpcd -4 -t "$DHCP_TIMEOUT" -h "$hn" "$IFACE" >/dev/null 2>&1
            ;;
        udhcpc)
            timeout "$DHCP_TIMEOUT" udhcpc -i "$IFACE" -x "hostname:$hn" -n -q >/dev/null 2>&1
            ;;
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
    local mac="$1" ssid="$2" psk="$3" kind="${4:-static}"
    local budget dls result="fail" hn prefix
    budget="$(rand_between "$MIN_SECS" "$MAX_SECS")"
    [[ "$kind" == "static" ]] && prefix="$STATIC_PREFIX" || prefix="$HOSTNAME_PREFIX"
    hn="$(gen_hostname "$mac" "$prefix")"
    info "Cycle: kind=$kind mac=$mac host=$hn ssid=\"$ssid\" budget=${budget}s downloads=$MIN_DOWNLOADS"

    if (( DRY_RUN )); then
        info "  [dry-run] would set MAC, associate, DHCP (hostname=$hn), download, disconnect"
        record_mac "$mac" "$ssid" "$hn" "dry-run"
        return 0
    fi

    CUR_MAC="$mac"; CUR_SSID="$ssid"
    local start now elapsed
    start="$(date +%s)"

    if ! set_mac "$mac";            then warn "  MAC set failed";    record_mac "$mac" "$ssid" "$hn" "mac-fail";   return 1; fi
    if ! associate "$ssid" "$psk";  then warn "  association failed"; teardown_link; record_mac "$mac" "$ssid" "$hn" "assoc-fail"; return 1; fi
    info "  associated"
    if ! dhcp_up "$hn";             then warn "  DHCP failed";       dhcp_down; teardown_link; record_mac "$mac" "$ssid" "$hn" "dhcp-fail"; return 1; fi
    info "  lease acquired: $(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | head -1) as $hn"

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
    record_mac "$mac" "$ssid" "$hn" "$result"
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
    (( MIN_SECS <= MAX_SECS )) || die "--session-min must be <= --session-max"
    [[ "$NET_ORDER" == seq || "$NET_ORDER" == random ]] || die "--order must be seq or random"

    # Resolve duration string -> seconds.
    if [[ "$RUN_MODE" == "duration" ]]; then
        DURATION="$(parse_duration "$DURATION")"
    fi

    mkdir -p "$STATE_DIR"
    (( DRY_RUN == 0 )) && require_tools

    load_networks
    load_urls
    load_macs

    case "$RUN_MODE" in
        pool)       info "Run mode: pool (one pass over ${#SLOT_MAC[@]} slot(s))";;
        repeats)    info "Run mode: repeats ($REPEATS cycle(s), pool wraps)";;
        duration)   info "Run mode: duration (${DURATION}s, pool wraps)";;
        continuous) info "Run mode: continuous until interrupted (pool wraps)";;
    esac
    info "Settings: iface=$IFACE order=$NET_ORDER session=${MIN_SECS}-${MAX_SECS}s downloads=$MIN_DOWNLOADS cap=$CYCLES dry_run=$DRY_RUN"

    local i=0 ok=0 n=0 idx mac kind start
    start="$(date +%s)"
    while :; do
        # ---- termination checks ----
        case "$RUN_MODE" in
            repeats)    (( i >= REPEATS )) && break;;
            duration)   (( $(date +%s) - start >= DURATION )) && break;;
            continuous) : ;;
            pool)       : ;;   # ends when next_mac is exhausted
        esac
        (( CYCLES > 0 && i >= CYCLES )) && break

        next_mac || { info "Pool pass complete after $n cycle(s)."; break; }
        mac="$NEXT_MAC"; kind="$NEXT_KIND"

        if [[ "$NET_ORDER" == "random" ]]; then
            idx=$(( RANDOM % ${#SSIDS[@]} ))
        else
            idx=$(( i % ${#SSIDS[@]} ))
        fi
        ((n++))
        run_cycle "$mac" "${SSIDS[$idx]}" "${PSKS[$idx]}" "$kind" && ((ok++))
        ((i++))
    done

    info "Done. $ok/$n cycle(s) succeeded. Used-MAC log: $USED_LOG${LOG_FILE:+, event log: $LOG_FILE}"
    cleanup
    return 0
}

main
exit $?

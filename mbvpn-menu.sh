#!/usr/bin/env bash
# mbvpn-menu: menu-driven front end, auto-reconnect watchdog and health checks
# for the Malwarebytes VPN Linux client (mbvpn). Modeled on the VPN Rotator menu.
# Run as your normal user (not root).
#
#   mbvpn-menu                   interactive menu
#   mbvpn-menu status            print connection status
#   mbvpn-menu rotate [country]  connect to a random other server (same country if "country")
#   mbvpn-menu connect <server>  connect to a specific server
#   mbvpn-menu stop              disconnect (Windows VM loses internet)
#   mbvpn-menu list              list known servers
#   mbvpn-menu check             health + leak check (same as menu option 9)
#   mbvpn-menu auto on|off|status  switch auto-reconnect on/off
#   mbvpn-menu watchdog          run the watchdog loop in the foreground (used by the service)
#   mbvpn-menu install-service   install + start the watchdog as a systemd service (uses sudo)
#   mbvpn-menu service           print the systemd unit instead of installing it
#   mbvpn-menu log               show the last watchdog events

VERSION="1.0"
LAN_IF="${LAN_IF:-enp26s0}"
REFRESH="${MBVPN_MENU_REFRESH:-10}"                  # seconds between automatic header refreshes (0 = off)
WATCH_INTERVAL="${MBVPN_MENU_WATCH_INTERVAL:-15}"    # seconds between watchdog checks
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mbvpn-menu"
FAV_FILE="$STATE_DIR/favorites"
STATE_FILE="$STATE_DIR/state"        # "<epoch> <server>" written on every successful connect
WANT_FILE="$STATE_DIR/want"          # "up <server>" or "down": what the user last asked for
WATCH_FILE="$STATE_DIR/watchdog"     # "on" or "off"
LOG_FILE="$STATE_DIR/events.log"
LOCK_FILE="$STATE_DIR/lock"
HDR_CACHE="$STATE_DIR/header.cache"   # last header drawn, shown instantly on the next start
HDR_LINES=13
DNSMASQ_DIR="${DNSMASQ_DIR:-/etc/dnsmasq.d}"
mkdir -p "$STATE_DIR"; touch "$FAV_FILE"
exec 9>"$LOCK_FILE"                  # fd 9 = lock shared by the menu and the watchdog service

command -v mbvpn >/dev/null 2>&1 || { echo "mbvpn not found in PATH (try: eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\")"; exit 1; }

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_RED=$(tput setaf 1)
  C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi
NEEDS_PAUSE=0   # set by warn/err so the menu waits for Enter instead of clearing a message you haven't read
ok()   { echo "${C_GREEN}$*${C_RESET}"; }
warn() { NEEDS_PAUSE=1; echo "${C_YELLOW}$*${C_RESET}"; }
err()  { NEEDS_PAUSE=1; echo "${C_RED}$*${C_RESET}"; }

# ---------- names and flags (read live from `mbvpn cities`) ----------
declare -A CNAME LNAME     # country code -> name, "cc-loc" -> city name
cname() { echo "${CNAME[$1]:-${1^^}}"; }
lname() {   # $1 = cc-loc, e.g. jp-tyo; falls back to the bare location code
  local k=$1 n=${LNAME[$1]:-}
  [[ -z $n ]] && n=${LNAME[${k%%[0-9]*}]:-}
  echo "${n:-${k#*-}}"
}

UTF8=0; [[ $(locale charmap 2>/dev/null) == UTF-8 ]] && UTF8=1
flag() {   # $1 = two-letter country code -> flag emoji (only on UTF-8 terminals)
  ((UTF8)) || return 0
  local c=${1,,} a b
  [[ $c == uk ]] && c=gb
  [[ $c =~ ^[a-z]{2}$ ]] || return 0
  printf -v a '%08x' $((0x1F1E6 + $(printf '%d' "'${c:0:1}") - 97))
  printf -v b '%08x' $((0x1F1E6 + $(printf '%d' "'${c:1:1}") - 97))
  printf "\\U$a\\U$b"
}

strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

fmt_dur() {   # seconds -> [Nd ]HH:MM:SS
  local s=$1 d h m
  d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60)); s=$((s%60))
  if ((d)); then printf '%dd %02d:%02d:%02d' "$d" "$h" "$m" "$s"; else printf '%02d:%02d:%02d' "$h" "$m" "$s"; fi
}

# ---------- status ----------
STATUS_RAW=""; CUR_SERVER=""; CUR_IP=""; CUR_COUNTRY=""; CUR_CITY=""; CUR_HANDSHAKE=""; CUR_TRANSFER=""
refresh_status() {
  STATUS_RAW=$(mbvpn status 2>&1 | strip_ansi)
  CUR_SERVER=$(sed -nE 's/.*Connected to:[[:space:]]*([^[:space:]]+).*/\1/p' <<<"$STATUS_RAW" | head -1)
  CUR_IP=$(sed -nE 's/^[[:space:]]*IP Address:[[:space:]]*(.*)$/\1/p' <<<"$STATUS_RAW" | head -1)
  CUR_COUNTRY=$(sed -nE 's/^[[:space:]]*Country:[[:space:]]*(.*)$/\1/p' <<<"$STATUS_RAW" | head -1)
  CUR_CITY=$(sed -nE 's/^[[:space:]]*City:[[:space:]]*(.*)$/\1/p' <<<"$STATUS_RAW" | head -1)
  CUR_HANDSHAKE=$(sed -nE 's/^[[:space:]]*Last handshake:[[:space:]]*(.*)$/\1/p' <<<"$STATUS_RAW" | head -1)
  CUR_TRANSFER=$(sed -nE 's/^[[:space:]]*Transfer:[[:space:]]*(.*)$/\1/p' <<<"$STATUS_RAW" | head -1)
  STATUS_TS=$SECONDS
}
STATUS_TS=-100
refresh_status_if_stale() { (( SECONDS - STATUS_TS >= 2 )) && refresh_status; return 0; }   # mbvpn status is slow: reuse a result from the last 2s

lan_info() {
  local a; a=$(ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | awk '{print $4}' | head -1)
  echo "${a:-n/a} ($LAN_IF)"
}
lan_gw() { ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }
lan_clients() {   # IPs of devices seen on the LAN (from the neighbour table)
  ip -4 neigh show dev "$LAN_IF" 2>/dev/null | awk '$NF!="FAILED" && $NF!="INCOMPLETE" {printf "%s%s", sep, $1; sep=", "}'
}

# ---------- servers ----------
SERVERS=()
load_servers() {   # asks mbvpn for the current list every time (it needs an active session)
  SERVERS=()
  local out
  out=$(mbvpn servers 2>/dev/null | strip_ansi | grep -oE '\b[a-z]{2}-[a-z0-9]+-[0-9]+\b' | sort -uV)
  [[ -n $out ]] && mapfile -t SERVERS <<<"$out"
  if ((${#SERVERS[@]} == 0)); then
    err "Could not get the server list. Is the session active? Try: mbvpn servers"
    return 1
  fi
  load_names
}

load_names() {   # parses `mbvpn cities`:  "<flag> Japan, jp"  and  "├─ Tokyo, jp-tyo"
  CNAME=(); LNAME=()
  local out k v
  out=$(mbvpn cities 2>/dev/null | strip_ansi)
  while IFS=$'\t' read -r k v; do [[ -n $k ]] && CNAME[$k]=$v; done \
    < <(sed -nE '/(├|└|│)/d; s/^[^[:alnum:]]*(.*), ([a-z]{2})$/\2\t\1/p' <<<"$out")
  while IFS=$'\t' read -r k v; do [[ -n $k ]] && LNAME[$k]=$v; done \
    < <(sed -nE 's/^.*(├|└)─ (.*), ([a-z]{2}-[a-z0-9]+)$/\3\t\2/p' <<<"$out")
}

MENU_KEYS=(); MENU_LABELS=()
build_country_menu() {   # labels like "🇯🇵 Japan (4)", sorted by name; MENU_KEYS holds the codes
  MENU_KEYS=(); MENU_LABELS=()
  local name cc n f
  while IFS='|' read -r name cc n; do
    f=$(flag "$cc"); MENU_KEYS+=("$cc"); MENU_LABELS+=("${f:+$f }$name ($n)")
  done < <(
    for cc in $(printf '%s\n' "${SERVERS[@]}" | cut -d- -f1 | sort -u); do
      printf '%s|%s|%s\n' "$(cname "$cc")" "$cc" "$(printf '%s\n' "${SERVERS[@]}" | grep -c "^$cc-")"
    done | sort -f)
}
build_location_menu() {   # $1 = country code
  MENU_KEYS=(); MENU_LABELS=()
  local name loc n
  while IFS='|' read -r name loc n; do MENU_KEYS+=("$loc"); MENU_LABELS+=("$name ($n)"); done < <(
    # us-sea and us-sea2 are the same city, so trailing digits are stripped to merge them
    for loc in $(printf '%s\n' "${SERVERS[@]}" | grep "^$1-" | cut -d- -f2 | sed -E 's/[0-9]+$//' | sort -u); do
      printf '%s|%s|%s\n' "$(lname "$1-$loc")" "$loc" "$(printf '%s\n' "${SERVERS[@]}" | grep -cE "^$1-$loc[0-9]*-")"
    done | sort -f)
}

PICKED=""; PICKED_IDX=0
pick() {   # pick "prompt" label...  -> sets PICKED (label) and PICKED_IDX
  local prompt=$1; shift
  local items=("$@") i n
  PICKED=""
  if ((${#items[@]} == 0)); then warn "Nothing to choose from."; return 1; fi
  for i in "${!items[@]}"; do
    printf '%3d) %-30s' $((i+1)) "${items[$i]}"
    (( (i+1) % 2 == 0 )) && echo
  done
  (( ${#items[@]} % 2 )) && echo
  read -r -p "$prompt (number, Enter to cancel): " n
  [[ -z $n ]] && return 1
  if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#items[@]} )); then
    PICKED=${items[$((n-1))]}; PICKED_IDX=$((n-1)); return 0
  fi
  warn "Invalid choice."; return 1
}

random_of() { local a=("$@"); ((${#a[@]})) && echo "${a[RANDOM % ${#a[@]}]}"; }

# ---------- wanted state, watchdog switch, log ----------
WANT_STATE=down; WANT_SERVER=""
read_want() {
  WANT_STATE=down; WANT_SERVER=""
  [[ -r $WANT_FILE ]] && read -r WANT_STATE WANT_SERVER < "$WANT_FILE"
  [[ $WANT_STATE == up || $WANT_STATE == down ]] || WANT_STATE=down
}
set_want()  { echo "$*" > "$WANT_FILE"; }
watch_on()  { [[ $(cat "$WATCH_FILE" 2>/dev/null) == on ]]; }
svc_active() { systemctl is-active --quiet mbvpn-watchdog 2>/dev/null; }
log_event() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }
last_event() { [[ -s $LOG_FILE ]] && tail -1 "$LOG_FILE" | cut -c12-; }

# ---------- connecting and stopping ----------
_connect_server() {   # caller must hold the lock
  local target=$1
  echo "${C_YELLOW}Switching to ${target}...${C_RESET} (the Windows VM is offline until the tunnel is up)"
  mbvpn disconnect >/dev/null 2>&1
  if mbvpn connect "$target"; then
    refresh_status
    if [[ $CUR_SERVER == "$target" ]]; then
      echo "$(date +%s) $target" > "$STATE_FILE"
      ok "Connected to $(flag "${target%%-*}") $target (${CUR_CITY:-?}, ${CUR_COUNTRY:-?}), public IP ${CUR_IP:-unknown}"
      return 0
    fi
  fi
  err "Could not confirm a connection to $target. The Windows VM stays offline (kill switch)."
  return 1
}

connect_server() {   # user-facing: takes the lock so the watchdog stays out of the way
  flock -w 120 9 || { err "Another reconnect is in progress, try again in a moment."; return 1; }
  set_want up "$1"
  _connect_server "$1"; local rc=$?
  flock -u 9
  return $rc
}

stop_vpn() {
  flock -w 120 9 || { err "Another reconnect is in progress, try again in a moment."; return 1; }
  set_want down            # tell the watchdog this is on purpose
  mbvpn disconnect
  refresh_status
  flock -u 9
  if [[ -z $CUR_SERVER ]]; then ok "VPN stopped. The Windows VM has no internet (kill switch)."
  else err "Still connected to $CUR_SERVER."; fi
}

quit_and_stop() {
  refresh_status
  [[ -z $CUR_SERVER ]] && exit 0
  echo "Stopping VPN ($CUR_SERVER)..."
  flock -w 120 9
  set_want down
  mbvpn disconnect >/dev/null 2>&1
  refresh_status
  flock -u 9
  if [[ -z $CUR_SERVER ]]; then
    ok "VPN stopped. The Windows VM has no internet (kill switch)."
    exit 0
  fi
  err "Could not stop the VPN (still connected to $CUR_SERVER), so the menu stays open."
}

rotate() {   # $1 = "country" to stay in the current country
  load_servers || return 1; refresh_status
  local pool=() s cc=${CUR_SERVER%%-*}
  for s in "${SERVERS[@]}"; do
    [[ $s == "$CUR_SERVER" ]] && continue
    [[ ${1:-} == country && -n $cc && ${s%%-*} != "$cc" ]] && continue
    pool+=("$s")
  done
  if ((${#pool[@]} == 0)); then err "No other servers available."; return 1; fi
  connect_server "$(random_of "${pool[@]}")"
}

show_status() { refresh_status; echo "$STATUS_RAW"; }

# ---------- watchdog ----------
WD_FAILS=0; RECON_TRY=0
trace() {   # trace <4|6> [timeout] -> key=value lines from Cloudflare (ip=, loc=, ...)
  local url="https://1.1.1.1/cdn-cgi/trace"
  [[ $1 == 6 ]] && url="https://[2606:4700:4700::1111]/cdn-cgi/trace"
  curl -"$1" -fsS -m "${2:-5}" "$url" 2>/dev/null
}
tval() { sed -nE "s/^$1=(.*)$/\1/p" | head -1; }

watchdog_reconnect() {
  flock -n 9 || return 0              # a manual connect/stop is in progress
  local target=$WANT_SERVER cc=${WANT_SERVER%%-*} pool=() s
  RECON_TRY=$((RECON_TRY+1))
  if (( RECON_TRY > 2 )) && load_servers >/dev/null 2>&1; then
    for s in "${SERVERS[@]}"; do      # attempts 3-4: same country, 5+: anywhere
      [[ $s == "$WANT_SERVER" ]] && continue
      (( RECON_TRY <= 4 )) && [[ ${s%%-*} != "$cc" ]] && continue
      pool+=("$s")
    done
    ((${#pool[@]})) && target=$(random_of "${pool[@]}")
  fi
  log_event "reconnect attempt $RECON_TRY to $target"
  if _connect_server "$target" >/dev/null 2>&1; then
    set_want up "$target"; log_event "reconnected to $target"; WD_FAILS=0; RECON_TRY=0
  else
    log_event "reconnect to $target failed"
  fi
  flock -u 9
}

watchdog_tick() {
  watch_on || return 0
  refresh_status
  if [[ ! -e $WANT_FILE && -n $CUR_SERVER ]]; then set_want up "$CUR_SERVER"; fi
  read_want
  [[ $WANT_STATE == up && -n $WANT_SERVER ]] || return 0
  if [[ -n $CUR_SERVER ]]; then
    if trace 4 4 >/dev/null; then WD_FAILS=0; RECON_TRY=0; return 0; fi
    WD_FAILS=$((WD_FAILS+1))
    (( WD_FAILS < 3 )) && return 0    # tolerate brief hiccups
    log_event "tunnel to $CUR_SERVER is not passing traffic"
  fi
  watchdog_reconnect
}

watchdog_loop() {
  echo "mbvpn watchdog running (checks every ${WATCH_INTERVAL}s; switch on/off with: mbvpn-menu auto on|off)"
  log_event "watchdog service started"
  local wait
  while true; do
    watchdog_tick
    wait=$WATCH_INTERVAL; (( RECON_TRY >= 5 )) && wait=$((WATCH_INTERVAL*4))   # back off when it keeps failing
    sleep "$wait"
  done
}

set_auto() {   # on|off
  if [[ $1 == on ]]; then
    echo on > "$WATCH_FILE"
    refresh_status
    [[ ! -e $WANT_FILE && -n $CUR_SERVER ]] && set_want up "$CUR_SERVER"
    ok "Auto-reconnect is ON."
    if svc_active; then echo "The background service will keep the tunnel up."
    else warn "It only runs while this menu is open. To keep it running after you quit and after reboots: mbvpn-menu install-service"; fi
  else
    echo off > "$WATCH_FILE"; ok "Auto-reconnect is OFF."
  fi
}

unit_text() {
  cat <<UNIT
[Unit]
Description=Malwarebytes VPN auto-reconnect watchdog
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
Environment=PATH=$(dirname "$(command -v mbvpn)"):/usr/local/bin:/usr/bin:/bin
ExecStart=$(readlink -f "$0") watchdog
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
}

install_service() {
  unit_text | sudo tee /etc/systemd/system/mbvpn-watchdog.service >/dev/null || return 1
  sudo systemctl daemon-reload && sudo systemctl enable --now mbvpn-watchdog || return 1
  echo on > "$WATCH_FILE"
  ok "Service installed and started. Auto-reconnect is ON."
  echo "Switch it on or off any time with the menu or: mbvpn-menu auto on|off"
}

# ---------- health and leak check ----------
CHK_OK=0; CHK_WARN=0; CHK_BAD=0
c_ok()   { CHK_OK=$((CHK_OK+1));     printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
c_warn() { CHK_WARN=$((CHK_WARN+1)); printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
c_bad()  { CHK_BAD=$((CHK_BAD+1));   printf '  %s✖%s %s\n' "$C_RED" "$C_RESET" "$*"; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

health_check() {
  CHK_OK=0; CHK_WARN=0; CHK_BAD=0
  refresh_status
  local gw clients test_ip route dev rules nat leaky t4 ip4 loc t6 ip6 ups u w r
  gw=$(lan_gw); clients=$(lan_clients)

  section "Tunnel"
  if [[ -n $CUR_SERVER ]]; then
    c_ok "Connected to $CUR_SERVER (VPN IP ${CUR_IP:-unknown})"
    if trace 4 5 >/dev/null; then c_ok "Traffic passes through the tunnel"
    else c_bad "Connected, but no traffic gets through (auto-reconnect would restart it)"; fi
  else
    c_bad "Not connected: the Windows VM has no internet"
  fi

  section "Where Windows traffic would go"
  test_ip=${clients%%,*}; [[ -n $test_ip ]] || test_ip="${gw%.*}.10"
  route=$(ip route get 1.1.1.1 iif "$LAN_IF" from "$test_ip" 2>&1)
  dev=$(sed -nE 's/.* dev ([^ ]+).*/\1/p' <<<"$route" | head -1)
  if [[ -z $dev ]]; then c_warn "Could not look up the forwarding route ($(head -1 <<<"$route"))"
  elif [[ $dev == enp* ]]; then
    if [[ -n $CUR_SERVER ]]; then c_bad "Forwarded traffic would leave via $dev, bypassing the tunnel"
    else c_warn "Tunnel is down, so routes fall back to $dev; only the firewall blocks Windows (checked below)"; fi
  else c_ok "Forwarded traffic leaves via $dev"; fi

  section "Gateway and kill switch"
  [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) == 1 ]] && c_ok "IPv4 forwarding is on" || c_bad "IPv4 forwarding is off (Windows has no route out)"
  [[ $(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null) == 0 ]] && c_ok "IPv6 forwarding is off" || c_warn "IPv6 forwarding is on"
  systemctl is-active --quiet dnsmasq 2>/dev/null && c_ok "dnsmasq is running" || c_bad "dnsmasq is not running (no DHCP/DNS for Windows)"
  if [[ -n $clients ]]; then c_ok "LAN clients seen: $clients"; else c_warn "No LAN client seen yet (has the Windows VM sent any traffic?)"; fi
  if sudo -v 2>/dev/null; then
    rules=$(sudo -n iptables -S 2>/dev/null)
    nat=$(sudo -n iptables -t nat -S POSTROUTING 2>/dev/null)
    if grep -qx -- '-P FORWARD DROP' <<<"$rules"; then c_ok "Firewall: FORWARD policy is DROP (kill switch)"
    else c_bad "Firewall: FORWARD policy is not DROP, so Windows could leave without the VPN"; fi
    if grep -- '^-A FORWARD' <<<"$rules" | grep -- "-i $LAN_IF" | grep -F -- '! -o enp+' | grep -q ACCEPT; then
      c_ok "Firewall: LAN traffic is only allowed out through the tunnel"
    else c_bad "Firewall: no rule allows LAN traffic out through the tunnel"; fi
    leaky=$(grep -- '^-A FORWARD' <<<"$rules" | grep -- "-i $LAN_IF" | grep ACCEPT | grep -vF -- '! -o enp+')
    [[ -z $leaky ]] && c_ok "Firewall: nothing lets LAN traffic out via the real connection" \
                    || c_bad "Firewall: a FORWARD rule lets LAN traffic leave via the real connection: $leaky"
    grep -q -- 'MASQUERADE' <<<"$nat" && c_ok "NAT: masquerade is set up" || c_bad "NAT: no masquerade rule (Windows replies would not come back)"
    grep -qx -- "-A INPUT -i $LAN_IF -j DROP" <<<"$rules" && c_ok "Firewall: Windows can only use DHCP, DNS and ping on this VM" \
                                                         || c_warn "Firewall: no catch-all DROP for LAN input (Windows may reach services here)"
    sudo -n ip6tables -S FORWARD 2>/dev/null | grep -qx -- '-P FORWARD DROP' && c_ok "Firewall: IPv6 forwarding is dropped" || c_warn "Firewall: IPv6 FORWARD policy is not DROP"
    sudo -n test -f /etc/iptables/rules.v4 && c_ok "Firewall rules are saved for the next boot" || c_warn "No saved rules in /etc/iptables/rules.v4 (run: sudo netfilter-persistent save)"
  else
    c_warn "Firewall rules not checked (sudo is needed to read them)"
  fi
  if watch_on; then
    if svc_active; then c_ok "Auto-reconnect is on (background service running)"
    else c_warn "Auto-reconnect is on but only while the menu is open (mbvpn-menu install-service)"; fi
  else c_warn "Auto-reconnect is off"; fi

  section "DNS"
  r=$(dig +short +time=3 +tries=1 example.com @"$gw" 2>/dev/null | head -1)
  [[ -n $r ]] && c_ok "dnsmasq on $gw answers (example.com -> $r)" || c_bad "dnsmasq on $gw did not answer"
  ups=$(grep -hE '^[[:space:]]*server=' "$DNSMASQ_DIR"/*.conf /etc/dnsmasq.conf 2>/dev/null | cut -d= -f2 | sort -u)
  if [[ -n $ups ]]; then
    c_ok "dnsmasq upstream resolvers: $(echo $ups)"
    grep -qhE '^[[:space:]]*no-resolv' "$DNSMASQ_DIR"/*.conf /etc/dnsmasq.conf 2>/dev/null \
      && c_ok "dnsmasq ignores /etc/resolv.conf (no-resolv)" || c_warn "no-resolv is not set: dnsmasq may also use other resolvers"
  else c_warn "Could not read dnsmasq upstream servers"; fi
  t4=$(trace 4 5); ip4=$(tval ip <<<"$t4"); loc=$(tval loc <<<"$t4")
  for u in $ups; do
    [[ $u =~ ^[0-9.]+$ ]] || continue
    w=$(dig +short +time=3 +tries=1 ch txt whoami.cloudflare @"$u" 2>/dev/null | tr -d '"' | head -1)
    [[ -n $w ]] || continue                 # only Cloudflare resolvers answer this
    if [[ -n $ip4 && $w == "$ip4" ]]; then c_ok "Resolver $u sees your queries coming from $w (the tunnel's exit IP)"
    else c_bad "Resolver $u sees your queries coming from $w, not the tunnel's exit IP ${ip4:-unknown}: DNS may leak"; fi
  done

  section "Public IP"
  if [[ -z $ip4 ]]; then c_bad "No IPv4 connectivity through the tunnel"
  elif [[ -z $CUR_SERVER ]]; then c_warn "VPN is down: this VM reaches the internet directly as $ip4 (only the firewall keeps Windows off the internet)"
  else
    if [[ -n $CUR_IP && $ip4 == "$CUR_IP" ]]; then c_ok "IPv4 exit address $ip4 matches the VPN's IP"
    else c_warn "IPv4 exit address $ip4 differs from mbvpn's $CUR_IP (may be a separate exit address; just make sure it is not your real IP)"; fi
    if [[ -n $loc ]]; then
      [[ ${loc,,} == "${CUR_SERVER%%-*}" ]] && c_ok "Exit country $loc matches the server" || c_warn "Exit country is $loc but the server is ${CUR_SERVER%%-*}"
    fi
  fi
  t6=$(trace 6 5); ip6=$(tval ip <<<"$t6")
  if [[ -n $ip6 && -z $CUR_SERVER ]]; then c_warn "This VM has direct IPv6 ($ip6) because the VPN is down. The Windows VM gets none (no router advertisements, forwarding dropped)"
  elif [[ -n $ip6 ]]; then c_warn "This VM has IPv6 through the tunnel ($ip6). The Windows VM gets none (no router advertisements, forwarding dropped)"
  else c_ok "No IPv6 path, so nothing can leak over IPv6"; fi

  printf '\n%s%d passed%s, %s%d warnings%s, %s%d problems%s\n' "$C_GREEN" $CHK_OK "$C_RESET" "$C_YELLOW" $CHK_WARN "$C_RESET" "$C_RED" $CHK_BAD "$C_RESET"
  echo "These checks run on Debian. For the Windows side, open a leak-test site in Windows"
  echo "(for example ipleak.net) and confirm the IP and DNS servers shown belong to the VPN."
}

# ---------- menus ----------
menu_favorite() {
  mapfile -t favs < <(grep -v '^[[:space:]]*$' "$FAV_FILE")
  if ((${#favs[@]} == 0)); then warn "No favorites yet. Add some under 'Manage favorites'."; return 1; fi
  pick "Favorite" "${favs[@]}" && connect_server "$PICKED"
}

menu_country() {
  load_servers || return 1
  build_country_menu
  pick "Country" "${MENU_LABELS[@]}" || return 1
  local cc=${MENU_KEYS[$PICKED_IDX]} pool=() s
  for s in "${SERVERS[@]}"; do [[ ${s%%-*} == "$cc" && $s != "$CUR_SERVER" ]] && pool+=("$s"); done
  ((${#pool[@]})) || pool=($(printf '%s\n' "${SERVERS[@]}" | grep "^$cc-"))
  connect_server "$(random_of "${pool[@]}")"
}

menu_location() {
  load_servers || return 1
  build_country_menu
  pick "Country" "${MENU_LABELS[@]}" || return 1
  local cc=${MENU_KEYS[$PICKED_IDX]}
  build_location_menu "$cc"
  pick "City in $(cname "$cc")" "${MENU_LABELS[@]}" || return 1
  local loc=${MENU_KEYS[$PICKED_IDX]} pool=() s
  for s in "${SERVERS[@]}"; do [[ $s =~ ^$cc-$loc[0-9]*-[0-9]+$ && $s != "$CUR_SERVER" ]] && pool+=("$s"); done
  ((${#pool[@]})) || pool=($(printf '%s\n' "${SERVERS[@]}" | grep -E "^$cc-$loc[0-9]*-"))
  connect_server "$(random_of "${pool[@]}")"
}

menu_server() {
  load_servers || return 1
  pick "Server" "${SERVERS[@]}" && connect_server "$PICKED"
}

menu_rotate() {
  echo "  1) Any country"; echo "  2) Stay in the current country"
  read -r -p "Rotate (Enter to cancel): " c
  case $c in 1) rotate any ;; 2) rotate country ;; *) return 1 ;; esac
}

menu_favorites_manage() {
  while true; do
    echo; echo "Favorites: $(grep -v '^[[:space:]]*$' "$FAV_FILE" | tr '\n' ' ')"
    echo "  1) Add current server  2) Add a server  3) Remove one  4) Back"
    read -r -p "> " c
    case $c in
      1) refresh_status
         if [[ -n $CUR_SERVER ]]; then grep -qx "$CUR_SERVER" "$FAV_FILE" || echo "$CUR_SERVER" >> "$FAV_FILE"; ok "Added $CUR_SERVER"
         else warn "Not connected."; fi ;;
      2) load_servers && pick "Server" "${SERVERS[@]}" && { grep -qx "$PICKED" "$FAV_FILE" || echo "$PICKED" >> "$FAV_FILE"; ok "Added $PICKED"; } ;;
      3) mapfile -t favs < <(grep -v '^[[:space:]]*$' "$FAV_FILE")
         pick "Remove" "${favs[@]}" && { grep -vx "$PICKED" "$FAV_FILE" > "$FAV_FILE.tmp"; mv "$FAV_FILE.tmp" "$FAV_FILE"; ok "Removed $PICKED"; } ;;
      4|"") return 0 ;;
    esac
  done
}

toggle_watchdog() { if watch_on; then set_auto off; else set_auto on; fi; }

update_mbvpn() {
  warn "This may drop the tunnel. After updating, reconnect from the menu."
  read -r -p "Update mbvpn with Homebrew? [y/N] " a
  [[ $a == [yY]* ]] || return 1
  if command -v brew >/dev/null 2>&1; then
    brew update && brew upgrade malwarebytes/tap/mbvpn
    sudo setcap cap_net_admin,cap_net_raw+eip "$(readlink -f "$(command -v mbvpn)")" && ok "Capabilities reapplied."
  else err "brew not found."; fi
}

# ---------- UI ----------
HDR=()      # always exactly 13 lines, so it can be redrawn in place
MENU_ROWS=29

wd_text() {
  local t
  if watch_on; then
    if svc_active; then t="ON (service)"; else t="ON (menu only)"; fi
  else t="OFF"; fi
  local last; last=$(last_event)
  echo "Auto-reconnect: $t${last:+ - last: $last}"
}

build_header() {
  refresh_status_if_stale
  [[ ! -e $WANT_FILE && -n $CUR_SERVER ]] && set_want up "$CUR_SERVER"
  read_want
  HDR=()
  local ts="" srv="" f fwd dns clients since
  HDR+=("@HASH@" "@TITLE@" "@HASH@")
  HDR+=("Current system time: $(date +%H:%M:%S)")
  HDR+=("VPN gateway (LAN): $(lan_info)")
  fwd=OFF; [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) == 1 ]] && fwd=on
  dns=$(systemctl is-active dnsmasq 2>/dev/null); clients=$(lan_clients)
  local l6="LAN clients: ${clients:-none seen} | forwarding: $fwd | dnsmasq: ${dns:-unknown}"
  HDR+=("${l6:0:78}")
  local l7; l7=$(wd_text); HDR+=("${l7:0:78}")
  HDR+=("@HASH@")
  [[ -r $STATE_FILE ]] && read -r ts srv < "$STATE_FILE"
  if [[ -n $CUR_SERVER ]]; then
    f=$(flag "${CUR_SERVER%%-*}")
    HDR+=("Currently connected to: ${f:+$f }${C_GREEN}${C_BOLD}${CUR_SERVER}${C_RESET} ${CUR_CITY:+- $CUR_CITY}${CUR_COUNTRY:+, $CUR_COUNTRY}")
    HDR+=("Public IP: ${CUR_IP:-unknown}")
    if [[ $srv == "$CUR_SERVER" && -n $ts ]]; then
      since=$(( $(date +%s) - ts )); (( since < 0 )) && since=0
      HDR+=("Connected for $(fmt_dur "$since") (since $(date -d "@$ts" '+%a %b %-d %H:%M:%S %Z %Y'))")
    else
      HDR+=("Connected for: unknown (started outside this menu)")
    fi
    HDR+=("Traffic: ${CUR_TRANSFER:-n/a}")
  else
    HDR+=("${C_RED}${C_BOLD}Not connected${C_RESET} - the Windows VM has no internet.")
    if [[ -n $srv ]]; then HDR+=("Last server: $srv"); else HDR+=("No connection made from this menu yet."); fi
    if [[ ! -e $WANT_FILE ]]; then HDR+=("Nothing requested yet.")
    elif [[ $WANT_STATE == up ]] && watch_on; then HDR+=("Auto-reconnect is trying to restore ${WANT_SERVER}.")
    elif [[ $WANT_STATE == up ]]; then HDR+=("Wanted: ${WANT_SERVER} (auto-reconnect is off).")
    else HDR+=("Stopped on purpose."); fi
    HDR+=("Choose 3, 4, 5 or 6 to connect.")
  fi
  HDR+=("@HASH@")
  fit_borders
  printf '%s\n' "${HDR[@]}" > "$HDR_CACHE" 2>/dev/null
}

fit_borders() {   # make the ### borders as wide as the longest header line (min 52, max 78)
  local line plain maxw=52 i hash title l r
  for line in "${HDR[@]}"; do
    [[ $line == @HASH@ || $line == @TITLE@ ]] && continue
    plain=$(strip_ansi <<<"$line"); (( ${#plain} > maxw )) && maxw=${#plain}
  done
  (( maxw > 78 )) && maxw=78
  hash=$(printf '#%.0s' $(seq "$maxw"))
  title=" MBVPN ROTATOR v${VERSION} "
  l=$(( (maxw - ${#title}) / 2 )); r=$(( maxw - ${#title} - l ))
  for i in "${!HDR[@]}"; do
    case ${HDR[$i]} in
      @HASH@)  HDR[$i]="${C_CYAN}${hash}${C_RESET}" ;;
      @TITLE@) HDR[$i]="${C_CYAN}$(printf '#%.0s' $(seq "$l"))${title}$(printf '#%.0s' $(seq "$r"))${C_RESET}" ;;
    esac
  done
}

print_header() { local line; for line in "${HDR[@]}"; do printf '%s\e[K\n' "$line"; done; }

redraw_header() {   # update the top of the screen without moving the cursor or touching typed input
  build_header
  printf '\e7\e[H'; print_header; printf '\e8'
}

pause() { echo; read -r -p "Press Enter to continue..." _ || exit 0; }
pause_if_needed() { ((NEEDS_PAUSE)) && pause; }

print_menu() {
  local wd=OFF; watch_on && wd=ON
  cat <<MENU
1) Check VPN connection status
2) Start VPN from favorite
3) Start VPN in new country
4) Start VPN in new city
5) Start VPN on a specific server
6) Rotate VPN
7) Manage favorites
8) Stop VPN (no internet connection)
9) Health and leak check
10) Auto-reconnect watchdog: ${wd}  (toggle)
11) Update mbvpn
12) Quit and stop VPN

MENU
}

PROMPT="Enter your choice and press [ENTER]: "
CHOICE=""
can_refresh() {   # auto-refresh needs a terminal that is tall enough
  local rows; rows=$(tput lines 2>/dev/null || echo 0)
  [[ -t 0 && -t 1 ]] && (( REFRESH > 0 && rows >= MENU_ROWS ))
}

load_header_cache() {
  [[ -s $HDR_CACHE ]] || return 1
  mapfile -t HDR < "$HDR_CACHE"
  (( ${#HDR[@]} == HDR_LINES ))
}

read_choice() {   # reads CHOICE; "noprompt" = the prompt is already on screen. Refreshes the header every $REFRESH seconds while idle
  CHOICE=""
  local rc pending="" first=1 prompt=(-p "$PROMPT")
  [[ ${1:-} == noprompt ]] && prompt=()
  if can_refresh; then
    while true; do
      if ((first)); then read -r -t "$REFRESH" "${prompt[@]}" CHOICE; rc=$?; first=0
      else read -r -t "$REFRESH" CHOICE; rc=$?; fi
      if (( rc > 128 )); then
        pending+=$CHOICE
        watch_on && ! svc_active && watchdog_tick
        redraw_header; continue
      fi
      (( rc == 0 )) || exit 0
      CHOICE=$pending$CHOICE; return 0
    done
  else
    read -r -p "$PROMPT" CHOICE || exit 0
  fi
}

main_menu() {
  local choice first=1
  while true; do
    if ((first)) && can_refresh && load_header_cache; then
      # paint the last known header at once, then replace it with live data in place
      clear 2>/dev/null; print_header; echo; print_menu; printf '%s' "$PROMPT"
      redraw_header
      read_choice noprompt
    else
      build_header; clear 2>/dev/null; print_header; echo
      print_menu
      read_choice
    fi
    first=0
    choice=$CHOICE
    NEEDS_PAUSE=0
    echo
    case $choice in
      "") ;;
      1) show_status; pause ;;
      2) menu_favorite; pause_if_needed ;;
      3) menu_country; pause_if_needed ;;
      4) menu_location; pause_if_needed ;;
      5) menu_server; pause_if_needed ;;
      6) menu_rotate; pause_if_needed ;;
      7) menu_favorites_manage ;;
      8) stop_vpn; pause ;;
      9) health_check; pause ;;
      10) toggle_watchdog; pause ;;
      11) update_mbvpn; pause ;;
      12) quit_and_stop; pause ;;
      *) warn "Unknown choice."; sleep 1 ;;
    esac
  done
}

# ---------- entry point ----------
[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0     # sourced (for tests): define functions only
case "${1:-}" in
  "")      main_menu ;;
  status)  show_status ;;
  rotate)  rotate "${2:-any}" ;;
  connect) [[ -n ${2:-} ]] || { err "Usage: $0 connect <server>"; exit 1; }; connect_server "$2" ;;
  stop)    stop_vpn ;;
  list)    load_servers && printf '%s\n' "${SERVERS[@]}" ;;
  check)   health_check ;;
  auto)    case "${2:-status}" in
             on|off) set_auto "$2" ;;
             *) if watch_on; then echo "Auto-reconnect is ON"; else echo "Auto-reconnect is OFF"; fi ;;
           esac ;;
  watchdog)        watchdog_loop ;;
  install-service) install_service ;;
  service)         unit_text ;;
  log)     [[ -s $LOG_FILE ]] && tail -20 "$LOG_FILE" || echo "No watchdog events yet." ;;
  *)       echo "Usage: $0 [status|rotate [country]|connect <server>|stop|list|check|auto on|off|watchdog|install-service|service|log]"; exit 1 ;;
esac

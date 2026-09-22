#!/usr/bin/env bash
set -Eeuo pipefail

# Interstellar Network Toolbox
# Supports Debian and Ubuntu.
# Start without arguments for the interactive menu.

VERSION="4.3.2"
BACKUP_DIR="/var/backups/interstellar-toolbox"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-interstellar-hardening.conf"
MANAGER_INSTALL_PATH="/usr/local/sbin/interstellar-toolbox"
RELEASE_REPO="${INTERSTELLAR_RELEASE_REPO:-interstellarforge/interstellar-network-node}"
RELEASE_ASSET="interstellar-network-toolbox.sh"
RELEASE_SUMS_ASSET="SHA256SUMS"

# Deliberately root-only. A normal user must explicitly invoke this with sudo.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Interstellar Network Toolbox is root-only."
  echo "Run it with:"
  echo "  sudo $0"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot determine operating system."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *)
    echo "Unsupported OS: ${PRETTY_NAME:-unknown}"
    echo "This script currently supports Debian and Ubuntu."
    exit 1
    ;;
esac


# The toolbox uses whiptail for its complete TUI.
if ! command -v whiptail >/dev/null 2>&1; then
  echo "Interstellar Network Toolbox needs 'whiptail'. Installing it now..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
fi

UI_BACKTITLE="Interstellar Network Toolbox v${VERSION} | $(hostname)"

ui_menu() {
  local title="$1" text="$2"
  shift 2
  whiptail --clear --backtitle "$UI_BACKTITLE" --title "$title" \
    --menu "$text" 23 88 15 "$@" 3>&1 1>&2 2>&3
}

ui_yesno() {
  whiptail --clear --backtitle "$UI_BACKTITLE" --title "$1" \
    --yesno "$2" 13 82
}

ui_msg() {
  whiptail --clear --backtitle "$UI_BACKTITLE" --title "$1" \
    --msgbox "$2" 16 86
}

ui_input() {
  local title="$1" msg="$2" default="${3:-}"
  whiptail --clear --backtitle "$UI_BACKTITLE" --title "$title" \
    --inputbox "$msg" 14 86 "$default" 3>&1 1>&2 2>&3
}

ui_radiolist() {
  local title="$1" msg="$2"
  shift 2
  whiptail --clear --backtitle "$UI_BACKTITLE" --title "$title" \
    --radiolist "$msg" 24 96 14 "$@" 3>&1 1>&2 2>&3
}

ui_checklist() {
  local title="$1" msg="$2"
  shift 2
  whiptail --clear --backtitle "$UI_BACKTITLE" --title "$title" \
    --checklist "$msg" 26 98 16 "$@" 3>&1 1>&2 2>&3
}

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; RESET=""
fi

ok()   { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
fix()  { printf '%s[FIX]%s %s\n' "$BLUE" "$RESET" "$*"; }

pause() {
  echo
  read -r -p "Press Enter to continue..." _
}

header() {
  clear 2>/dev/null || true
  cat <<'EOF'
 .   .     .. .  ..   . .               .     ....
.  .          .. .         .  .  . . .     . . ..
. . .       .          ............            ..
    ..     .  . ..:-==++=========---:..
. .        ..-++***#**+==--=-:.:=++=+++=:.    .
   . .  .:*#****#######**++=:..   .:=+++=-.    ..
.     .=#########%######***++=-:....:=++==-.
.   .:##########%%######*++++++=----::--=--:.
 . .:############%#####***+++++++=====-----:..  .
  ..%%###########%%#####****++***+++++===--::. ..
   +%%%%%#######%%%###************+++++++==-:.
  .+@%%%%%#####%%%%#####**********++++++++==-:.  .
   .%@%%%%%#############*********+++++++++==-:.
   .:@@%%%%################******+====++++==--.
.   .-%@%%%%###############******++=--======-:.
      :%@%%%%#############*******++=-::--::..    .
      ..*@%%%###########*******+++==-. . . .
   .  . .-#%%%#######********++++=-:... .     .. .
          .:=***#*********+++==-:... .  .. .   . .
  . . ..      .....:::::::......   .
  .     .    .   .  .     .    .. .   .      .  .
         ..  .. .  .       ..    .              .
EOF
  printf '\n%sInterstellar Network Toolbox%s v%s | %s | %s\n\n' \
    "$BOLD" "$RESET" "$VERSION" "$(hostname)" "${PRETTY_NAME:-Linux}"
}

confirm() {
  ui_yesno "Confirm" "${1:-Continue?}"
}

backup_file() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$file" "${BACKUP_DIR}/$(basename "$file").${stamp}.bak"
}

is_installed() {
  local pkg="$1"

  # Debian 13 resolves dnsutils to bind9-dnsutils.
  if [[ "$pkg" == "dnsutils" ]]; then
    dpkg-query -W -f='${Status}' bind9-dnsutils 2>/dev/null | grep -q "ok installed" && return 0
  fi

  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"
}

install_pkg() {
  local pkg="$1"
  if ! is_installed "$pkg"; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
}

detect_lan_cidr() {
  local default_if
  default_if="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [[ -n "$default_if" ]] || return 1
  ip -4 route show dev "$default_if" proto kernel scope link 2>/dev/null |
    awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1; exit}'
}

# ---------------- Health check ----------------

time_sync_backend() {
  if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    echo "systemd-timesyncd"
  elif systemctl list-unit-files chrony.service >/dev/null 2>&1; then
    echo "chrony"
  elif systemctl list-unit-files chronyd.service >/dev/null 2>&1; then
    echo "chronyd"
  else
    echo "none"
  fi
}

time_sync_is_active() {
  local backend
  backend="$(time_sync_backend)"
  case "$backend" in
    systemd-timesyncd) systemctl is-active --quiet systemd-timesyncd ;;
    chrony) systemctl is-active --quiet chrony ;;
    chronyd) systemctl is-active --quiet chronyd ;;
    *) return 1 ;;
  esac
}

time_sync_is_synchronized() {
  local sync
  sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ "$sync" == "yes" ]] && return 0

  if command -v chronyc >/dev/null 2>&1; then
    chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal$' && return 0
  fi

  return 1
}

fix_time_sync() {
  local backend
  backend="$(time_sync_backend)"

  if [[ "$backend" == "none" ]]; then
    info "Installing systemd-timesyncd..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-timesyncd
    backend="systemd-timesyncd"
  fi

  case "$backend" in
    systemd-timesyncd) systemctl enable --now systemd-timesyncd ;;
    chrony) systemctl enable --now chrony ;;
    chronyd) systemctl enable --now chronyd ;;
  esac

  sleep 2

  if time_sync_is_synchronized; then
    fix "System time synchronized via $backend"
  elif time_sync_is_active; then
    warn "$backend is active, but synchronization has not completed yet"
    info "Check with: timedatectl status"
    [[ "$backend" == "systemd-timesyncd" ]] && info "And: timedatectl timesync-status"
  else
    fail "Could not start an NTP synchronization service"
  fi
}


health_check() {
  local fix_mode="${1:-0}"
  header
  echo "${BOLD}Health check${RESET}"
  echo "------------------------------------------------------------"

  local packages=(
    sudo ca-certificates curl wget git gnupg bash-completion
    vim nano less man-db procps iproute2 iputils-ping dnsutils
    rsync unzip zip tmux htop jq ripgrep
  )
  local missing=()

  for pkg in "${packages[@]}"; do
    if is_installed "$pkg"; then
      ok "Package: $pkg"
    else
      warn "Missing package: $pkg"
      missing+=("$pkg")
    fi
  done

  if [[ "$fix_mode" -eq 1 && "${#missing[@]}" -gt 0 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fix "Installed missing baseline packages"
  fi

  if is_installed openssh-server; then
    ok "OpenSSH server installed"
  else
    warn "OpenSSH server missing"
    if [[ "$fix_mode" -eq 1 ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
      fix "Installed OpenSSH server"
    fi
  fi

  if systemctl is-active --quiet ssh 2>/dev/null; then
    ok "SSH service running"
  else
    warn "SSH service not running"
    if [[ "$fix_mode" -eq 1 ]]; then
      systemctl enable --now ssh
      fix "Started SSH"
    fi
  fi

  if command -v sshd >/dev/null 2>&1; then
    local effective
    effective="$(sshd -T 2>/dev/null || true)"
    grep -q '^permitrootlogin no$' <<<"$effective" \
      && ok "SSH root login disabled" \
      || warn "SSH root login not fully disabled"
    grep -q '^passwordauthentication no$' <<<"$effective" \
      && ok "SSH password login disabled" \
      || warn "SSH password login enabled"
    grep -q '^pubkeyauthentication yes$' <<<"$effective" \
      && ok "SSH key authentication enabled" \
      || warn "SSH key authentication not enabled"
  fi

  if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale installed"
    if systemctl is-active --quiet tailscaled; then
      ok "tailscaled running"
    else
      warn "tailscaled not running"
      if [[ "$fix_mode" -eq 1 ]]; then
        systemctl enable --now tailscaled
        fix "Started tailscaled"
      fi
    fi

    if tailscale status >/dev/null 2>&1; then
      ok "Tailscale connected ($(tailscale ip -4 2>/dev/null || echo 'no IPv4'))"
    else
      warn "Tailscale installed but not connected"
      info "Use menu 6 -> Connect / login Tailscale"
    fi
  else
    warn "Tailscale not installed"
    info "Use menu 6 -> Install Tailscale"
  fi

  if is_installed unattended-upgrades; then
    ok "unattended-upgrades installed"
  else
    warn "unattended-upgrades missing"
    if [[ "$fix_mode" -eq 1 ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
      fix "Installed unattended-upgrades"
    fi
  fi

  local auto_cfg="/etc/apt/apt.conf.d/20auto-upgrades"
  if [[ -f "$auto_cfg" ]] &&
     grep -q 'APT::Periodic::Update-Package-Lists "1"' "$auto_cfg" &&
     grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$auto_cfg"; then
    ok "Automatic updates enabled"
  else
    warn "Automatic updates not fully enabled"
    if [[ "$fix_mode" -eq 1 ]]; then
      cat >"$auto_cfg" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
      fix "Enabled unattended updates"
    fi
  fi

  if grep -RqsE 'Unattended-Upgrade::Automatic-Reboot[[:space:]]+"true"' /etc/apt/apt.conf.d 2>/dev/null; then
    warn "Automatic reboot is enabled"
  else
    ok "Automatic reboot is disabled"
  fi

  local time_backend
  time_backend="$(time_sync_backend)"
  if time_sync_is_synchronized; then
    ok "System time synchronized via $time_backend"
  elif time_sync_is_active; then
    warn "$time_backend is active, but time is not yet reported synchronized"
    if [[ "$fix_mode" -eq 1 ]]; then
      fix_time_sync
    fi
  else
    warn "No active NTP synchronization service"
    if [[ "$fix_mode" -eq 1 ]]; then
      fix_time_sync
    fi
  fi

  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  info "Virtualization: ${virt:-none detected}"

  case "$virt" in
    kvm|qemu)
      if is_installed qemu-guest-agent; then
        ok "QEMU Guest Agent installed"
      else
        warn "QEMU Guest Agent missing"
        if [[ "$fix_mode" -eq 1 ]]; then
          apt-get update
          DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent
          fix "Installed QEMU Guest Agent"
        fi
      fi
      if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
        ok "QEMU guest-agent channel present"
        if systemctl is-active --quiet qemu-guest-agent; then
          ok "QEMU Guest Agent running"
        else
          warn "QEMU Guest Agent not running"
          if [[ "$fix_mode" -eq 1 ]]; then
            systemctl start qemu-guest-agent || true
            fix "Attempted to start QEMU Guest Agent"
          fi
        fi
      else
        warn "QEMU guest-agent channel missing in guest"
      fi
      ;;
    lxc)
      ok "LXC detected; QEMU Guest Agent not required"
      ;;
  esac

  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q '^Status: active'; then
      ok "UFW firewall active"
    else
      warn "UFW installed but inactive"
    fi
  else
    warn "UFW not installed"
  fi

  [[ -s /etc/motd ]] && ok "Startup text present" || warn "Startup text empty/missing"

  local failed_units
  failed_units="$(systemctl --failed --no-legend 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')"
  [[ "$failed_units" == "0" ]] \
    && ok "No failed systemd services" \
    || warn "$failed_units failed systemd service(s)"

  info "Root disk: $(df -h / | awk 'NR==2 {print $5 " used (" $3 "/" $2 ")"}')"
  info "Memory: $(free -h | awk '/Mem:/ {print $3 " used / " $2}')"
  info "Uptime: $(uptime -p 2>/dev/null || true)"

  [[ -f /var/run/reboot-required ]] \
    && warn "System reboot required" \
    || ok "No reboot required"

  # Manager file security
  local self_path self_owner self_mode
  self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [[ -f "$self_path" ]]; then
    self_owner="$(stat -c '%U:%G' "$self_path" 2>/dev/null || echo '?')"
    self_mode="$(stat -c '%a' "$self_path" 2>/dev/null || echo '?')"
    if [[ "$self_owner" == "root:root" && "$self_mode" == "700" ]]; then
      ok "Server Manager is root-owned and mode 0700"
    else
      warn "Server Manager permissions are $self_owner mode $self_mode"
      info "Use menu 9 to install/secure it as root:root 0700."
    fi
  fi

  # Admin users
  local sudo_members
  sudo_members="$(getent group sudo 2>/dev/null | awk -F: '{print $4}')"
  if [[ -n "$sudo_members" ]]; then
    info "sudo-group users: $sudo_members"
  else
    warn "No users listed in the sudo group"
  fi

  echo
  info "Listening TCP sockets (firewall may still restrict access):"
  ss -lntp 2>/dev/null | sed 's/^/  /' || true

  echo
  if [[ "$fix_mode" -eq 1 ]]; then
    info "Minor fixes do NOT change SSH auth, firewall rules, passwords, MOTD, or Tailscale login state."
  else
    info "Check-only mode: no changes made."
  fi
}

health_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Health check" "Audit this server." \
      "1" "Check only" \
      "2" "Check and minor safe fixes" \
      "0" "Back")" || return
    case "$choice" in
      1) health_check 0; pause ;;
      2) health_check 1; pause ;;
      0) return ;;
    esac
  done
}

# ---------------- Passwords ----------------

choose_regular_user() {
  local users=()
  mapfile -t users < <(
    getent passwd |
      awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" && $7 !~ /(nologin|false)$/ {print $1}'
  )
  [[ "${#users[@]}" -gt 0 ]] || return 1

  local opts=() u state="ON"
  for u in "${users[@]}"; do
    opts+=("$u" "Home: $(getent passwd "$u" | cut -d: -f6)" "$state")
    state="OFF"
  done

  ui_radiolist "Select user" "Choose the normal Linux user." "${opts[@]}"
}

password_menu() {
  while true; do
    local choice user
    choice="$(ui_menu "Passwords" "Change a local account password." \
      "1" "Change root password" \
      "2" "Change user password" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; passwd root; pause ;;
      2) user="$(choose_regular_user)" || continue; clear; passwd "$user"; pause ;;
      0) return ;;
    esac
  done
}

# ---------------- Firewall ----------------

ensure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    info "Installing UFW..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
  fi
}

firewall_close_all() {
  ensure_ufw
  local phrase
  phrase="$(ui_input "DANGER: close all inbound" \
"This resets UFW and DENIES ALL new inbound connections.

SSH over LAN and Tailscale will also be blocked until allow rules are added.
Prefer doing this from a Proxmox/local console.

Type exactly: CLOSE ALL" "")" || return
  [[ "$phrase" == "CLOSE ALL" ]] || { ui_msg "Cancelled" "Firewall reset cancelled."; return; }

  backup_file /etc/ufw/user.rules
  backup_file /etc/ufw/user6.rules
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ui_msg "Firewall" "All unsolicited inbound traffic is now blocked."
}

firewall_open_tailscale() {
  ensure_ufw
  if ! ip link show tailscale0 >/dev/null 2>&1; then
    warn "tailscale0 does not currently exist."
    confirm "Add the rule anyway?" || return
  fi
  ufw allow in on tailscale0
  ufw --force enable
  fix "Allowed all inbound traffic via tailscale0."
}

firewall_open_lan() {
  ensure_ufw
  local detected cidr
  detected="$(detect_lan_cidr || true)"
  cidr="$(ui_input "Open for LAN" "Allow all inbound traffic from this LAN CIDR:" "${detected:-192.168.1.0/24}")" || return
  [[ -n "$cidr" ]] || return
  ufw allow from "$cidr"
  ufw --force enable
  ui_msg "Firewall" "Allowed all inbound traffic from $cidr."
}

firewall_open_ports() {
  ensure_ufw
  local ports proto scope source cidr
  ports="$(ui_input "Open port" "Port or range (examples: 22, 3000, 8000:8010):" "")" || return
  [[ -n "$ports" ]] || return

  proto="$(ui_radiolist "Protocol" "Choose protocol." \
    "tcp" "TCP" ON \
    "udp" "UDP" OFF \
    "both" "TCP + UDP" OFF)" || return

  scope="$(ui_radiolist "Source" "Who may connect to this port?" \
    "any" "Anywhere" OFF \
    "tailscale" "Tailscale only" ON \
    "lan" "LAN only" OFF \
    "custom" "Custom CIDR / IP" OFF)" || return

  case "$scope" in
    any) source="any" ;;
    tailscale) source="tailscale" ;;
    lan)
      cidr="$(detect_lan_cidr || true)"
      source="$(ui_input "LAN source" "LAN CIDR:" "${cidr:-192.168.1.0/24}")" || return
      ;;
    custom) source="$(ui_input "Custom source" "Source CIDR or IP:" "")" || return ;;
  esac

  add_rule() {
    local p="$1"
    if [[ "$source" == "any" ]]; then
      ufw allow "$ports/$p"
    elif [[ "$source" == "tailscale" ]]; then
      ufw allow in on tailscale0 to any port "$ports" proto "$p"
    else
      ufw allow from "$source" to any port "$ports" proto "$p"
    fi
  }

  case "$proto" in
    tcp) add_rule tcp ;;
    udp) add_rule udp ;;
    both) add_rule tcp; add_rule udp ;;
  esac

  ufw --force enable
  ui_msg "Firewall" "Firewall rule(s) added."
}

firewall_delete_rule() {
  ensure_ufw
  local tmp num
  tmp="$(mktemp)"
  ufw status numbered >"$tmp"
  whiptail --backtitle "$UI_BACKTITLE" --title "Firewall rules" --scrolltext --textbox "$tmp" 26 100
  rm -f "$tmp"
  num="$(ui_input "Delete firewall rule" "Enter the UFW rule number to delete:" "")" || return
  [[ "$num" =~ ^[0-9]+$ ]] || return
  ufw --force delete "$num"
  ui_msg "Firewall" "Deleted UFW rule $num."
}

firewall_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Firewall" "Manage UFW firewall rules." \
      "1" "Close all inbound" \
      "2" "Open all inbound via Tailscale" \
      "3" "Open all inbound from LAN" \
      "4" "Open certain ports" \
      "5" "Show firewall rules" \
      "6" "Delete a firewall rule" \
      "0" "Back")" || return
    case "$choice" in
      1) firewall_close_all; pause ;;
      2) firewall_open_tailscale; pause ;;
      3) firewall_open_lan; pause ;;
      4) firewall_open_ports; pause ;;
      5) clear; ensure_ufw; ufw status numbered; pause ;;
      6) firewall_delete_rule; pause ;;
      0) return ;;
    esac
  done
}

# ---------------- MOTD ----------------

default_motd() {
  cat <<EOF
 .   .     .. .  ..   . .               .     ....
.  .          .. .         .  .  . . .     . . ..
. . .       .          ............            ..
    ..     .  . ..:-==++=========---:..
. .        ..-++***#**+==--=-:.:=++=+++=:.    .
   . .  .:*#****#######**++=:..   .:=+++=-.    ..
.     .=#########%######***++=-:....:=++==-.
.   .:##########%%######*++++++=----::--=--:.
 . .:############%#####***+++++++=====-----:..  .
  ..%%###########%%#####****++***+++++===--::. ..
   +%%%%%#######%%%###************+++++++==-:.
  .+@%%%%%#####%%%%#####**********++++++++==-:.  .
   .%@%%%%%#############*********+++++++++==-:.
   .:@@%%%%################******+====++++==--.
.   .-%@%%%%###############******++=--======-:.
      :%@%%%%#############*******++=-::--::..    .
      ..*@%%%###########*******+++==-. . . .
   .  . .-#%%%#######********++++=-:... .     .. .
          .:=***#*********+++==-:... .  .. .   . .
  . . ..      .....:::::::......   .
  .     .    .   .  .     .    .. .   .      .  .
         ..  .. .  .       ..    .              .

$(hostname) — Interstellar Network
EOF
}

motd_set() {
  local choice
  choice="$(ui_menu "Set startup text" "Choose MOTD source." \
    "1" "Use Interstellar Network ASCII" \
    "2" "Paste custom startup text" \
    "0" "Cancel")" || return

  backup_file /etc/motd
  case "$choice" in
    1)
      default_motd >/etc/motd
      ui_msg "Startup text" "Installed Interstellar Network startup text."
      ;;
    2)
      clear
      info "Paste/type the startup text."
      info "Finish with a line containing only: __END__"
      local tmp
      tmp="$(mktemp)"
      while IFS= read -r line; do
        [[ "$line" == "__END__" ]] && break
        printf '%s\n' "$line" >>"$tmp"
      done
      install -m 0644 "$tmp" /etc/motd
      rm -f "$tmp"
      ui_msg "Startup text" "Custom startup text installed."
      ;;
    0) return ;;
  esac
}

motd_delete() {
  backup_file /etc/motd
  : >/etc/motd
  fix "Startup text deleted. Backup stored in $BACKUP_DIR."
}

motd_menu() {
  while true; do
    local choice tmp
    choice="$(ui_menu "Startup text" "Manage /etc/motd." \
      "1" "See startup text" \
      "2" "Delete startup text" \
      "3" "Set startup text" \
      "0" "Back")" || return
    case "$choice" in
      1)
        tmp="$(mktemp)"
        cat /etc/motd 2>/dev/null >"$tmp" || true
        whiptail --backtitle "$UI_BACKTITLE" --title "Startup text" \
          --scrolltext --textbox "$tmp" 30 110
        rm -f "$tmp"
        ;;
      2) confirm "Delete /etc/motd startup text?" && motd_delete ;;
      3) motd_set ;;
      0) return ;;
    esac
  done
}

# ---------------- SSH ----------------

ensure_ssh_dropin() {
  mkdir -p /etc/ssh/sshd_config.d
  touch "$SSH_DROPIN"
}

set_ssh_directive() {
  local key="$1" value="$2"
  ensure_ssh_dropin
  backup_file "$SSH_DROPIN"

  if grep -qiE "^[[:space:]]*${key}[[:space:]]+" "$SSH_DROPIN"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$SSH_DROPIN"
  else
    printf '%s %s\n' "$key" "$value" >>"$SSH_DROPIN"
  fi

  if sshd -t; then
    systemctl reload ssh
    fix "SSH: $key = $value"
  else
    fail "SSH configuration validation failed."
    info "A backup was saved in $BACKUP_DIR."
    return 1
  fi
}

has_authorized_key() {
  local home
  while IFS=: read -r _ _ uid _ _ home shell; do
    [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] || continue
    [[ "$shell" =~ (nologin|false)$ ]] && continue
    [[ -s "$home/.ssh/authorized_keys" ]] && return 0
  done </etc/passwd
  return 1
}

ssh_root_login_menu() {
  local choice
  choice="$(ui_radiolist "Root SSH login" "Choose root-login policy." \
    "no" "Disable root SSH login" ON \
    "prohibit-password" "Allow root with SSH key only" OFF \
    "yes" "Enable root SSH login (not recommended)" OFF)" || return

  if [[ "$choice" == "yes" ]]; then
    ui_yesno "Warning" "Enable root SSH login? This increases attack surface." || return
  fi
  set_ssh_directive PermitRootLogin "$choice"
}

ssh_password_login_menu() {
  local choice
  choice="$(ui_radiolist "SSH password login" "Choose password-authentication policy." \
    "no" "Disable password login (keys only)" ON \
    "yes" "Enable password login" OFF)" || return

  if [[ "$choice" == "no" ]]; then
    if ! has_authorized_key; then
      ui_msg "Cannot disable password login" "No authorized_keys was found for a normal user. Password login was left enabled to avoid lockout."
      return
    fi
    set_ssh_directive PasswordAuthentication no
    set_ssh_directive KbdInteractiveAuthentication no
    set_ssh_directive PubkeyAuthentication yes
  else
    ui_yesno "Warning" "Enable SSH password authentication?" || return
    set_ssh_directive PasswordAuthentication yes
  fi
}

ssh_status() {
  command -v sshd >/dev/null 2>&1 || { fail "sshd is not installed."; return; }
  sshd -T |
    grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|usepam) '
}

ssh_menu() {
  while true; do
    local choice
    choice="$(ui_menu "SSH settings" "Manage OpenSSH security." \
      "1" "Change root login" \
      "2" "Change password login" \
      "3" "Show effective SSH settings" \
      "4" "Validate and reload SSH" \
      "0" "Back")" || return
    case "$choice" in
      1) ssh_root_login_menu; pause ;;
      2) ssh_password_login_menu; pause ;;
      3) clear; ssh_status; pause ;;
      4)
        clear
        if sshd -t; then systemctl reload ssh; ok "SSH configuration valid and reloaded."
        else fail "SSH configuration invalid; not reloaded."; fi
        pause ;;
      0) return ;;
    esac
  done
}

# ---------------- Tailscale & networking ----------------

tailscale_install() {
  if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale already installed."
    return
  fi
  info "Installing Tailscale using the official installer..."
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  fix "Tailscale installed."
}

tailscale_status_show() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status || true
    echo
    echo "Tailscale IPv4: $(tailscale ip -4 2>/dev/null || echo '-')"
    echo "LAN IPv4:"
    ip -4 -br addr show scope global | grep -v tailscale || true
  else
    warn "Tailscale is not installed."
  fi
}

network_info() {
  echo "Hostname: $(hostname)"
  echo
  echo "Addresses:"
  ip -br addr
  echo
  echo "Routes:"
  ip route
  echo
  echo "DNS:"
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | head -80 || true
  else
    cat /etc/resolv.conf
  fi
}

tailscale_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Tailscale & networking" "Manage private remote connectivity." \
      "1" "Show Tailscale status" \
      "2" "Install Tailscale" \
      "3" "Connect / login Tailscale" \
      "4" "Disconnect Tailscale" \
      "5" "Show network information" \
      "6" "Show Tailscale Serve status" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; tailscale_status_show; pause ;;
      2) clear; tailscale_install; pause ;;
      3) clear; tailscale_install; tailscale up; pause ;;
      4) clear; command -v tailscale >/dev/null 2>&1 && tailscale down; pause ;;
      5) clear; network_info; pause ;;
      6) clear; tailscale serve status 2>/dev/null || true; pause ;;
      0) return ;;
    esac
  done
}



# ---------------- Install tools ----------------

user_home() {
  getent passwd "$1" | cut -d: -f6
}

run_as_user() {
  local user="$1"
  shift
  local home
  home="$(user_home "$user")"
  runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" "$@"
}

ensure_user_local_path() {
  local user="$1" home profile
  home="$(user_home "$user")"
  profile="$home/.bashrc"
  touch "$profile"
  chown "$user":"$(id -gn "$user")" "$profile"
  if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$profile"; then
    printf '\n# Interstellar Network user tools\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$profile"
    chown "$user":"$(id -gn "$user")" "$profile"
  fi
}

tool_is_installed() {
  local tag="$1" user="$2"
  case "$tag" in
    git) command -v git >/dev/null 2>&1 ;;
    git-lfs) command -v git-lfs >/dev/null 2>&1 ;;
    gh) command -v gh >/dev/null 2>&1 ;;
    node) run_as_user "$user" bash -lc 'command -v node >/dev/null 2>&1' ;;
    pnpm) run_as_user "$user" bash -lc 'command -v pnpm >/dev/null 2>&1' ;;
    build) command -v gcc >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1 ;;
    docker) command -v docker >/dev/null 2>&1 ;;
    claude) run_as_user "$user" bash -lc 'command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]' ;;
    codex) run_as_user "$user" bash -lc 'command -v codex >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/codex" ]]' ;;
    *) return 1 ;;
  esac
}

install_node22_for_user() {
  local user="$1"
  ensure_user_local_path "$user"
  run_as_user "$user" bash -lc '
    set -e
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash
    fi
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm install 22
    nvm alias default 22
    node --version
  '
}

install_pnpm_for_user() {
  local user="$1"
  if ! tool_is_installed node "$user"; then
    install_node22_for_user "$user"
  fi
  run_as_user "$user" bash -lc '
    set -e
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
    npm install -g pnpm@10
    pnpm --version
  '
}

install_claude_for_user() {
  local user="$1"
  if [[ "$(uname -m)" == "x86_64" ]] && ! grep -qw avx2 /proc/cpuinfo; then
    fail "AVX2 is not exposed to this VM."
    warn "Claude Code can hang on some x86_64 KVM/QEMU guests without AVX2."
    info "In Proxmox, set CPU type to 'host', cold boot the VM, then retry."
    return 1
  fi

  ensure_user_local_path "$user"
  run_as_user "$user" bash -lc '
    set -e
    curl -fsSL https://claude.ai/install.sh | bash
  '
  fix "Claude Code installed for $user."
  info "Log in as $user and run: claude"
}

install_codex_for_user() {
  local user="$1"
  ensure_user_local_path "$user"
  run_as_user "$user" bash -lc '
    set -e
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
  '
  fix "Codex installed for $user."
  info "On a headless server, log in as $user and run: codex login --device-auth"
}


apt_candidate_version() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

node_remote_versions() {
  python3 - <<'PY'
import json, urllib.request
try:
    with urllib.request.urlopen("https://nodejs.org/dist/index.json", timeout=6) as r:
        data=json.load(r)
    latest=data[0]["version"].lstrip("v") if data else ""
    stable=next((x["version"].lstrip("v") for x in data if x.get("lts")), latest)
    print(latest); print(stable)
except Exception:
    print(""); print("")
PY
}

npm_remote_versions() {
  local package="$1"
  python3 - "$package" <<'PY'
import json,re,sys,urllib.parse,urllib.request
pkg=sys.argv[1]
url="https://registry.npmjs.org/"+urllib.parse.quote(pkg, safe="@")
try:
    with urllib.request.urlopen(url, timeout=6) as r: data=json.load(r)
    versions=list((data.get("versions") or {}).keys())
    stable=(data.get("dist-tags") or {}).get("latest","")
    def key(v):
        m=re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$",v)
        if not m: return (-1,-1,-1,-1,"")
        a,b,c=map(int,m.group(1,2,3)); pre=m.group(4)
        return (a,b,c,1 if pre is None else 0,pre or "")
    latest=max(versions,key=key) if versions else stable
    print(latest); print(stable or latest)
except Exception:
    print(""); print("")
PY
}

tool_installed_version() {
  local tag="$1" user="$2"
  case "$tag" in
    git) git --version 2>/dev/null | awk '{print $3}' ;;
    git-lfs) git lfs version 2>/dev/null | sed -E 's#git-lfs/([^ ]+).*#\1#' ;;
    gh) gh --version 2>/dev/null | awk 'NR==1 {print $3}' ;;
    node) run_as_user "$user" bash -lc 'export NVM_DIR="$HOME/.nvm"; [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"; node --version 2>/dev/null | sed "s/^v//"' ;;
    pnpm) run_as_user "$user" bash -lc 'export NVM_DIR="$HOME/.nvm"; [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"; pnpm --version 2>/dev/null' ;;
    claude) run_as_user "$user" bash -lc 'claude --version 2>/dev/null | awk "{print \$1}"' ;;
    codex) run_as_user "$user" bash -lc 'codex --version 2>/dev/null | awk "{print \$2}"' ;;
    docker) docker --version 2>/dev/null | sed -E 's/.*version ([^,]+),.*/\1/' ;;
    build) gcc -dumpfullversion 2>/dev/null || gcc -dumpversion 2>/dev/null || true ;;
  esac
}

tool_remote_versions() {
  local tag="$1"
  case "$tag" in
    node) node_remote_versions ;;
    pnpm) npm_remote_versions "pnpm" ;;
    claude) npm_remote_versions "@anthropic-ai/claude-code" ;;
    codex) npm_remote_versions "@openai/codex" ;;
    git) local v; v="$(apt_candidate_version git)"; printf '%s\n%s\n' "$v" "$v" ;;
    git-lfs) local v; v="$(apt_candidate_version git-lfs)"; printf '%s\n%s\n' "$v" "$v" ;;
    gh) local v; v="$(apt_candidate_version gh)"; printf '%s\n%s\n' "$v" "$v" ;;
    docker) local v; v="$(apt_candidate_version docker-ce)"; printf '%s\n%s\n' "$v" "$v" ;;
    build) local v; v="$(apt_candidate_version build-essential)"; printf '%s\n%s\n' "$v" "$v" ;;
  esac
}

choose_tool_version() {
  local tag="$1" user="$2" current latest stable choice custom
  current="$(tool_installed_version "$tag" "$user" || true)"
  mapfile -t _rv < <(tool_remote_versions "$tag")
  latest="${_rv[0]:-}"; stable="${_rv[1]:-}"
  [[ -n "$current" ]] || current="not installed"
  [[ -n "$latest" ]] || latest="unavailable"
  [[ -n "$stable" ]] || stable="$latest"

  choice="$(ui_radiolist "Version: $tag" "Choose version/channel for $tag." \
    "current" "Current / installed ($current)" OFF \
    "latest" "Latest published ($latest)" ON \
    "stable" "Latest stable / LTS ($stable)" OFF \
    "custom" "Custom exact version..." OFF)" || return 1

  case "$choice" in
    current) [[ "$current" != "not installed" ]] || return 1; printf '%s\n' "$current" ;;
    latest) [[ "$latest" != "unavailable" ]] || return 1; printf '%s\n' "$latest" ;;
    stable) [[ "$stable" != "unavailable" ]] || return 1; printf '%s\n' "$stable" ;;
    custom) custom="$(ui_input "Custom version" "Exact version for $tag:" "")" || return 1; [[ -n "$custom" ]] || return 1; printf '%s\n' "$custom" ;;
  esac
}

install_node_version_for_user() {
  local user="$1" version="$2"
  ensure_user_local_path "$user"
  run_as_user "$user" env NODE_VERSION="$version" bash -lc '
    set -e
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash
    fi
    . "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use "$NODE_VERSION"
  '
}

ensure_node_for_user() {
  local user="$1"
  tool_is_installed node "$user" && return 0
  mapfile -t _nv < <(node_remote_versions)
  install_node_version_for_user "$user" "${_nv[1]:-${_nv[0]:-22}}"
}

install_npm_tool_version_for_user() {
  local user="$1" package="$2" version="$3"
  ensure_node_for_user "$user"
  run_as_user "$user" env NPM_PACKAGE="$package" NPM_VERSION="$version" bash -lc '
    set -e
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    npm install -g "${NPM_PACKAGE}@${NPM_VERSION}"
  '
}

install_apt_exact_or_candidate() {
  local pkg="$1" version="$2"
  apt-get update
  if apt-cache madison "$pkg" 2>/dev/null | awk '{print $3}' | grep -Fxq "$version"; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}=${version}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
}

install_selected_tools() {
  local user="$1"
  shift
  local selected=("$@")
  local tag version
  install_pkg python3

  for tag in "${selected[@]}"; do
    version="$(choose_tool_version "$tag" "$user")" || continue
    clear
    info "Installing/setting $tag -> $version"
    case "$tag" in
      git) install_apt_exact_or_candidate git "$version" ;;
      git-lfs) install_apt_exact_or_candidate git-lfs "$version"; run_as_user "$user" git lfs install || true ;;
      gh) install_apt_exact_or_candidate gh "$version" ;;
      node) install_node_version_for_user "$user" "$version" ;;
      pnpm) install_npm_tool_version_for_user "$user" "pnpm" "$version" ;;
      build) apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential python3 python3-venv python3-pip pkg-config libssl-dev ;;
      docker) docker_install_official ;;
      claude)
        if [[ "$(uname -m)" == "x86_64" ]] && ! grep -qw avx2 /proc/cpuinfo; then
          fail "AVX2 is not exposed. Set Proxmox CPU type to host and cold boot."
        else
          install_npm_tool_version_for_user "$user" "@anthropic-ai/claude-code" "$version"
        fi ;;
      codex) install_npm_tool_version_for_user "$user" "@openai/codex" "$version" ;;
    esac
  done
  ok "Selected tools processed for '$user'."
}

install_tools_checklist() {
  local user result rc
  user="$(choose_regular_user)" || return

  local sg=OFF sl=OFF sgh=OFF sn=OFF sp=OFF sb=OFF sd=OFF sc=OFF sx=OFF
  tool_is_installed git "$user" && sg=ON
  tool_is_installed git-lfs "$user" && sl=ON
  tool_is_installed gh "$user" && sgh=ON
  tool_is_installed node "$user" && sn=ON
  tool_is_installed pnpm "$user" && sp=ON
  tool_is_installed build "$user" && sb=ON
  tool_is_installed docker "$user" && sd=ON
  tool_is_installed claude "$user" && sc=ON
  tool_is_installed codex "$user" && sx=ON

  set +e
  result="$(ui_checklist "Install tools for $user" \
    "Space toggles tools. A version selector follows for every selected item." \
    "git" "Git" "$sg" \
    "git-lfs" "Git Large File Storage" "$sl" \
    "gh" "GitHub CLI" "$sgh" \
    "node" "Node.js" "$sn" \
    "pnpm" "pnpm" "$sp" \
    "build" "Build tools + Python + OpenSSL dev" "$sb" \
    "docker" "Docker Engine + Compose + Buildx" "$sd" \
    "claude" "Claude Code" "$sc" \
    "codex" "OpenAI Codex CLI" "$sx")"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return

  local selected=()
  while IFS= read -r tag; do [[ -n "$tag" ]] && selected+=("$tag"); done < <(printf '%s' "$result" | tr -d '"' | tr ' ' '\n')
  [[ "${#selected[@]}" -gt 0 ]] || return
  install_selected_tools "$user" "${selected[@]}"
}

show_tool_status() {
  local user
  if ! user="$(choose_regular_user)"; then
    warn "No valid user selected."
    return
  fi

  echo
  printf '%-12s %-10s\n' "Tool" "Status"
  printf '%-12s %-10s\n' "------------" "----------"
  local tag
  for tag in git git-lfs gh node pnpm build docker claude codex; do
    if tool_is_installed "$tag" "$user"; then
      printf '%-12s %sinstalled%s\n' "$tag" "$GREEN" "$RESET"
    else
      printf '%-12s %snot installed%s\n' "$tag" "$YELLOW" "$RESET"
    fi
  done
}

tools_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Install tools" "Install and pin development/server tooling." \
      "1" "Install / repair tools (checkboxes + versions)" \
      "2" "Show installed tool status" \
      "0" "Back")" || return
    case "$choice" in
      1) install_tools_checklist; pause ;;
      2) clear; show_tool_status; pause ;;
      0) return ;;
    esac
  done
}

# ---------------- Docker ----------------

docker_status() {
  echo
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  info "Virtualization: ${virt:-unknown}"
  if [[ "$virt" == "lxc" ]]; then
    warn "This is an LXC container. Docker can work in LXC, but Proxmox may require nesting/keyctl configuration."
    warn "This manager will not modify Proxmox host settings."
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker CLI installed: $(docker --version 2>/dev/null || true)"
    docker compose version 2>/dev/null && ok "Docker Compose plugin available" || warn "Docker Compose plugin unavailable"
    docker buildx version 2>/dev/null && ok "Docker Buildx plugin available" || warn "Docker Buildx plugin unavailable"

    if systemctl is-active --quiet docker 2>/dev/null; then
      ok "Docker daemon running"
    else
      warn "Docker daemon not running"
    fi

    echo
    docker info --format 'Server version: {{.ServerVersion}}
Storage driver: {{.Driver}}
Cgroup driver: {{.CgroupDriver}}
Containers: {{.Containers}} (running {{.ContainersRunning}})
Images: {{.Images}}' 2>/dev/null || true
  else
    warn "Docker is not installed."
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    echo
    warn "UFW is active."
    warn "Published Docker container ports can bypass normal UFW filtering."
    info "Review Docker's DOCKER-USER firewall chain for internet-facing containers."
  fi
}

docker_install_official() {
  echo
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ "$virt" == "lxc" ]]; then
    warn "LXC detected. Docker may need nesting/keyctl enabled in Proxmox."
    confirm "Continue with the guest-side Docker installation?" || return
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    warn "UFW is active. Docker-published ports can bypass normal UFW rules."
    confirm "Continue installing Docker?" || return
  fi

  local conflicts=(
    docker.io docker-compose docker-compose-v2 docker-doc docker-buildx
    podman-docker containerd runc
  )
  local installed_conflicts=()
  local pkg
  for pkg in "${conflicts[@]}"; do
    if is_installed "$pkg"; then
      installed_conflicts+=("$pkg")
    fi
  done

  if [[ "${#installed_conflicts[@]}" -gt 0 ]]; then
    warn "Conflicting distribution packages detected:"
    printf '  - %s\n' "${installed_conflicts[@]}"
    if confirm "Remove these conflicting packages first?"; then
      apt-get remove -y "${installed_conflicts[@]}"
    else
      info "Docker installation cancelled."
      return
    fi
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings

  local repo_os suite
  case "$ID" in
    debian)
      repo_os="debian"
      suite="${VERSION_CODENAME}"
      ;;
    ubuntu)
      repo_os="ubuntu"
      suite="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
      ;;
  esac

  curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${repo_os}
Suites: ${suite}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
  fix "Installed Docker Engine, Buildx and Docker Compose from Docker's official apt repository."
  docker_status
}

docker_add_user() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed."
    return
  fi

  echo
  warn "Membership of the docker group is effectively root-level access to this server."
  local user
  if user="$(choose_regular_user)"; then
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
      ok "$user is already in the docker group."
    else
      confirm "Add '$user' to the docker group?" || return
      usermod -aG docker "$user"
      fix "Added $user to docker group."
      info "The user must fully log out and back in before the new group membership applies."
    fi
  else
    warn "No valid user selected."
  fi
}

docker_hello_world() {
  command -v docker >/dev/null 2>&1 || { warn "Docker is not installed."; return; }
  docker run --rm hello-world
}

docker_overview() {
  command -v docker >/dev/null 2>&1 || { warn "Docker is not installed."; return; }
  echo "Containers:"
  docker ps -a
  echo
  echo "Images:"
  docker images
  echo
  echo "Disk usage:"
  docker system df
}

docker_update() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed."
    return
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  systemctl restart docker
  fix "Docker packages updated and daemon restarted."
}

docker_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Docker & containers" "Manage Docker Engine." \
      "1" "Show Docker status" \
      "2" "Install / repair official Docker Engine" \
      "3" "Add user to docker group" \
      "4" "Run hello-world test" \
      "5" "Show containers / images / disk usage" \
      "6" "Update Docker packages" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; docker_status; pause ;;
      2) clear; docker_install_official; pause ;;
      3) clear; docker_add_user; pause ;;
      4) clear; docker_hello_world; pause ;;
      5) clear; docker_overview; pause ;;
      6) clear; docker_update; pause ;;
      0) return ;;
    esac
  done
}


# ---------------- Health agent / API ----------------

AGENT_DIR="/usr/local/lib/interstellar"
AGENT_PY="${AGENT_DIR}/agent.py"
AGENT_ENV="/etc/default/interstellar-agent"
AGENT_UNIT="/etc/systemd/system/interstellar-agent.service"
MDNS_PY="${AGENT_DIR}/mdns.py"
MDNS_ENV="/etc/default/interstellar-mdns"
MDNS_UNIT="/etc/systemd/system/interstellar-mdns.service"

write_agent_python() {
  install -d -o root -g root -m 0755 "$AGENT_DIR"
  cat >"$AGENT_PY" <<'PYEOF'
#!/usr/bin/env python3
from __future__ import annotations

import glob
import json
import os
import platform
import shutil
import socket
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

VERSION = "3.0.0"
BIND = "127.0.0.1"
PORT = int(os.environ.get("INTERSTELLAR_PORT", "9127"))
ROLES = [x.strip() for x in os.environ.get("INTERSTELLAR_ROLES", "general").split(",") if x.strip()]
EXPECTED_SERVICES = [x.strip() for x in os.environ.get("INTERSTELLAR_EXPECTED_SERVICES", "ssh,tailscaled").split(",") if x.strip()]
APT_CACHE_SECONDS = 900


def which(name: str, fallbacks: tuple[str, ...] = ()) -> str:
    path = shutil.which(name)
    if path:
        return path
    for path in fallbacks:
        if os.path.exists(path):
            return path
    return name


SYSTEMCTL = which("systemctl", ("/usr/bin/systemctl", "/bin/systemctl"))
IP = which("ip", ("/usr/sbin/ip", "/usr/bin/ip"))
SS = which("ss", ("/usr/sbin/ss", "/usr/bin/ss"))
TAILSCALE = which("tailscale", ("/usr/bin/tailscale", "/usr/sbin/tailscale"))
DETECT_VIRT = which("systemd-detect-virt", ("/usr/bin/systemd-detect-virt",))
TIMEDATECTL = which("timedatectl", ("/usr/bin/timedatectl",))
APT = which("apt", ("/usr/bin/apt",))

_previous_network: dict[str, tuple[float, int, int]] = {}
_previous_disk: dict[str, tuple[float, int, int]] = {}
_apt_cache: tuple[float, dict[str, Any]] | None = None


def run(cmd: list[str], timeout: float = 3.0) -> str:
    try:
        process = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env={**os.environ, "LC_ALL": "C"},
        )
        return process.stdout.strip()
    except Exception:
        return ""


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def iso_from_timestamp(timestamp: float | int | None) -> str | None:
    if timestamp is None:
        return None
    try:
        return datetime.fromtimestamp(float(timestamp), timezone.utc).isoformat()
    except (OSError, OverflowError, ValueError):
        return None


def human_bytes(value: int | float | None) -> str | None:
    if value is None:
        return None
    value = float(value)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    for unit in units:
        if abs(value) < 1024.0 or unit == units[-1]:
            return f"{value:.1f} {unit}"
        value /= 1024.0
    return None


def read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except (OSError, PermissionError):
        return None


def read_os_release() -> dict[str, str]:
    result: dict[str, str] = {}
    value = read_text("/etc/os-release")
    if not value:
        return result
    for line in value.splitlines():
        if "=" in line:
            key, item = line.split("=", 1)
            result[key] = item.strip('"')
    return result


def machine_id() -> str | None:
    return read_text("/etc/machine-id")


def process_running(names: set[str]) -> bool:
    try:
        entries = os.scandir("/proc")
    except OSError:
        return False
    with entries:
        for entry in entries:
            if not entry.name.isdigit():
                continue
            value = read_text(f"/proc/{entry.name}/comm")
            if value in names:
                return True
    return False


SERVICE_PROCESSES: dict[str, set[str]] = {
    "ssh": {"sshd"},
    "sshd": {"sshd"},
    "tailscaled": {"tailscaled"},
    "docker": {"dockerd"},
    "qemu-guest-agent": {"qemu-ga"},
    "systemd-timesyncd": {"systemd-timesyn", "systemd-timesyncd"},
    "nginx": {"nginx"},
}


def service_state(name: str) -> str:
    output = run([SYSTEMCTL, "show", "-p", "ActiveState", "--value", name], timeout=2.0)
    if output in {"active", "inactive", "failed", "activating", "deactivating", "reloading"}:
        return output
    processes = SERVICE_PROCESSES.get(name, {name})
    return "active" if process_running(processes) else "inactive"


def virtualization() -> str:
    return run([DETECT_VIRT], timeout=1.0) or "none"


def cpu_model() -> str | None:
    value = read_text("/proc/cpuinfo")
    if value:
        for line in value.splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    return platform.processor() or None


def _cpu_snapshot() -> list[int]:
    value = read_text("/proc/stat") or ""
    first = value.splitlines()[0].split()[1:]
    return [int(x) for x in first]


def cpu_percentages() -> dict[str, float | None]:
    try:
        first = _cpu_snapshot()
        time.sleep(0.10)
        second = _cpu_snapshot()
    except Exception:
        return {"used_percent": None, "iowait_percent": None, "steal_percent": None}

    deltas = [b - a for a, b in zip(first, second, strict=False)]
    total = sum(deltas)
    if total <= 0:
        return {"used_percent": None, "iowait_percent": None, "steal_percent": None}

    idle = deltas[3] if len(deltas) > 3 else 0
    iowait = deltas[4] if len(deltas) > 4 else 0
    steal = deltas[7] if len(deltas) > 7 else 0
    return {
        "used_percent": round((1.0 - idle / total) * 100.0, 1),
        "iowait_percent": round(iowait / total * 100.0, 2),
        "steal_percent": round(steal / total * 100.0, 2),
    }


def memory_stats() -> dict[str, Any]:
    data: dict[str, int] = {}
    value = read_text("/proc/meminfo")
    if not value:
        return {}
    for line in value.splitlines():
        key, item = line.split(":", 1)
        data[key] = int(item.strip().split()[0]) * 1024

    total = data.get("MemTotal", 0)
    available = data.get("MemAvailable", 0)
    used = max(total - available, 0)
    swap_total = data.get("SwapTotal", 0)
    swap_free = data.get("SwapFree", 0)
    swap_used = max(swap_total - swap_free, 0)

    return {
        "total_bytes": total,
        "total_human": human_bytes(total),
        "available_bytes": available,
        "available_human": human_bytes(available),
        "used_bytes": used,
        "used_human": human_bytes(used),
        "used_percent": round(used / total * 100.0, 1) if total else None,
        "swap": {
            "total_bytes": swap_total,
            "total_human": human_bytes(swap_total),
            "used_bytes": swap_used,
            "used_human": human_bytes(swap_used),
            "free_bytes": swap_free,
            "free_human": human_bytes(swap_free),
            "used_percent": round(swap_used / swap_total * 100.0, 1) if swap_total else 0.0,
        },
    }


def filesystem_stats() -> list[dict[str, Any]]:
    byte_output = run(["df", "-B1", "-P", "-x", "tmpfs", "-x", "devtmpfs"], timeout=2.0)
    inode_output = run(["df", "-Pi", "-x", "tmpfs", "-x", "devtmpfs"], timeout=2.0)
    inodes: dict[str, dict[str, Any]] = {}

    for line in inode_output.splitlines()[1:]:
        parts = line.split(None, 5)
        if len(parts) != 6:
            continue
        _, total, used, free, percent, mount = parts
        try:
            inodes[mount] = {
                "inode_total": int(total),
                "inode_used": int(used),
                "inode_free": int(free),
                "inode_used_percent": float(percent.rstrip("%")),
            }
        except ValueError:
            continue

    result: list[dict[str, Any]] = []
    for line in byte_output.splitlines()[1:]:
        parts = line.split(None, 5)
        if len(parts) != 6:
            continue
        filesystem, total, used, free, percent, mount = parts
        try:
            total_i, used_i, free_i = int(total), int(used), int(free)
        except ValueError:
            continue
        item = {
            "filesystem": filesystem,
            "mountpoint": mount,
            "total_bytes": total_i,
            "total_human": human_bytes(total_i),
            "used_bytes": used_i,
            "used_human": human_bytes(used_i),
            "free_bytes": free_i,
            "free_human": human_bytes(free_i),
            "used_percent": float(percent.rstrip("%")) if percent.endswith("%") else None,
        }
        item.update(inodes.get(mount, {}))
        result.append(item)
    return result


def root_disk_stats(filesystems: list[dict[str, Any]]) -> dict[str, Any]:
    for item in filesystems:
        if item.get("mountpoint") == "/":
            return item
    usage = shutil.disk_usage("/")
    return {
        "filesystem": None,
        "mountpoint": "/",
        "total_bytes": usage.total,
        "total_human": human_bytes(usage.total),
        "used_bytes": usage.used,
        "used_human": human_bytes(usage.used),
        "free_bytes": usage.free,
        "free_human": human_bytes(usage.free),
        "used_percent": round(usage.used / usage.total * 100.0, 1) if usage.total else None,
    }


def uptime_seconds() -> int | None:
    value = read_text("/proc/uptime")
    if not value:
        return None
    try:
        return int(float(value.split()[0]))
    except ValueError:
        return None


def boot_time_utc() -> str | None:
    value = read_text("/proc/stat")
    if value:
        for line in value.splitlines():
            if line.startswith("btime "):
                try:
                    return iso_from_timestamp(int(line.split()[1]))
                except (IndexError, ValueError):
                    pass
    uptime = uptime_seconds()
    if uptime is not None:
        return iso_from_timestamp(time.time() - uptime)
    return None


def human_duration(seconds: int | None) -> str | None:
    if seconds is None:
        return None
    days, rem = divmod(int(seconds), 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    pieces: list[str] = []
    if days:
        pieces.append(f"{days}d")
    if hours or days:
        pieces.append(f"{hours}h")
    if minutes or hours or days:
        pieces.append(f"{minutes}m")
    pieces.append(f"{secs}s")
    return " ".join(pieces)


def ipv4_addresses() -> list[dict[str, Any]]:
    output = run([IP, "-j", "-4", "addr", "show"], timeout=2.0)
    try:
        parsed = json.loads(output) if output else []
    except json.JSONDecodeError:
        parsed = []
    result: list[dict[str, Any]] = []
    for interface in parsed:
        name = interface.get("ifname")
        if name == "lo":
            continue
        for address_info in interface.get("addr_info", []):
            if address_info.get("family") != "inet":
                continue
            address = address_info.get("local")
            if not address or address.startswith("127."):
                continue
            result.append(
                {
                    "interface": name,
                    "address": address,
                    "prefixlen": address_info.get("prefixlen"),
                    "scope": address_info.get("scope"),
                    "kind": "tailscale" if name == "tailscale0" or address.startswith("100.") else "lan",
                }
            )
    return result


def network_stats() -> list[dict[str, Any]]:
    global _previous_network
    now = time.monotonic()
    result: list[dict[str, Any]] = []
    for path in sorted(glob.glob("/sys/class/net/*")):
        interface = os.path.basename(path)
        if interface == "lo":
            continue
        try:
            rx = int(read_text(f"{path}/statistics/rx_bytes") or "0")
            tx = int(read_text(f"{path}/statistics/tx_bytes") or "0")
            rx_packets = int(read_text(f"{path}/statistics/rx_packets") or "0")
            tx_packets = int(read_text(f"{path}/statistics/tx_packets") or "0")
            rx_errors = int(read_text(f"{path}/statistics/rx_errors") or "0")
            tx_errors = int(read_text(f"{path}/statistics/tx_errors") or "0")
        except ValueError:
            continue

        rx_rate = tx_rate = None
        previous = _previous_network.get(interface)
        if previous:
            previous_time, previous_rx, previous_tx = previous
            delta = now - previous_time
            if delta > 0:
                rx_rate = max(0.0, (rx - previous_rx) / delta)
                tx_rate = max(0.0, (tx - previous_tx) / delta)
        _previous_network[interface] = (now, rx, tx)
        result.append(
            {
                "interface": interface,
                "rx_bytes": rx,
                "tx_bytes": tx,
                "rx_bytes_per_second": round(rx_rate, 1) if rx_rate is not None else None,
                "tx_bytes_per_second": round(tx_rate, 1) if tx_rate is not None else None,
                "rx_packets": rx_packets,
                "tx_packets": tx_packets,
                "rx_errors": rx_errors,
                "tx_errors": tx_errors,
            }
        )
    return result


def disk_io_stats() -> list[dict[str, Any]]:
    global _previous_disk
    now = time.monotonic()
    result: list[dict[str, Any]] = []
    for path in sorted(glob.glob("/sys/block/*")):
        device = os.path.basename(path)
        if device.startswith(("loop", "ram")):
            continue
        raw = read_text(f"{path}/stat")
        if not raw:
            continue
        fields = raw.split()
        if len(fields) < 11:
            continue
        try:
            sectors_read = int(fields[2])
            sectors_written = int(fields[6])
            io_ms = int(fields[9])
        except ValueError:
            continue
        read_bytes = sectors_read * 512
        write_bytes = sectors_written * 512
        read_rate = write_rate = None
        previous = _previous_disk.get(device)
        if previous:
            previous_time, previous_read, previous_write = previous
            delta = now - previous_time
            if delta > 0:
                read_rate = max(0.0, (read_bytes - previous_read) / delta)
                write_rate = max(0.0, (write_bytes - previous_write) / delta)
        _previous_disk[device] = (now, read_bytes, write_bytes)
        result.append(
            {
                "device": device,
                "read_bytes": read_bytes,
                "write_bytes": write_bytes,
                "read_bytes_per_second": round(read_rate, 1) if read_rate is not None else None,
                "write_bytes_per_second": round(write_rate, 1) if write_rate is not None else None,
                "io_time_seconds": round(io_ms / 1000.0, 3),
            }
        )
    return result


def default_route() -> dict[str, Any]:
    output = run([IP, "-j", "-4", "route", "show", "default"], timeout=2.0)
    try:
        routes = json.loads(output) if output else []
    except json.JSONDecodeError:
        routes = []
    if not routes:
        return {}
    route = routes[0]
    return {
        "gateway": route.get("gateway"),
        "interface": route.get("dev"),
        "preferred_source": route.get("prefsrc"),
    }


def tailscale_ipv4(addresses: list[dict[str, Any]]) -> str | None:
    for item in addresses:
        if item.get("interface") == "tailscale0":
            return item.get("address")
    output = run([TAILSCALE, "ip", "-4"], timeout=1.5)
    return output.splitlines()[0].strip() if output else None


def listening_tcp() -> list[dict[str, Any]]:
    output = run([SS, "-lntH"], timeout=2.0)
    result: list[dict[str, Any]] = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local = parts[3]
        if local.startswith("[") and "]:" in local:
            address, port_value = local.rsplit("]:", 1)
            address += "]"
        elif ":" in local:
            address, port_value = local.rsplit(":", 1)
        else:
            continue
        try:
            port = int(port_value)
        except ValueError:
            continue
        result.append({"address": address, "port": port})
    return result


def ntp_status() -> dict[str, Any]:
    sync = run([TIMEDATECTL, "show", "-p", "NTPSynchronized", "--value"], timeout=1.5)
    return {
        "synchronized": True if sync == "yes" else False if sync == "no" else None,
        "systemd_timesyncd": service_state("systemd-timesyncd"),
    }


def thermal_stats() -> list[dict[str, Any]]:
    zones: list[dict[str, Any]] = []
    for path in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        try:
            raw = float(read_text(f"{path}/temp") or "")
        except ValueError:
            continue
        name = read_text(f"{path}/type") or os.path.basename(path)
        celsius = raw / 1000.0 if raw > 200 else raw
        if -50 <= celsius <= 200:
            zones.append({"name": name, "celsius": round(celsius, 1)})
    return zones


def failed_units() -> list[dict[str, str]]:
    output = run([SYSTEMCTL, "--failed", "--no-legend", "--no-pager"], timeout=2.0)
    result: list[dict[str, str]] = []
    for line in output.splitlines():
        parts = line.split()
        if not parts:
            continue
        unit = parts[0].lstrip("●")
        if unit == "●" and len(parts) > 1:
            unit = parts[1]
        result.append({"unit": unit})
    return result


def oom_kills_since_boot() -> int | None:
    value = read_text("/proc/vmstat")
    if not value:
        return None
    for line in value.splitlines():
        if line.startswith("oom_kill "):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return None
    return 0


def newest_mtime(paths: list[str]) -> float | None:
    values: list[float] = []
    for pattern in paths:
        for path in glob.glob(pattern):
            try:
                values.append(os.stat(path).st_mtime)
            except OSError:
                pass
    return max(values) if values else None


def last_apt_history_end() -> str | None:
    candidates = ["/var/log/apt/history.log"] + sorted(glob.glob("/var/log/apt/history.log.*"), reverse=True)
    latest: datetime | None = None
    for path in candidates:
        if path.endswith(".gz"):
            continue
        value = read_text(path)
        if not value:
            continue
        for line in value.splitlines():
            if not line.startswith("End-Date: "):
                continue
            raw = line.split(": ", 1)[1].strip()
            try:
                parsed = datetime.strptime(raw, "%Y-%m-%d  %H:%M:%S").replace(tzinfo=datetime.now().astimezone().tzinfo).astimezone(timezone.utc)
            except ValueError:
                continue
            if latest is None or parsed > latest:
                latest = parsed
    return latest.isoformat() if latest else None


def package_update_stats() -> dict[str, Any]:
    global _apt_cache
    monotonic_now = time.monotonic()
    if _apt_cache and monotonic_now - _apt_cache[0] < APT_CACHE_SECONDS:
        return _apt_cache[1]

    output = run([APT, "list", "--upgradable"], timeout=12.0)
    packages: list[dict[str, Any]] = []
    security = 0
    for line in output.splitlines():
        if not line or line.startswith("Listing...") or "/" not in line:
            continue
        parts = line.split()
        if not parts:
            continue
        name_repo = parts[0]
        package_name, repo = name_repo.split("/", 1)
        version = parts[1] if len(parts) > 1 else None
        is_security = "security" in repo.lower() or "security" in line.lower()
        if is_security:
            security += 1
        packages.append(
            {
                "name": package_name,
                "version": version,
                "repository": repo,
                "security": is_security,
            }
        )

    last_cache = newest_mtime(["/var/lib/apt/lists/*"])
    last_package_change = newest_mtime(["/var/lib/dpkg/status"])
    result = {
        "pending": len(packages),
        "pending_security": security,
        "packages": packages[:100],
        "last_cache_update_utc": iso_from_timestamp(last_cache),
        "last_package_change_utc": iso_from_timestamp(last_package_change),
        "last_successful_update_utc": last_apt_history_end() or iso_from_timestamp(last_package_change),
        "cache_seconds": APT_CACHE_SECONDS,
    }
    _apt_cache = (monotonic_now, result)
    return result


def role_metadata() -> dict[str, Any]:
    role_defaults: dict[str, list[str]] = {
        "docker-host": ["docker"],
    }
    effective = list(dict.fromkeys(EXPECTED_SERVICES))
    for role in ROLES:
        for service in role_defaults.get(role, []):
            if service not in effective:
                effective.append(service)
    return {
        "roles": ROLES,
        "configured_expected_services": EXPECTED_SERVICES,
        "expected_services": effective,
    }


def service_stats() -> tuple[dict[str, str], list[dict[str, str]]]:
    metadata = role_metadata()
    names = ["ssh", "tailscaled", "docker", "qemu-guest-agent", "systemd-timesyncd"]
    names.extend(metadata["expected_services"])
    names = list(dict.fromkeys(names))
    services = {name: service_state(name) for name in names}
    problems = [
        {"service": name, "state": services.get(name, "unknown")}
        for name in metadata["expected_services"]
        if services.get(name) != "active"
    ]
    return services, problems


def listen_urls() -> list[str]:
    return [f"http://127.0.0.1:{PORT}"]


def api_info() -> dict[str, Any]:
    urls = listen_urls()
    return {
        "bind_address": BIND,
        "port": PORT,
        "listen_urls": urls,
        "note": "Backend is localhost-only. Use Tailscale Serve and tailnet policy for remote access.",
        "endpoints": {
            name: {"path": path, "auth_required": False, "urls": [url + path for url in urls]}
            for name, path in {"health": "/health", "stats": "/stats", "metrics": "/metrics"}.items()
        },
    }


def collect_stats() -> dict[str, Any]:
    os_release = read_os_release()
    try:
        load = os.getloadavg()
        load_object = {"1m": round(load[0], 2), "5m": round(load[1], 2), "15m": round(load[2], 2)}
    except OSError:
        load_object = {}

    uptime = uptime_seconds()
    addresses = ipv4_addresses()
    filesystems = filesystem_stats()
    cpu = cpu_percentages()
    services, expected_problems = service_stats()
    failed = failed_units()

    return {
        "status": "ok",
        "agent_version": VERSION,
        "timestamp_utc": now_utc(),
        "api": api_info(),
        "host": {
            "machine_id": machine_id(),
            "hostname": socket.gethostname(),
            "fqdn": socket.getfqdn(),
            "os": os_release.get("PRETTY_NAME", platform.platform()),
            "os_id": os_release.get("ID"),
            "os_version": os_release.get("VERSION_ID"),
            "kernel": platform.release(),
            "architecture": platform.machine(),
            "virtualization": virtualization(),
            "roles": role_metadata()["roles"],
            "uptime_seconds": uptime,
            "uptime_human": human_duration(uptime),
            "boot_time_utc": boot_time_utc(),
        },
        "cpu": {
            "model": cpu_model(),
            "count": os.cpu_count(),
            "used_percent": cpu["used_percent"],
            "iowait_percent": cpu["iowait_percent"],
            "steal_percent": cpu["steal_percent"],
            "load": load_object,
        },
        "memory": memory_stats(),
        "disk_root": root_disk_stats(filesystems),
        "filesystems": filesystems,
        "disk_io": disk_io_stats(),
        "temperatures": thermal_stats(),
        "network": {
            "addresses": addresses,
            "interfaces": network_stats(),
            "tailscale_ipv4": tailscale_ipv4(addresses),
            "default_route": default_route(),
            "listening_tcp": listening_tcp(),
        },
        "services": services,
        "service_policy": {
            **role_metadata(),
            "problems": expected_problems,
            "healthy": not expected_problems,
        },
        "updates": package_update_stats(),
        "time": ntp_status(),
        "system": {
            "reboot_required": os.path.exists("/var/run/reboot-required"),
            "failed_systemd_units": len(failed),
            "failed_units": failed,
            "oom_kills_since_boot": oom_kills_since_boot(),
        },
    }


def minimal_health() -> dict[str, Any]:
    stats = collect_stats()
    root_used = stats.get("disk_root", {}).get("used_percent")
    failures = stats.get("system", {}).get("failed_systemd_units", 0)
    expected_healthy = stats.get("service_policy", {}).get("healthy", True)
    ntp = stats.get("time", {}).get("synchronized")
    healthy = (
        failures == 0
        and expected_healthy
        and ntp is not False
        and (root_used is None or root_used < 95)
    )
    return {
        "status": "ok" if healthy else "degraded",
        "agent_version": VERSION,
        "timestamp_utc": stats["timestamp_utc"],
        "machine_id": stats["host"].get("machine_id"),
        "hostname": stats["host"]["hostname"],
        "roles": stats["host"].get("roles", []),
        "uptime_seconds": stats["host"]["uptime_seconds"],
        "uptime_human": stats["host"]["uptime_human"],
        "reboot_required": stats["system"]["reboot_required"],
        "failed_systemd_units": failures,
        "expected_services_healthy": expected_healthy,
    }


def prom_label(value: Any) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def prometheus(stats: dict[str, Any]) -> str:
    def number(value: Any) -> str:
        return "NaN" if value is None else str(value)

    host = stats.get("host", {})
    cpu = stats.get("cpu", {})
    memory = stats.get("memory", {})
    swap = memory.get("swap", {})
    disk = stats.get("disk_root", {})
    system = stats.get("system", {})
    updates = stats.get("updates", {})
    service_policy = stats.get("service_policy", {})

    lines = [
        "# HELP interstellar_up Interstellar health agent availability.",
        "# TYPE interstellar_up gauge",
        "interstellar_up 1",
        "# HELP interstellar_agent_info Static machine information.",
        "# TYPE interstellar_agent_info gauge",
        'interstellar_agent_info{hostname="%s",machine_id="%s",roles="%s",os="%s",architecture="%s",virtualization="%s",agent_version="%s"} 1'
        % (
            prom_label(host.get("hostname", "")),
            prom_label(host.get("machine_id", "")),
            prom_label(",".join(host.get("roles", []))),
            prom_label(host.get("os", "")),
            prom_label(host.get("architecture", "")),
            prom_label(host.get("virtualization", "")),
            prom_label(VERSION),
        ),
        "# TYPE interstellar_uptime_seconds gauge",
        f"interstellar_uptime_seconds {number(host.get('uptime_seconds'))}",
        "# TYPE interstellar_cpu_used_percent gauge",
        f"interstellar_cpu_used_percent {number(cpu.get('used_percent'))}",
        "# TYPE interstellar_cpu_iowait_percent gauge",
        f"interstellar_cpu_iowait_percent {number(cpu.get('iowait_percent'))}",
        "# TYPE interstellar_cpu_steal_percent gauge",
        f"interstellar_cpu_steal_percent {number(cpu.get('steal_percent'))}",
        "# TYPE interstellar_memory_used_percent gauge",
        f"interstellar_memory_used_percent {number(memory.get('used_percent'))}",
        "# TYPE interstellar_memory_used_bytes gauge",
        f"interstellar_memory_used_bytes {number(memory.get('used_bytes'))}",
        "# TYPE interstellar_swap_used_bytes gauge",
        f"interstellar_swap_used_bytes {number(swap.get('used_bytes'))}",
        "# TYPE interstellar_root_disk_used_percent gauge",
        f"interstellar_root_disk_used_percent {number(disk.get('used_percent'))}",
        "# TYPE interstellar_root_inode_used_percent gauge",
        f"interstellar_root_inode_used_percent {number(disk.get('inode_used_percent'))}",
        "# TYPE interstellar_reboot_required gauge",
        f"interstellar_reboot_required {1 if system.get('reboot_required') else 0}",
        "# TYPE interstellar_failed_systemd_units gauge",
        f"interstellar_failed_systemd_units {system.get('failed_systemd_units', 0)}",
        "# TYPE interstellar_oom_kills_since_boot counter",
        f"interstellar_oom_kills_since_boot {number(system.get('oom_kills_since_boot'))}",
        "# TYPE interstellar_pending_updates gauge",
        f"interstellar_pending_updates {updates.get('pending', 0)}",
        "# TYPE interstellar_pending_security_updates gauge",
        f"interstellar_pending_security_updates {updates.get('pending_security', 0)}",
        "# TYPE interstellar_expected_services_healthy gauge",
        f"interstellar_expected_services_healthy {1 if service_policy.get('healthy', True) else 0}",
    ]

    for service, state in stats.get("services", {}).items():
        lines.append(
            f'interstellar_service_active{{service="{prom_label(service)}",state="{prom_label(state)}"}} {1 if state == "active" else 0}'
        )
    for interface in stats.get("network", {}).get("interfaces", []):
        name = prom_label(interface.get("interface", ""))
        lines.append(f'interstellar_network_rx_bytes{{interface="{name}"}} {number(interface.get("rx_bytes"))}')
        lines.append(f'interstellar_network_tx_bytes{{interface="{name}"}} {number(interface.get("tx_bytes"))}')
        lines.append(f'interstellar_network_rx_bytes_per_second{{interface="{name}"}} {number(interface.get("rx_bytes_per_second"))}')
        lines.append(f'interstellar_network_tx_bytes_per_second{{interface="{name}"}} {number(interface.get("tx_bytes_per_second"))}')
    for item in stats.get("disk_io", []):
        device = prom_label(item.get("device", ""))
        lines.append(f'interstellar_disk_read_bytes{{device="{device}"}} {number(item.get("read_bytes"))}')
        lines.append(f'interstellar_disk_write_bytes{{device="{device}"}} {number(item.get("write_bytes"))}')
        lines.append(f'interstellar_disk_read_bytes_per_second{{device="{device}"}} {number(item.get("read_bytes_per_second"))}')
        lines.append(f'interstellar_disk_write_bytes_per_second{{device="{device}"}} {number(item.get("write_bytes_per_second"))}')
    for filesystem in stats.get("filesystems", []):
        mount = prom_label(filesystem.get("mountpoint", ""))
        lines.append(f'interstellar_filesystem_used_percent{{mountpoint="{mount}"}} {number(filesystem.get("used_percent"))}')
        lines.append(f'interstellar_filesystem_inode_used_percent{{mountpoint="{mount}"}} {number(filesystem.get("inode_used_percent"))}')
    for temperature in stats.get("temperatures", []):
        lines.append(
            f'interstellar_temperature_celsius{{sensor="{prom_label(temperature.get("name", ""))}"}} {number(temperature.get("celsius"))}'
        )
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    server_version = "InterstellarAgent/3.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def json_response(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/":
            self.json_response(
                200,
                {
                    "name": "Interstellar Network Health Agent",
                    "version": VERSION,
                    "hostname": socket.gethostname(),
                    "machine_id": machine_id(),
                    "roles": ROLES,
                    "api": api_info(),
                },
            )
            return
        if path == "/health":
            health = minimal_health()
            self.json_response(200 if health["status"] == "ok" else 503, health)
            return
        if path == "/stats":
            self.json_response(200, collect_stats())
            return
        if path == "/metrics":
            body = prometheus(collect_stats()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self.json_response(404, {"error": "not_found"})


httpd = ThreadingHTTPServer((BIND, PORT), Handler)
print(
    f"Interstellar health agent {VERSION} listening on {BIND}:{PORT} roles={','.join(ROLES)}",
    flush=True,
)
httpd.serve_forever()
PYEOF
  chown root:root "$AGENT_PY"
  chmod 0755 "$AGENT_PY"
}

write_agent_unit() {
  cat >"$AGENT_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Health Agent
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
EnvironmentFile=/etc/default/interstellar-agent
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/agent.py
Restart=on-failure
RestartSec=3

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$AGENT_UNIT"
  chmod 0644 "$AGENT_UNIT"
}

agent_env_value() {
  local key="$1"
  [[ -f "$AGENT_ENV" ]] || return 1
  sed -n -E "s/^${key}=(.*)$/\1/p" "$AGENT_ENV" | tail -1
}

write_agent_env() {
  local port="$1" roles="${2:-general}" expected="${3:-ssh,tailscaled}"
  cat >"$AGENT_ENV" <<EOF
INTERSTELLAR_PORT=${port}
INTERSTELLAR_ROLES=${roles}
INTERSTELLAR_EXPECTED_SERVICES=${expected}
EOF
  chown root:root "$AGENT_ENV"
  chmod 0600 "$AGENT_ENV"
}

install_health_agent() {
  install_pkg python3
  local port roles expected
  port="$(agent_env_value INTERSTELLAR_PORT 2>/dev/null || true)"
  roles="$(agent_env_value INTERSTELLAR_ROLES 2>/dev/null || true)"
  expected="$(agent_env_value INTERSTELLAR_EXPECTED_SERVICES 2>/dev/null || true)"
  port="${port:-9127}"
  roles="${roles:-general}"
  expected="${expected:-ssh,tailscaled}"

  write_agent_python
  write_agent_unit
  write_agent_env "$port" "$roles" "$expected"
  systemctl daemon-reload
  systemctl enable --now interstellar-agent

  fix "Read-only health agent v3 installed/upgraded."
  info "Backend: http://127.0.0.1:${port}"
  info "Roles: ${roles}"
  info "Expected services: ${expected}"
  info "Use Tailscale Serve for remote access; no static bearer token is used."
}

agent_show_status() {
  [[ -f "$AGENT_UNIT" ]] || { warn "Health agent is not installed."; return; }
  systemctl status interstellar-agent --no-pager || true
  echo
  local port
  port="$(agent_env_value INTERSTELLAR_PORT 2>/dev/null || echo 9127)"
  echo "Local read-only backend"
  echo "  Base:    http://127.0.0.1:${port}"
  echo "  Health:  http://127.0.0.1:${port}/health"
  echo "  Stats:   http://127.0.0.1:${port}/stats"
  echo "  Metrics: http://127.0.0.1:${port}/metrics"
  echo
  echo "Listening socket"
  ss -lntp 2>/dev/null | awk -v p=":${port}" 'NR==1 || index($4,p)' | sed 's/^/  /'
  echo
  echo "Tailscale Serve"
  tailscale serve status 2>/dev/null | sed 's/^/  /' || echo "  Not configured"
  echo
  echo
  echo "Server policy"
  echo "  Roles:             $(agent_env_value INTERSTELLAR_ROLES 2>/dev/null || echo general)"
  echo "  Expected services: $(agent_env_value INTERSTELLAR_EXPECTED_SERVICES 2>/dev/null || echo ssh,tailscaled)"
  echo
  echo "Home Assistant discovery"
  systemctl is-active --quiet interstellar-mdns 2>/dev/null && echo "  Active (_interstellar._tcp.local.)" || echo "  Disabled"
  echo
  info "Remote access is controlled by Tailscale identity and tailnet policy."
}
agent_configure_binding() {
  [[ -f "$AGENT_ENV" ]] || { warn "Install the health agent first."; return; }
  local current port roles expected
  current="$(agent_env_value INTERSTELLAR_PORT 2>/dev/null || echo 9127)"
  roles="$(agent_env_value INTERSTELLAR_ROLES 2>/dev/null || echo general)"
  expected="$(agent_env_value INTERSTELLAR_EXPECTED_SERVICES 2>/dev/null || echo ssh,tailscaled)"
  port="$(ui_input "Health API port" "Backend remains on 127.0.0.1.\nEnter local port:" "$current")" || return
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { ui_msg "Invalid port" "Use a port between 1 and 65535."; return; }
  write_agent_env "$port" "$roles" "$expected"
  systemctl restart interstellar-agent
  ui_msg "Health API" "Backend now listens on 127.0.0.1:${port}"
}

agent_rotate_token() {
  ui_msg "Removed" "Static bearer-token authentication was removed in Toolbox v4.\nUse Tailscale Serve and tailnet identity/policy instead."
}

agent_show_token() {
  ui_msg "Removed" "Static bearer-token authentication was removed in Toolbox v4.\nUse Tailscale Serve and tailnet identity/policy instead."
}

agent_configure_roles_services() {
  [[ -f "$AGENT_ENV" ]] || { warn "Install the health agent first."; return; }
  local current_roles current_expected port result rc roles expected
  port="$(agent_env_value INTERSTELLAR_PORT 2>/dev/null || echo 9127)"
  current_roles="$(agent_env_value INTERSTELLAR_ROLES 2>/dev/null || echo general)"
  current_expected="$(agent_env_value INTERSTELLAR_EXPECTED_SERVICES 2>/dev/null || echo ssh,tailscaled)"

  role_on() { [[ ",${current_roles}," == *",$1,"* ]] && echo ON || echo OFF; }
  set +e
  result="$(ui_checklist "Server roles" "Choose one or more roles. Roles are metadata; docker-host also implies Docker should be running." \
    "general" "General-purpose server" "$(role_on general)" \
    "development" "Development workstation / build host" "$(role_on development)" \
    "docker-host" "Docker/container host" "$(role_on docker-host)" \
    "media" "Media server" "$(role_on media)" \
    "home-automation" "Home automation server" "$(role_on home-automation)" \
    "reverse-proxy" "Reverse proxy / ingress" "$(role_on reverse-proxy)" \
    "storage" "Storage / NAS" "$(role_on storage)" \
    "monitoring" "Monitoring / observability" "$(role_on monitoring)" \
    "database" "Database server" "$(role_on database)")"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return
  roles="$(printf '%s' "$result" | tr -d '"' | tr ' ' ',' | sed 's/^,*//;s/,*$//')"
  [[ -n "$roles" ]] || roles="general"

  expected="$(ui_input "Expected services" "Comma-separated systemd service names.\nIf an expected service is not active, Home Assistant will raise a problem.\n\nRole docker-host automatically also expects docker." "$current_expected")" || return
  expected="$(printf '%s' "$expected" | tr -d ' ' | sed 's/^,*//;s/,*$//')"
  [[ -n "$expected" ]] || expected="ssh,tailscaled"

  write_agent_env "$port" "$roles" "$expected"
  systemctl restart interstellar-agent
  ui_msg "Server policy" "Roles: $roles\nExpected services: $expected\n\nAgent restarted."
}

write_mdns_helper() {
  install -d -o root -g root -m 0755 "$AGENT_DIR"
  cat >"$MDNS_PY" <<'PYEOF'
#!/usr/bin/env python3
import os, signal, socket, time
from zeroconf import IPVersion, ServiceInfo, Zeroconf

SERVICE_TYPE = "_interstellar._tcp.local."
hostname = os.environ["INTERSTELLAR_HOSTNAME"]
machine_id = os.environ["INTERSTELLAR_MACHINE_ID"]
url = os.environ["INTERSTELLAR_URL"].rstrip("/")
lan_ip = os.environ["INTERSTELLAR_LAN_IP"]
roles = os.environ.get("INTERSTELLAR_ROLES", "general")
agent_version = os.environ.get("INTERSTELLAR_AGENT_VERSION", "unknown")

info = ServiceInfo(
    SERVICE_TYPE,
    f"{hostname}.{SERVICE_TYPE}",
    addresses=[socket.inet_aton(lan_ip)],
    port=443,
    properties={
        "url": url,
        "machine_id": machine_id,
        "hostname": hostname,
        "roles": roles,
        "agent_version": agent_version,
        "transport": "tailscale-serve",
    },
    server=f"{hostname}.local.",
)
zc = Zeroconf(ip_version=IPVersion.V4Only)
running = True

def stop(*_):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    zc.register_service(info)
    print(f"Advertising {hostname}: {url} via {lan_ip}", flush=True)
    while running:
        time.sleep(1)
finally:
    try: zc.unregister_service(info)
    finally: zc.close()
PYEOF
  chmod 0755 "$MDNS_PY"
}

write_mdns_unit() {
  cat >"$MDNS_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Home Assistant discovery announcer
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
EnvironmentFile=/etc/default/interstellar-mdns
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/mdns.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$MDNS_UNIT"
}

agent_enable_discovery() {
  [[ -f "$AGENT_ENV" ]] || { warn "Install the health agent first."; return; }
  command -v tailscale >/dev/null 2>&1 || { warn "Tailscale is required."; return; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-zeroconf

  local ts_dns lan_ip roles machine
  ts_dns="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
  lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  roles="$(agent_env_value INTERSTELLAR_ROLES 2>/dev/null || echo general)"
  machine="$(cat /etc/machine-id)"
  [[ -n "$ts_dns" && -n "$lan_ip" ]] || { fail "Could not determine Tailscale DNS name or LAN IP."; return; }

  write_mdns_helper
  write_mdns_unit
  cat >"$MDNS_ENV" <<EOF
INTERSTELLAR_HOSTNAME=$(hostname -s)
INTERSTELLAR_MACHINE_ID=${machine}
INTERSTELLAR_URL=https://${ts_dns}
INTERSTELLAR_LAN_IP=${lan_ip}
INTERSTELLAR_ROLES=${roles}
INTERSTELLAR_AGENT_VERSION=3.0.0
EOF
  chmod 0644 "$MDNS_ENV"
  systemctl daemon-reload
  systemctl enable --now interstellar-mdns
  fix "Home Assistant auto-discovery enabled."
  info "mDNS: _interstellar._tcp.local."
  info "Advertised URL: https://${ts_dns}"
}

agent_disable_discovery() {
  systemctl disable --now interstellar-mdns 2>/dev/null || true
  rm -f "$MDNS_UNIT" "$MDNS_ENV" "$MDNS_PY"
  systemctl daemon-reload
  fix "Home Assistant mDNS discovery disabled."
}

agent_enable_tailscale_serve() {
  [[ -f "$AGENT_ENV" ]] || { warn "Install the health agent first."; return; }
  command -v tailscale >/dev/null 2>&1 || { warn "Tailscale is not installed."; return; }
  local port
  port="$(agent_env_value INTERSTELLAR_PORT 2>/dev/null || echo 9127)"
  clear
  info "Serving localhost:${port} inside the tailnet."
  tailscale serve --bg "$port"
  echo
  tailscale serve status || true
}

agent_disable_tailscale_serve() {
  command -v tailscale >/dev/null 2>&1 || return
  tailscale serve off || true
  fix "Tailscale Serve disabled."
}

agent_security_model() {
  ui_msg "Health/control security" "HEALTH PLANE
• read-only HTTP backend
• listens on 127.0.0.1 only
• Tailscale Serve provides encrypted tailnet access
• Tailscale ACL/Grants decide who can connect
• no reusable bearer token

CONTROL PLANE
Reboot/update/firewall actions are NOT exposed over this health API.

Remote privileged actions should use:
SSH + Tailscale + sudo + interstellar

A future web control plane should be separate, use Tailscale identity/app capabilities, a local root helper over a Unix socket, and audit every action."
}

agent_local_url() {
  local port
  port="$(agent_env_value INTERSTELLAR_PORT 2>/dev/null || echo 9127)"
  printf 'http://127.0.0.1:%s' "$port"
}

agent_test_health() {
  local url
  url="$(agent_local_url)"
  curl -fsS "${url}/health" | python3 -m json.tool
}

agent_test_stats() {
  local url
  url="$(agent_local_url)"
  curl -fsS "${url}/stats" | python3 -m json.tool
}

agent_test_metrics() {
  local url
  url="$(agent_local_url)"
  curl -fsS "${url}/metrics"
}

agent_toggle_public_health() {
  ui_msg "Removed" "Static bearer-token authentication was removed in Toolbox v4.\nUse Tailscale Serve and tailnet identity/policy instead."
}

agent_uninstall() {
  ui_yesno "Uninstall health agent" "Remove the local Interstellar health agent?" || return
  systemctl disable --now interstellar-agent 2>/dev/null || true
  systemctl disable --now interstellar-mdns 2>/dev/null || true
  rm -f "$AGENT_UNIT" "$AGENT_ENV" "$AGENT_PY" "$MDNS_UNIT" "$MDNS_ENV" "$MDNS_PY"
  rmdir "$AGENT_DIR" 2>/dev/null || true
  systemctl daemon-reload
  fix "Health agent uninstalled."
  info "Tailscale Serve is left unchanged; disable it separately if desired."
}

agent_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Health API agent" \
"Read-only server telemetry, policy and Home Assistant discovery." \
      "1" "Show status, policy, ports & Serve URL" \
      "2" "Install / repair / upgrade agent" \
      "3" "Change local API port" \
      "4" "Configure server roles & expected services" \
      "5" "Enable Tailscale Serve" \
      "6" "Disable Tailscale Serve" \
      "7" "Enable Home Assistant auto-discovery" \
      "8" "Disable Home Assistant auto-discovery" \
      "9" "Test /health" \
      "10" "Test /stats" \
      "11" "Test /metrics" \
      "12" "Explain security model" \
      "13" "Restart agent" \
      "14" "Uninstall agent" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; agent_show_status; pause ;;
      2) clear; install_health_agent; pause ;;
      3) agent_configure_binding ;;
      4) agent_configure_roles_services ;;
      5) clear; agent_enable_tailscale_serve; pause ;;
      6) clear; agent_disable_tailscale_serve; pause ;;
      7) clear; agent_enable_discovery; pause ;;
      8) clear; agent_disable_discovery; pause ;;
      9) clear; agent_test_health; pause ;;
      10) clear; agent_test_stats; pause ;;
      11) clear; agent_test_metrics; pause ;;
      12) agent_security_model ;;
      13) systemctl restart interstellar-agent; ui_msg "Health API" "Agent restarted." ;;
      14) clear; agent_uninstall; pause ;;
      0) return ;;
    esac
  done
}

# ---------------- Manager security ----------------

manager_security_status() {
  local self_path owner mode
  self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  owner="$(stat -c '%U:%G' "$self_path" 2>/dev/null || echo '?')"
  mode="$(stat -c '%a' "$self_path" 2>/dev/null || echo '?')"

  echo "Running file: $self_path"
  echo "Owner:        $owner"
  echo "Mode:         $mode"
  echo "Secure path:  $MANAGER_INSTALL_PATH"
  echo "CLI command:  /usr/local/bin/interstellar"
  echo
  if [[ "$self_path" == "$MANAGER_INSTALL_PATH" && "$owner" == "root:root" && "$mode" == "700" ]]; then
    ok "Manager is installed root-only."
  else
    warn "Manager is not currently installed as root:root mode 0700."
  fi
}

manager_install_secure() {
  local self_path
  self_path="$(readlink -f "$0")"

  if [[ "$self_path" == "$MANAGER_INSTALL_PATH" ]]; then
    chown root:root "$MANAGER_INSTALL_PATH"
    chmod 0700 "$MANAGER_INSTALL_PATH"
    fix "Secured existing installation as root:root mode 0700."
  else
    install -o root -g root -m 0700 "$self_path" "$MANAGER_INSTALL_PATH"
    fix "Installed root-only manager at $MANAGER_INSTALL_PATH"
  fi

  cat >/usr/local/bin/interstellar <<'EOF'
#!/bin/sh
if [ "$(id -u)" -eq 0 ]; then
  exec /usr/local/sbin/interstellar-toolbox "$@"
else
  exec sudo /usr/local/sbin/interstellar-toolbox "$@"
fi
EOF
  chown root:root /usr/local/bin/interstellar
  chmod 0755 /usr/local/bin/interstellar

  echo
  ok "Installed command: interstellar"
  info "From now on simply type:"
  echo "  interstellar"
  info "The actual manager remains root:root mode 0700."
  warn "Users still need sudo permission to run the manager."
}


manager_latest_release_version() {
  local effective tag
  effective="$(
    curl -fsSIL -o /dev/null -w '%{url_effective}' \
      "https://github.com/${RELEASE_REPO}/releases/latest" 2>/dev/null
  )" || return 1

  tag="${effective##*/}"
  tag="${tag#v}"
  [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
  printf '%s\n' "$tag"
}

manager_release_status() {
  clear
  echo "Interstellar Network Toolbox"
  echo "  Installed version: ${VERSION}"
  echo "  Release repository: https://github.com/${RELEASE_REPO}"
  echo

  local latest
  if ! latest="$(manager_latest_release_version)"; then
    warn "Could not determine the latest GitHub release."
    info "Check internet/DNS connectivity or repository name."
    return 1
  fi

  echo "  Latest release:    ${latest}"
  echo

  if dpkg --compare-versions "$latest" gt "$VERSION"; then
    warn "Update available: ${VERSION} -> ${latest}"
    return 2
  elif dpkg --compare-versions "$latest" eq "$VERSION"; then
    ok "Toolbox is up to date."
  else
    info "Installed version ${VERSION} is newer than the latest published release ${latest}."
  fi
}

manager_update_latest() {
  local latest tmp asset sums expected actual
  latest="$(manager_latest_release_version)" || {
    ui_msg "Update failed" "Could not determine the latest Interstellar Network release."
    return 1
  }

  if ! dpkg --compare-versions "$latest" gt "$VERSION"; then
    ui_msg "Interstellar Network" "Installed: ${VERSION}\nLatest: ${latest}\n\nNo newer release is available."
    return 0
  fi

  if ! ui_yesno "Update Interstellar Network" \
"Update the Interstellar Network Toolbox?

Current: ${VERSION}
Latest:  ${latest}

The release is downloaded from:
${RELEASE_REPO}

SHA-256 will be verified before installation."; then
    return 0
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  asset="$tmp/$RELEASE_ASSET"
  sums="$tmp/$RELEASE_SUMS_ASSET"

  clear
  info "Downloading Interstellar Network ${latest}..."

  curl -fL --retry 3 --connect-timeout 10 \
    "https://github.com/${RELEASE_REPO}/releases/download/v${latest}/${RELEASE_ASSET}" \
    -o "$asset"

  curl -fL --retry 3 --connect-timeout 10 \
    "https://github.com/${RELEASE_REPO}/releases/download/v${latest}/${RELEASE_SUMS_ASSET}" \
    -o "$sums"

  expected="$(
    awk -v file="$RELEASE_ASSET" '$2 == file || $2 == ("*" file) {print $1; exit}' "$sums"
  )"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
    fail "Release checksum file is invalid."
    return 1
  }

  actual="$(sha256sum "$asset" | awk '{print $1}')"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    fail "SHA-256 verification failed."
    echo "Expected: $expected"
    echo "Actual:   $actual"
    return 1
  fi

  ok "SHA-256 verified."

  bash -n "$asset" || {
    fail "Downloaded toolbox failed bash syntax validation."
    return 1
  }

  install -o root -g root -m 0700 "$asset" "$MANAGER_INSTALL_PATH"

  # Ensure the friendly command exists as well.
  cat >/usr/local/bin/interstellar <<'EOF'
#!/bin/sh
if [ "$(id -u)" -eq 0 ]; then
  exec /usr/local/sbin/interstellar-toolbox "$@"
else
  exec sudo /usr/local/sbin/interstellar-toolbox "$@"
fi
EOF
  chown root:root /usr/local/bin/interstellar
  chmod 0755 /usr/local/bin/interstellar

  fix "Interstellar Network Toolbox updated to ${latest}."

  if systemctl list-unit-files interstellar-agent.service >/dev/null 2>&1; then
    echo
    info "Refreshing the embedded Interstellar health agent..."
    # Re-run using the new script so the agent version bundled in that
    # release is installed rather than the implementation from this process.
    "$MANAGER_INSTALL_PATH" --upgrade-agent-noninteractive || \
      warn "Toolbox updated, but automatic health-agent refresh failed."
  fi

  echo
  info "Restarting the toolbox with the new release..."
  sleep 1
  exec "$MANAGER_INSTALL_PATH"
}

manager_security_menu() {
  while true; do
    local choice rc
    choice="$(ui_menu "Toolbox & releases" "Manage the Interstellar Network Toolbox." \
      "1" "Show toolbox file security" \
      "2" "Install / secure as root-only (root:root 0700)" \
      "3" "Check for updates" \
      "4" "Update to latest GitHub release" \
      "5" "Show release repository" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; manager_security_status; pause ;;
      2) clear; manager_install_secure; pause ;;
      3)
        set +e
        manager_release_status
        rc=$?
        set -e
        pause
        ;;
      4) manager_update_latest ;;
      5)
        ui_msg "Interstellar Network releases" \
"Repository:
https://github.com/${RELEASE_REPO}

Installed toolbox:
${VERSION}

Release assets:
${RELEASE_ASSET}
${RELEASE_SUMS_ASSET}"
        ;;
      0) return ;;
    esac
  done
}

# ---------------- System maintenance ----------------

auto_updates_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Automatic updates" "Manage unattended security updates." \
      "1" "Show auto-update status" \
      "2" "Enable auto updates" \
      "3" "Disable auto updates" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || true; echo; systemctl list-timers 'apt-daily*' --no-pager 2>/dev/null || true; pause ;;
      2) install_pkg unattended-upgrades; printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' >/etc/apt/apt.conf.d/20auto-upgrades; ui_msg "Automatic updates" "Enabled. Automatic reboot remains disabled." ;;
      3) backup_file /etc/apt/apt.conf.d/20auto-upgrades; printf '%s\n' 'APT::Periodic::Update-Package-Lists "0";' 'APT::Periodic::Unattended-Upgrade "0";' >/etc/apt/apt.conf.d/20auto-upgrades; ui_msg "Automatic updates" "Disabled." ;;
      0) return ;;
    esac
  done
}

guest_agent_status() {
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  echo "Virtualization: ${virt:-unknown}"
  case "$virt" in
    kvm|qemu)
      if ! is_installed qemu-guest-agent; then
        warn "qemu-guest-agent not installed."
        confirm "Install it?" && install_pkg qemu-guest-agent
      fi
      if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
        ok "Guest-agent channel present."
        if ! systemctl is-active --quiet qemu-guest-agent; then
          systemctl start qemu-guest-agent || true
        fi
        systemctl status qemu-guest-agent --no-pager || true
      else
        warn "Guest-agent channel missing. Enable QEMU Guest Agent in Proxmox and cold boot."
      fi
      ;;
    lxc) info "LXC guest: QEMU Guest Agent is not applicable." ;;
    *) info "No QEMU/KVM guest detected." ;;
  esac
}

system_menu() {
  while true; do
    local choice new_hostname
    choice="$(ui_menu "System maintenance" "System-level maintenance." \
      "1" "apt update" \
      "2" "apt full-upgrade" \
      "3" "Automatic updates" \
      "4" "QEMU Guest Agent" \
      "5" "Show failed services" \
      "6" "Show disk / memory / uptime" \
      "7" "Change hostname" \
      "8" "Show OS / kernel / CPU / virtualization" \
      "9" "Reboot" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; apt-get update; pause ;;
      2) clear; apt-get update; apt-get full-upgrade; pause ;;
      3) auto_updates_menu ;;
      4) clear; guest_agent_status; pause ;;
      5) clear; systemctl --failed --no-pager || true; pause ;;
      6) clear; df -h /; echo; free -h; echo; uptime; echo; [[ -f /var/run/reboot-required ]] && warn "Reboot required" || ok "No reboot required"; pause ;;
      7)
        new_hostname="$(ui_input "Hostname" "Enter new hostname:" "$(hostname)")" || continue
        if [[ "$new_hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
          hostnamectl set-hostname "$new_hostname"
          UI_BACKTITLE="Interstellar Network Toolbox v${VERSION} | $(hostname)"
          ui_msg "Hostname" "Hostname changed to $new_hostname."
        else
          ui_msg "Invalid hostname" "The supplied hostname is invalid."
        fi ;;
      8) clear; echo "OS: ${PRETTY_NAME:-unknown}"; echo "Kernel: $(uname -r)"; echo "Architecture: $(uname -m)"; echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo none)"; echo; lscpu 2>/dev/null | grep -E '^(Model name|CPU\(s\)|Thread|Core|Socket|Virtualization|Flags):' || true; pause ;;
      9) ui_yesno "Reboot" "Reboot $(hostname) now?" && reboot ;;
      0) return ;;
    esac
  done
}

# ---------------- Main menu ----------------

main_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Interstellar Network Toolbox" "Server administration for $(hostname)." \
      "1" "Health check" \
      "2" "Change password" \
      "3" "Firewall changes" \
      "4" "Startup text" \
      "5" "SSH settings" \
      "6" "Tailscale & networking" \
      "7" "Install tools" \
      "8" "Docker & containers" \
      "9" "System maintenance" \
      "10" "Health API agent" \
      "11" "Toolbox & releases" \
      "0" "Exit")" || exit 0
    case "$choice" in
      1) health_menu ;;
      2) password_menu ;;
      3) firewall_menu ;;
      4) motd_menu ;;
      5) ssh_menu ;;
      6) tailscale_menu ;;
      7) tools_menu ;;
      8) docker_menu ;;
      9) system_menu ;;
      10) agent_menu ;;
      11) manager_security_menu ;;
      0) clear 2>/dev/null || true; echo "Bye."; exit 0 ;;
    esac
  done
}


if [[ "${1:-}" == "--upgrade-agent-noninteractive" ]]; then
  install_health_agent
  exit 0
fi

main_menu

#!/usr/bin/env bash
set -Eeuo pipefail

# Interstellar Network Toolbox
# Supports Debian and Ubuntu.
# Start without arguments for the interactive menu.

TOOLBOX_VERSION="4.6.1"
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

UI_BACKTITLE="Interstellar Network Toolbox v${TOOLBOX_VERSION} | $(hostname)"

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
    "$BOLD" "$RESET" "$TOOLBOX_VERSION" "$(hostname)" "${PRETTY_NAME:-Linux}"
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
      "7" "Wake-on-LAN" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; tailscale_status_show; pause ;;
      2) clear; tailscale_install; pause ;;
      3) clear; tailscale_install; tailscale up; pause ;;
      4) clear; command -v tailscale >/dev/null 2>&1 && tailscale down; pause ;;
      5) clear; network_info; pause ;;
      6) clear; tailscale serve status 2>/dev/null || true; pause ;;
      7) wol_menu ;;
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

CONTROL_API_PY="${AGENT_DIR}/control-api.py"
CONTROL_API_UNIT="/etc/systemd/system/interstellar-control-api.service"

CONTROL_HELPER_PY="${AGENT_DIR}/control-helper.py"
CONTROL_HELPER_UNIT="/etc/systemd/system/interstellar-control-helper.service"
CONTROL_POLICY="/etc/interstellar/control-policy.json"
WOL_PY="${AGENT_DIR}/wol.py"
WOL_UNIT="/etc/systemd/system/interstellar-wol.service"

write_wol_python() {
  install -d -o root -g root -m 0755 "$AGENT_DIR"
  cat >"$WOL_PY" <<'PYEOF'
#!/usr/bin/env python3
"""Apply only a validated, root-configured magic-packet WoL setting."""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

NET = Path("/sys/class/net")
CONFIG = Path("/etc/interstellar/wol.json")
ETHTOOL = "/usr/sbin/ethtool"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}\Z")
MAC = re.compile(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\Z")


def physical(name):
    return bool(NAME.fullmatch(name) and (NET / name / "device").exists())


def interfaces():
    return [p.name for p in sorted(NET.iterdir()) if physical(p.name)]


def details(name):
    if not physical(name):
        raise ValueError("Interface is not a physical network interface")
    mac = (NET / name / "address").read_text().strip().lower()
    if not MAC.fullmatch(mac) or mac == "00:00:00:00:00:00":
        raise ValueError("Interface has no valid MAC address")
    proc = subprocess.run([ETHTOOL, name], capture_output=True, text=True, timeout=5, check=False)
    if proc.returncode:
        raise ValueError("Cannot read Wake-on-LAN capabilities")
    supports = re.search(r"^\s*Supports Wake-on:\s*(\S+)", proc.stdout, re.M)
    current = re.search(r"^\s*Wake-on:\s*(\S+)", proc.stdout, re.M)
    return {"interface": name, "mac_address": mac,
            "supported": bool(supports and "g" in supports.group(1)),
            "enabled": bool(current and "g" in current.group(1)),
            "supports_modes": supports.group(1) if supports else "unknown",
            "current_modes": current.group(1) if current else "unknown"}


def config():
    try:
        value = json.loads(CONFIG.read_text())
    except FileNotFoundError:
        return {"enabled": False, "interface": None, "mac_address": None}
    if not isinstance(value, dict) or not isinstance(value.get("enabled"), bool):
        raise ValueError("Invalid WoL configuration")
    name, mac = value.get("interface"), value.get("mac_address")
    if not isinstance(name, str) or not NAME.fullmatch(name) or not isinstance(mac, str) or not MAC.fullmatch(mac):
        raise ValueError("Invalid WoL interface or MAC")
    return value


def save(value):
    CONFIG.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=CONFIG.parent, delete=False) as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    try:
        os.chmod(temporary, 0o644)
        os.chown(temporary, 0, 0)
        os.replace(temporary, CONFIG)
    finally:
        temporary.unlink(missing_ok=True)


def virtual_machine():
    try:
        return subprocess.run(["/usr/bin/systemd-detect-virt", "--vm"],
                              capture_output=True, timeout=3, check=False).returncode == 0
    except OSError:
        return False


def apply(name, expected_mac):
    value = details(name)
    if value["mac_address"] != expected_mac or not value["supported"]:
        raise ValueError("Configured NIC changed or magic-packet wake is unsupported")
    proc = subprocess.run([ETHTOOL, "-s", name, "wol", "g"],
                          capture_output=True, timeout=5, check=False)
    if proc.returncode:
        raise RuntimeError("Failed to enable magic-packet wake")


def main(argv):
    if len(argv) not in (1, 2) or argv[0] not in {"list", "status", "select", "enable", "disable", "apply", "test"}:
        raise ValueError("Unsupported WoL operation")
    action = argv[0]
    if action == "list":
        for name in interfaces():
            try:
                value = details(name)
                print(f'{name}\t{value["mac_address"]}\t{"magic packet" if value["supported"] else "unsupported"}')
            except (OSError, ValueError):
                print(f"{name}\tunknown\tunavailable")
        return
    selected = config()
    if action == "select":
        if len(argv) != 2 or selected["enabled"]:
            raise ValueError("Disable WoL before selecting another interface")
        value = details(argv[1])
        if not value["supported"]:
            raise ValueError("Selected NIC does not support magic-packet wake")
        save({"enabled": False, "interface": argv[1], "mac_address": value["mac_address"]})
        print(f'Selected {argv[1]} ({value["mac_address"]})')
        return
    if len(argv) != 1:
        raise ValueError("Unexpected WoL argument")
    name = selected["interface"]
    if action in {"enable", "apply"}:
        if not name:
            raise ValueError("Select a physical interface first")
        if virtual_machine():
            raise ValueError("This is a VM; configure power-on at the hypervisor instead")
        if action == "apply" and not selected["enabled"]:
            raise ValueError("WoL is not configured as enabled")
        if action == "apply":
            for _ in range(30):
                if physical(name):
                    break
                time.sleep(1)
        apply(name, selected["mac_address"])
        if action == "enable":
            save({**selected, "enabled": True})
        print("Magic-packet wake enabled")
        return
    if action == "disable":
        if name:
            save({**selected, "enabled": False})
        if name and physical(name):
            proc = subprocess.run([ETHTOOL, "-s", name, "wol", "d"],
                                  capture_output=True, timeout=5, check=False)
            if proc.returncode:
                raise RuntimeError("Persistence disabled, but the current NIC setting could not be changed")
        print("Magic-packet wake disabled")
        return
    value = details(name) if name else None
    persistent = subprocess.run(["/usr/bin/systemctl", "is-enabled", "interstellar-wol.service"],
                                capture_output=True, timeout=5, check=False).returncode == 0
    if action == "test":
        if not selected["enabled"] or not persistent or not value or not value["enabled"] or value["mac_address"] != selected["mac_address"]:
            raise ValueError("WoL configuration is not active and persistent")
        print("WoL is active and configured for reboot persistence")
        return
    print(f'Interface:       {name or "none"}')
    print(f'MAC:             {selected["mac_address"] or "unknown"}')
    print(f'WoL supported:   {"yes" if value and value["supported"] else "no"}')
    print(f'Magic packet:    {"supported" if value and value["supported"] else "unsupported"}')
    print(f'WoL enabled:     {"yes" if value and value["enabled"] else "no"}')
    print(f'Persistent:      {"yes" if selected["enabled"] and persistent else "no"}')
    if virtual_machine():
        print("VM detected: WoL from the guest cannot be relied on; use hypervisor power controls.")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"WoL: {error}", file=sys.stderr)
        raise SystemExit(1)
PYEOF
  chown root:root "$WOL_PY"
  chmod 0755 "$WOL_PY"
}

write_wol_unit() {
  cat >"$WOL_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Wake-on-LAN persistence
After=systemd-udevd.service

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/wol.py apply
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_INET AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$WOL_UNIT"
  chmod 0644 "$WOL_UNIT"
}

wol_menu() {
  install_pkg ethtool
  write_wol_python
  write_wol_unit
  systemctl daemon-reload
  while true; do
    local choice selected
    choice="$(ui_menu "Wake-on-LAN" "Configure magic-packet wake for a physical NIC." \
      "1" "Show status" \
      "2" "Enable Wake-on-LAN" \
      "3" "Disable Wake-on-LAN" \
      "4" "Select interface" \
      "5" "Show MAC address / interfaces" \
      "6" "Test persistence / configuration" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; python3 "$WOL_PY" status; pause ;;
      2) clear; if python3 "$WOL_PY" enable; then systemctl enable --now interstellar-wol.service; fi; pause ;;
      3) clear; systemctl disable --now interstellar-wol.service 2>/dev/null || true; python3 "$WOL_PY" disable; pause ;;
      4) clear; python3 "$WOL_PY" list; selected="$(ui_input "WoL interface" "Enter a listed physical interface name:")" || continue; python3 "$WOL_PY" select "$selected"; pause ;;
      5) clear; python3 "$WOL_PY" list; python3 "$WOL_PY" status; pause ;;
      6) clear; python3 "$WOL_PY" test; pause ;;
      0) return ;;
    esac
  done
}

write_agent_python() {
  install -d -o root -g root -m 0755 "$AGENT_DIR"
  cat >"$AGENT_PY" <<'PYEOF'
#!/usr/bin/env python3
from __future__ import annotations

import glob
import ipaddress
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

VERSION = "3.2.1"
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
_apt_cache: tuple[float, tuple[float | None, float | None], dict[str, Any]] | None = None


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

# systemd RuntimeDirectory per unit, used when `systemctl show` is unavailable.
SERVICE_RUNTIME_PATHS: dict[str, str] = {
    "interstellar-control-api": "/run/interstellar-control-api",
    "interstellar-control-helper": "/run/interstellar-control",
}
CONTROL_POLICY_PATH = "/etc/interstellar/control-policy.json"


def service_state(name: str) -> str:
    output = run([SYSTEMCTL, "show", "-p", "ActiveState", "--value", name], timeout=2.0)
    if output in {"active", "inactive", "failed", "activating", "deactivating", "reloading"}:
        return output
    runtime = SERVICE_RUNTIME_PATHS.get(name)
    if runtime:
        # These units run as `python3`, so /proc comm matching cannot see them.
        # systemd drops RuntimeDirectory when the unit stops, and the directory
        # entry is stat-able by the unprivileged agent without entering it.
        return "active" if os.path.isdir(runtime) else "inactive"
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

    deltas = [b - a for a, b in zip(first, second)]
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
        unit = parts[1] if parts[0] == "●" and len(parts) > 1 else parts[0].lstrip("●")
        if unit:
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
    last_cache = newest_mtime(["/var/lib/apt/lists/*"])
    last_package_change = newest_mtime(["/var/lib/dpkg/status"])
    fingerprint = (last_cache, last_package_change)
    if _apt_cache and monotonic_now - _apt_cache[0] < APT_CACHE_SECONDS and _apt_cache[1] == fingerprint:
        return _apt_cache[2]

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
        is_security = "security" in repo.lower()
        if is_security:
            security += 1
        packages.append(
            {
                "name": package_name,
                "version": version,
                "available_version": version,
                "installed_version": (line.split("[upgradable from: ", 1)[1].split("]", 1)[0]
                                      if "[upgradable from: " in line else None),
                "repository": repo,
                "security": is_security,
            }
        )

    result = {
        "pending": len(packages),
        "pending_security": security,
        "packages": packages[:100],
        "last_cache_update_utc": iso_from_timestamp(last_cache),
        "last_package_change_utc": iso_from_timestamp(last_package_change),
        "last_successful_update_utc": last_apt_history_end() or iso_from_timestamp(last_package_change),
        "cache_seconds": APT_CACHE_SECONDS,
    }
    _apt_cache = (monotonic_now, fingerprint, result)
    return result


def tailscale_status() -> dict[str, Any]:
    version = run([TAILSCALE, "version"], timeout=3.0).splitlines()
    installed = version[0] if version else None
    try:
        data = json.loads(run([TAILSCALE, "status", "--json"], timeout=3.0))
    except (ValueError, TypeError):
        return {"connected": False, "version": installed, "daemon_version": None}
    self_node = data.get("Self") or {}
    serve = run([TAILSCALE, "serve", "status"], timeout=3.0)
    return {"connected": data.get("BackendState") == "Running",
            "version": installed,
            "daemon_version": data.get("Version"),
            "magicdns_name": str(self_node.get("DNSName") or "").rstrip(".") or None,
            "serve_enabled": bool(serve and "No serve config" not in serve)}


def control_plane_status(tailscale: dict[str, Any], services: dict[str, str]) -> dict[str, Any]:
    raw = tailscale.get("version") or ""
    daemon = tailscale.get("daemon_version") or ""
    def supported(value: str, daemon_version: bool = False) -> bool:
        match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", value)
        if not match:
            return False
        version = tuple(int(match.group(i)) for i in (1, 2, 3))
        suffix = match.group(4)
        release_hashes = bool(daemon_version and suffix and re.fullmatch(r"[tg]?[0-9a-f]{6,}(?:-[tg]?[0-9a-f]{6,})?", suffix))
        return version > (1, 98, 9) or version == (1, 98, 9) and (not suffix or release_hashes)
    valid = supported(raw) and supported(daemon, True)
    installed = os.path.exists(CONTROL_POLICY_PATH)
    api_active = services.get("interstellar-control-api") == "active"
    helper_active = services.get("interstellar-control-helper") == "active"
    # These are three independent facts. The health agent can observe local
    # service state, can infer whether a Serve listener ought to exist, and can
    # never know whether Home Assistant holds the tailnet app capability. Only
    # the control API itself can answer that, so nothing here may be reported
    # as "control is available to Home Assistant".
    reason = None
    if not installed:
        reason = "Control plane is not installed"
    elif not valid:
        reason = "Tailscale CLI and running daemon must both be 1.98.9 or newer"
    elif not api_active:
        reason = "Control API service is not active"
    elif not helper_active:
        reason = "Control helper service is not active"
    return {"installed": installed,
            "api_service_active": api_active,
            "helper_service_active": helper_active,
            "serve_expected": installed and valid,
            "tailscale_version_supported": valid,
            "control_service_ready": reason is None,
            "control_service_unavailable_reason": reason,
            # Retained for older Home Assistant integrations. These describe local
            # service readiness only, never remote authorization.
            "control_available": reason is None, "control_unavailable_reason": reason,
            "tailscale_version": raw or None, "tailscale_daemon_version": daemon or None,
            "tailscale_control_minimum_version": "1.98.9"}


def wake_on_lan_stats() -> dict[str, Any]:
    result = {"supported": False, "enabled": False, "interface": None, "mac_address": None}
    try:
        with open("/etc/interstellar/wol.json", encoding="utf-8") as handle:
            config = json.load(handle)
        if not isinstance(config, dict) or not isinstance(config.get("enabled"), bool):
            return result
        name = config.get("interface")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}", name):
            return result
        if not os.path.exists(f"/sys/class/net/{name}/device"):
            return result
        mac = read_text(f"/sys/class/net/{name}/address")
        if not mac or not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac.lower()):
            return result
        if mac.lower() != config.get("mac_address"):
            return result
        result.update({"interface": name, "mac_address": mac.lower()})
        output = run([which("ethtool", ("/usr/sbin/ethtool",)), name], timeout=3.0)
        modes = re.search(r"^\s*Supports Wake-on:\s*(\S+)", output, re.M)
        current = re.search(r"^\s*Wake-on:\s*(\S+)", output, re.M)
        result["supported"] = bool(modes and "g" in modes.group(1))
        result["enabled"] = bool(config["enabled"] and current and "g" in current.group(1) and result["supported"])
        if virtualization() != "none":
            result["supported"] = False
            result["enabled"] = False
            result["unavailable_reason"] = "Virtualized NIC wake cannot be verified from the guest"
        try:
            addr = json.loads(run([IP, "-j", "-4", "addr", "show", "dev", name], timeout=3.0))
            broadcasts = [x.get("broadcast") for item in addr for x in item.get("addr_info", [])
                          if x.get("family") == "inet" and x.get("scope") == "global" and x.get("broadcast")]
            if len(broadcasts) == 1:
                candidate = ipaddress.IPv4Address(broadcasts[0])
                if not (candidate.is_multicast or candidate.is_loopback or candidate.is_unspecified):
                    result["broadcast_address"] = str(candidate)
        except (ValueError, TypeError, KeyError):
            pass
    except (OSError, ValueError, TypeError):
        pass
    return result


def control_policy() -> dict[str, Any]:
    try:
        with open("/etc/interstellar/control-policy.json", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def role_metadata() -> dict[str, Any]:
    policy = control_policy()
    expected = policy.get("expected_services")
    if not isinstance(expected, list):
        expected = EXPECTED_SERVICES
    manageable = policy.get("manageable_services")
    if not isinstance(manageable, list):
        manageable = []
    return {
        "roles": ROLES,
        "configured_expected_services": expected,
        "expected_services": list(dict.fromkeys(expected)),
        "manageable_services": list(dict.fromkeys(manageable)),
    }


def service_stats() -> tuple[dict[str, str], list[dict[str, str]]]:
    metadata = role_metadata()
    names = ["ssh", "tailscaled", "docker", "qemu-guest-agent", "systemd-timesyncd",
             "interstellar-agent", "interstellar-control-api", "interstellar-control-helper", "interstellar-mdns"]
    names.extend(metadata["expected_services"])
    names.extend(metadata["manageable_services"])
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
    tailscale = tailscale_status()
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
            "tailscale": tailscale,
            "interfaces": network_stats(),
            "tailscale_ipv4": tailscale_ipv4(addresses),
            "default_route": default_route(),
            "listening_tcp": listening_tcp(),
        },
        "services": services,
        "control_plane": control_plane_status(tailscale, services),
        "wake_on_lan": wake_on_lan_stats(),
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
    server_version = "InterstellarAgent/3.2"

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


tailscale_control_version_supported() {
  local installed metadata
  installed="$(tailscale version 2>/dev/null | head -n 1 || true)"
  metadata="$(tailscale version --daemon --json 2>/dev/null || true)"
  echo "Installed Tailscale: ${installed:-unavailable}"
  echo "Minimum for control: 1.98.9"
  python3 - "$installed" "$metadata" <<'PYEOF'
import json, re, sys
try:
    value = json.loads(sys.argv[2])
except ValueError:
    value = {}
client = value.get("short") if isinstance(value, dict) else None
daemon = value.get("daemonLong") if isinstance(value, dict) else None
print(f"Running tailscaled: {daemon or 'unavailable'}")
def supported(raw, daemon_version=False):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", raw or "")
    if not match:
        return False
    version = tuple(int(match.group(i)) for i in (1, 2, 3))
    suffix = match.group(4)
    release_hashes = bool(daemon_version and suffix and re.fullmatch(r"[tg]?[0-9a-f]{6,}(?:-[tg]?[0-9a-f]{6,})?", suffix))
    return version > (1, 98, 9) or version == (1, 98, 9) and (not suffix or release_hashes)
raise SystemExit(0 if client == sys.argv[1] and supported(client) and supported(daemon, True) else 1)
PYEOF
}

# ---------------- Tailscale Serve topology ----------------
#
# Health:  https://<magicdns>/      -> http://127.0.0.1:<health port>
# Control: https://<magicdns>:8443/ -> unix:/run/interstellar-control-api/api.sock
#
# The control handler must also accept the app capability. Without it Serve
# strips the capability header and the control API answers every request with
# HTTP 403, even though both services are running.

CONTROL_SERVE_PORT="8443"
CONTROL_CAPABILITY="interstellarnetwork.nl/cap/server-control"
CONTROL_API_SOCKET="/run/interstellar-control-api/api.sock"
CONTROL_SERVE_TARGET="unix:${CONTROL_API_SOCKET}"
CONTROL_HELPER_SOCKET="/run/interstellar-control/helper.sock"

tailscale_available() { command -v tailscale >/dev/null 2>&1; }

# Same version policy as tailscale_control_version_supported, without its output.
tailscale_control_version_ok() {
  tailscale_available || return 1
  local installed metadata
  installed="$(tailscale version 2>/dev/null | head -n 1 || true)"
  metadata="$(tailscale version --daemon --json 2>/dev/null || true)"
  python3 - "$installed" "$metadata" <<'PYEOF'
import json, re, sys
try:
    value = json.loads(sys.argv[2])
except ValueError:
    value = {}
client = value.get("short") if isinstance(value, dict) else None
daemon = value.get("daemonLong") if isinstance(value, dict) else None
def supported(raw, daemon_version=False):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", raw or "")
    if not match:
        return False
    version = tuple(int(match.group(i)) for i in (1, 2, 3))
    suffix = match.group(4)
    release_hashes = bool(daemon_version and suffix and re.fullmatch(r"[tg]?[0-9a-f]{6,}(?:-[tg]?[0-9a-f]{6,})?", suffix))
    return version > (1, 98, 9) or version == (1, 98, 9) and (not suffix or release_hashes)
raise SystemExit(0 if client == sys.argv[1] and supported(client) and supported(daemon, True) else 1)
PYEOF
}

health_serve_port() { agent_env_value INTERSTELLAR_PORT 2>/dev/null || echo 9127; }

magicdns_name() {
  tailscale_available || return 0
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
node = data.get("Self") or {}
print(str(node.get("DNSName") or "").rstrip("."))
' 2>/dev/null || true
}

serve_config_json() {
  tailscale_available || return 0
  tailscale serve status --json 2>/dev/null || true
}

# Emits shell-quoted serve_* assignments describing the effective Serve topology.
# Callers use: eval "$(serve_state_vars)"
serve_state_vars() {
  python3 - "$(serve_config_json)" "$(health_serve_port)" "$CONTROL_SERVE_PORT" \
              "$CONTROL_SERVE_TARGET" "$CONTROL_CAPABILITY" <<'PYEOF'
import json, shlex, sys
raw, health_port, control_port, control_target, capability = sys.argv[1:6]
try:
    config = json.loads(raw) if raw.strip() else {}
except ValueError:
    config = {}
if not isinstance(config, dict):
    config = {}
web = config.get("Web")
web = web if isinstance(web, dict) else {}

def entry_for(port):
    # Serve keys are "<magicdns host>:<port>".
    for key, value in web.items():
        if str(key).rsplit(":", 1)[-1] == str(port) and isinstance(value, dict):
            return key, value
    return None, None

def root_proxy(entry):
    handlers = entry.get("Handlers") if isinstance(entry, dict) else None
    root = handlers.get("/") if isinstance(handlers, dict) else None
    return root.get("Proxy") if isinstance(root, dict) else None

health_key, health_entry = entry_for(443)
control_key, control_entry = entry_for(control_port)
health_proxy = root_proxy(health_entry)
control_proxy = root_proxy(control_entry)
expected_health = f"http://127.0.0.1:{health_port}"

if health_entry is None:
    health_state = "missing"
elif health_proxy != expected_health:
    health_state = "wrong-target"
else:
    health_state = "ok"

if control_entry is None:
    control_state = "missing"
elif control_proxy != control_target:
    control_state = "wrong-target"
elif capability not in json.dumps(control_entry):
    # The field name for accepted app capabilities has changed between Tailscale
    # releases, so look for the capability anywhere in this handler's config.
    control_state = "missing-capability"
else:
    control_state = "ok"

other = sorted(k for k in web if k and k not in {health_key, control_key})
for name, value in (("serve_health_key", health_key), ("serve_health_proxy", health_proxy),
                    ("serve_health_state", health_state), ("serve_control_key", control_key),
                    ("serve_control_proxy", control_proxy), ("serve_control_state", control_state),
                    ("serve_other_routes", " ".join(other))):
    print(f"{name}={shlex.quote(str(value or ''))}")
PYEOF
}

control_serve_url() {
  local host
  host="$(magicdns_name)"
  [[ -n "$host" ]] || return 0
  printf 'https://%s:%s' "$host" "$CONTROL_SERVE_PORT"
}

# Idempotent. Only writes the Interstellar health handler.
ensure_health_serve() {
  local port serve_health_key serve_health_proxy serve_health_state
  local serve_control_key serve_control_proxy serve_control_state serve_other_routes
  port="$(health_serve_port)"
  tailscale_available || { warn "Tailscale is not installed; cannot configure the health listener."; return 1; }
  eval "$(serve_state_vars)"
  if [[ "$serve_health_state" == "ok" ]]; then
    ok "Health Serve already proxies http://127.0.0.1:${port}"
    return 0
  fi
  if [[ "$serve_health_state" == "wrong-target" ]]; then
    warn "Health Serve proxies ${serve_health_proxy:-nothing}; repairing."
  else
    info "Adding the health Serve listener."
  fi
  tailscale serve --bg "$port" || { warn "Could not configure the health Serve listener."; return 1; }
  eval "$(serve_state_vars)"
  [[ "$serve_health_state" == "ok" ]] || { warn "Health Serve did not reach the expected state."; return 1; }
  fix "Health Serve configured: https://$(magicdns_name)/ -> http://127.0.0.1:${port}"
}

# Idempotent. Only writes the Interstellar control handler on :8443 and never
# removes unrelated Serve routes.
ensure_control_serve() {
  local serve_health_key serve_health_proxy serve_health_state
  local serve_control_key serve_control_proxy serve_control_state serve_other_routes
  tailscale_available || { warn "Tailscale is not installed; cannot configure the control listener."; return 1; }
  if ! tailscale_control_version_ok; then
    warn "Control Serve requires Tailscale 1.98.9 or newer for both the CLI and the running daemon."
    return 1
  fi
  eval "$(serve_state_vars)"
  case "$serve_control_state" in
    ok) ok "Control Serve already configured on :${CONTROL_SERVE_PORT}."; return 0 ;;
    missing) info "Adding the control Serve listener on :${CONTROL_SERVE_PORT}." ;;
    wrong-target) warn "Control Serve proxies ${serve_control_proxy:-nothing}; repairing." ;;
    missing-capability) warn "Control Serve does not accept ${CONTROL_CAPABILITY}; repairing." ;;
  esac
  tailscale serve --bg --https="$CONTROL_SERVE_PORT" \
    --accept-app-caps="$CONTROL_CAPABILITY" "$CONTROL_SERVE_TARGET" \
    || { warn "Could not configure the control Serve listener."; return 1; }
  # A zero exit status does not prove the effective topology; re-read it.
  eval "$(serve_state_vars)"
  if [[ "$serve_control_state" != "ok" ]]; then
    warn "Control Serve did not reach the expected state (${serve_control_state})."
    return 1
  fi
  fix "Control Serve configured: $(control_serve_url)/ -> ${CONTROL_SERVE_TARGET}"
}

control_installed() { [[ -f "$CONTROL_API_UNIT" && -f "$CONTROL_POLICY" ]]; }

unit_state() { systemctl is-active "$1" 2>/dev/null || echo "inactive"; }

# Reports local service health, Serve configuration and tailnet authorization as
# three separate facts. Never claims control works because systemd is active.
control_show_status() {
  local serve_health_key serve_health_proxy serve_health_state
  local serve_control_key serve_control_proxy serve_control_state serve_other_routes
  local api helper socket url
  echo "Control service"
  if ! control_installed; then
    echo "  Not installed"
    echo
    echo "  Install with: Interstellar API / Agent -> Install / repair / upgrade Control API"
    return
  fi
  api="$(unit_state interstellar-control-api)"
  helper="$(unit_state interstellar-control-helper)"
  if [[ -S "$CONTROL_API_SOCKET" ]]; then socket="available"; else socket="missing"; fi
  eval "$(serve_state_vars)"
  url="$(control_serve_url)"
  printf '  API service:     %s\n' "$api"
  printf '  Helper service:  %s\n' "$helper"
  printf '  API socket:      %s\n' "$socket"
  case "$serve_control_state" in
    ok)
      printf '  Control Serve:   %s/\n' "${url:-configured}"
      printf '  App capability:  accepted by Serve\n'
      printf '  Tailnet Grant:   not verifiable locally / test from Home Assistant\n'
      ;;
    missing)
      printf '  Control Serve:   missing\n'
      printf '  App capability:  not configured\n'
      printf '  Remote control:  unavailable\n'
      ;;
    wrong-target)
      printf '  Control Serve:   wrong target (%s)\n' "${serve_control_proxy:-none}"
      printf '  App capability:  unknown\n'
      printf '  Remote control:  unavailable\n'
      ;;
    missing-capability)
      printf '  Control Serve:   %s/\n' "${url:-configured}"
      printf '  App capability:  MISSING from Serve\n'
      printf '  Remote control:  unavailable (Serve strips it, the API returns 403)\n'
      ;;
  esac
  if [[ "$serve_control_state" != "ok" ]]; then
    echo
    warn "Repair with: Interstellar API / Agent -> Install / repair / upgrade Control API"
  fi
}

# Runs one check as a condition so a failing test never trips `set -e`.
control_check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '[✓] %s\n' "$label"
  else
    printf '[✗] %s\n' "$label"
  fi
}

control_self_check() {
  local serve_health_key serve_health_proxy serve_health_state
  local serve_control_key serve_control_proxy serve_control_state serve_other_routes
  local url client daemon
  client="$(tailscale version 2>/dev/null | head -n 1 || true)"
  daemon="$(tailscale version --daemon --json 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("daemonLong") or "")
except Exception:
    print("")
' 2>/dev/null || true)"
  echo "Control Plane Diagnostics"
  echo
  echo "Local services"
  control_check "tailscaled active" systemctl is-active --quiet tailscaled
  control_check "Tailscale client and daemon >= 1.98.9 (client ${client:-unknown}, daemon ${daemon:-unknown})" \
    tailscale_control_version_ok
  control_check "interstellar-control-helper active" \
    test "$(unit_state interstellar-control-helper)" = active
  control_check "interstellar-control-api active" \
    test "$(unit_state interstellar-control-api)" = active
  control_check "API Unix socket exists" test -S "$CONTROL_API_SOCKET"
  control_check "Helper Unix socket exists" test -S "$CONTROL_HELPER_SOCKET"
  echo
  echo "Serve configuration"
  eval "$(serve_state_vars)"
  control_check "Health Serve configured (${serve_health_proxy:-none})" \
    test "$serve_health_state" = ok
  control_check "Control Serve configured on :${CONTROL_SERVE_PORT} (${serve_control_proxy:-none})" \
    test "${serve_control_proxy:-}" = "$CONTROL_SERVE_TARGET"
  control_check "--accept-app-caps configured" test "$serve_control_state" = ok
  if [[ -n "$serve_other_routes" ]]; then
    printf '[i] Other Serve routes preserved: %s\n' "$serve_other_routes"
  fi
  echo
  echo "Tailnet authorization"
  printf '[?] Tailnet app capability Grant cannot be proven locally\n'
  echo "    Nothing on this host can read the tailnet policy. Home Assistant"
  echo "    receiving HTTP 403 means the Grant is missing even when every check"
  echo "    above passes."
  echo
  url="$(control_serve_url)"
  echo "Control URL:"
  echo "  ${url:-https://<magicdns-name>:${CONTROL_SERVE_PORT}}"
  echo
  echo "Required capability:"
  echo "  ${CONTROL_CAPABILITY}"
}

node_tailscale_tags() {
  tailscale_available || return 0
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
print(",".join((data.get("Self") or {}).get("Tags") or []))
' 2>/dev/null || true
}

# Applies the grant through the Tailscale API, but never silently: the operator
# sees a diff, Tailscale validates the result, and the write carries an If-Match
# so a concurrent admin-console edit aborts instead of being overwritten.
control_configure_grant() {
  tailscale_available || { warn "Tailscale is not installed."; return 1; }
  local tailnet src dst credential client_id host tags confirm
  host="$(magicdns_name)"
  tags="$(node_tailscale_tags)"
  clear
  echo "Configure the tailnet Grant for Home Assistant"
  echo
  echo "This edits your tailnet policy file through the Tailscale API."
  echo "You will see the exact change and must confirm before anything is written."
  echo "Existing rules and comments are preserved."
  echo

  tailnet="$(ui_input "Tailnet" "Tailnet name, or - for the credential's default tailnet:" "-")" || return
  src="$(ui_input "Grant source" "Home Assistant's identity in the policy.\nA tag, user or group, comma-separated:" "tag:home-assistant")" || return
  if [[ -n "$tags" ]]; then
    dst="$(ui_input "Grant destination" "This server matches these tags:\n  ${tags}\n\nDestination for the grant:" "$tags")" || return
  else
    warn "This node has no Tailscale tags; a tag is the usual destination."
    dst="$(ui_input "Grant destination" "This server is ${host:-untagged}.\nDestination for the grant:" "tag:interstellar-server")" || return
  fi
  [[ -n "$src" && -n "$dst" ]] || { warn "A source and destination are required."; return 1; }

  echo
  echo "The credential needs the policy_file scope (read and write)."
  echo "Create one at: Tailscale admin console -> Settings -> Keys."
  echo "It is used once, kept in memory only, and never written to disk."
  echo
  read -r -s -p "API key (tskey-api-...) or OAuth client secret: " credential
  echo
  [[ -n "$credential" ]] || { warn "No credential entered."; return 1; }
  client_id=""
  if [[ "$credential" != tskey-api-* ]]; then
    read -r -p "OAuth client ID (leave empty if the secret contains it): " client_id
  fi

  echo
  info "Reading the current policy and preparing the change..."
  echo
  # Dry run first: shows the diff and runs Tailscale's own validation.
  if ! TS_GRANT_CREDENTIAL="$credential" run_tailnet_grant \
        --tailnet "$tailnet" --client-id "$client_id" \
        --src "$src" --dst "$dst" --port "$CONTROL_SERVE_PORT" \
        --capability "$CONTROL_CAPABILITY" --dry-run; then
    warn "Nothing was changed."
    unset credential
    return 1
  fi

  echo
  echo "Type the tailnet name (${tailnet}) to apply, anything else to cancel."
  read -r -p "> " confirm
  if [[ "$confirm" != "$tailnet" ]]; then
    unset credential
    info "Cancelled; the policy was not changed."
    return 1
  fi

  if TS_GRANT_CREDENTIAL="$credential" run_tailnet_grant \
      --tailnet "$tailnet" --client-id "$client_id" \
      --src "$src" --dst "$dst" --port "$CONTROL_SERVE_PORT" \
      --capability "$CONTROL_CAPABILITY" --confirm "$tailnet"; then
    unset credential
    echo
    fix "Grant applied. Home Assistant should reach $(control_serve_url) now."
    info "In Home Assistant, reload the integration or wait for the next refresh."
  else
    unset credential
    warn "The grant was not applied."
    return 1
  fi
}

control_grant_guidance() {
  local host url
  host="$(magicdns_name)"
  url="$(control_serve_url)"
  echo "Tailscale Grant required for Home Assistant"
  echo
  echo "The control API refuses every request without the app capability:"
  echo "  ${CONTROL_CAPABILITY}"
  echo
  echo "This Toolbox never edits your tailnet policy. Add a Grant like this in"
  echo "the Tailscale admin console (Access controls), with src/dst adjusted to"
  echo "the tags or users you actually use:"
  echo
  cat <<EOF
  {
    "grants": [
      {
        "src": ["tag:home-assistant"],
        "dst": ["tag:interstellar-server"],
        "ip": ["tcp:${CONTROL_SERVE_PORT}"],
        "app": {
          "${CONTROL_CAPABILITY}": [{}]
        }
      }
    ]
  }
EOF
  echo
  echo "Check each part before applying:"
  echo "  src   must match the Home Assistant node's identity (its tag, user or group)."
  echo "  dst   must match this server${host:+ (${host})}."
  echo "  ip    must allow tcp:${CONTROL_SERVE_PORT}; network access alone is not enough."
  echo "  app   grants the capability. Without it Serve strips it and the API returns 403."
  echo
  echo "Do not paste this over an existing policy. Merge it into your current grants."
  echo
  echo "Home Assistant control URL: ${url:-https://<magicdns-name>:${CONTROL_SERVE_PORT}}"
}

write_control_helper_python() {
  install -d -o root -g root -m 0755 "$AGENT_DIR"
  cat >"$CONTROL_HELPER_PY" <<'PYEOF'
#!/usr/bin/env python3
"""Root side of the Interstellar control plane. No shell or command API."""
from __future__ import annotations

import json
import os
import re
import socket
import sqlite3
import struct
import subprocess
import threading
import time
from datetime import datetime, timezone
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID

VERSION = "0.2.1"
SOCKET_PATH = Path("/run/interstellar-control/helper.sock")
DB_PATH = Path("/var/lib/interstellar-control/actions.db")
POLICY_PATH = Path("/etc/interstellar/control-policy.json")
CONTROL_UID = None
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$")
OPERATIONS = {
    "reboot", "shutdown", "update_refresh", "update_security", "update_all",
    "service_start", "service_stop", "service_restart",
    "container_start", "container_stop", "container_restart",
    "restart_health_agent", "restart_control_agent", "restart_mdns",
    "restart_docker", "restart_tailscaled",
}
LOCK = threading.Lock()
EXECUTION_LOCK = threading.Lock()
SLOTS = threading.BoundedSemaphore(16)


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def current_boot_time() -> datetime | None:
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("btime "):
            return datetime.fromtimestamp(int(line.split()[1]), timezone.utc)
    return None


def machine_id() -> str:
    return Path("/etc/machine-id").read_text().strip()


@contextmanager
def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def initialize() -> None:
    DB_PATH.parent.mkdir(mode=0o2750, parents=True, exist_ok=True)
    os.chmod(DB_PATH.parent, 0o2750)
    with db() as conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(actions)")}
        if columns and "action" not in columns:
            conn.execute("ALTER TABLE actions RENAME TO actions_legacy")
        conn.execute("""CREATE TABLE IF NOT EXISTS actions (
            action_id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, action TEXT NOT NULL,
            target TEXT NOT NULL, identity TEXT NOT NULL, status TEXT NOT NULL,
            timestamp TEXT NOT NULL, started_at TEXT, action_started_at TEXT,
            dispatched_at TEXT, finished_at TEXT, reboot_duration_seconds INTEGER,
            result TEXT, error TEXT, boot_id_before TEXT)""")
        for column, sql_type in (("action_started_at", "TEXT"), ("dispatched_at", "TEXT"),
                                 ("reboot_duration_seconds", "INTEGER")):
            if column not in {row[1] for row in conn.execute("PRAGMA table_info(actions)")}:
                conn.execute(f"ALTER TABLE actions ADD COLUMN {column} {sql_type}")
        conn.execute("CREATE INDEX IF NOT EXISTS actions_timestamp ON actions(timestamp DESC)")
        previous = conn.execute("""SELECT action_id, boot_id_before, action, status,
                                         started_at, action_started_at, dispatched_at FROM actions
                                  WHERE status IN ('running','dispatched') AND action IN ('reboot','shutdown')""").fetchall()
        conn.execute("""UPDATE actions SET status='failed', finished_at=?, error='Interrupted by helper restart'
                        WHERE status IN ('queued','running') AND action NOT IN ('reboot','shutdown')""", (utcnow(),))
        conn.execute("""UPDATE actions SET status='failed', finished_at=?, error='Interrupted before dispatch'
                        WHERE status='queued' AND action IN ('reboot','shutdown')""", (utcnow(),))
        for row in previous:
            if row["status"] == "running":
                if row["action_started_at"]:
                    conn.execute("""UPDATE actions SET status='failed', finished_at=?,
                                  error='Interrupted before dispatch' WHERE action_id=?""",
                                 (utcnow(), row["action_id"]))
                    continue
                # Upgrade v0.1 in-flight power actions without claiming success.
                conn.execute("UPDATE actions SET status='dispatched', dispatched_at=COALESCE(dispatched_at, started_at) WHERE action_id=?",
                             (row["action_id"],))
            if row["action"] == "reboot" and row["boot_id_before"] != boot_id():
                start = row["dispatched_at"] or row["action_started_at"] or row["started_at"]
                boot_time = current_boot_time()
                try:
                    duration = max(0, int((boot_time - datetime.fromisoformat(start)).total_seconds())) if boot_time and start else None
                except ValueError:
                    duration = None
                conn.execute("""UPDATE actions SET status='successful', finished_at=?,
                              reboot_duration_seconds=?, result='New boot observed', error=NULL WHERE action_id=?""",
                             (utcnow(), duration, row["action_id"]))
        conn.execute("""DELETE FROM actions WHERE action_id NOT IN
                        (SELECT action_id FROM actions ORDER BY timestamp DESC LIMIT 100)""")
    os.chmod(DB_PATH, 0o640)


def policy() -> dict:
    data = json.loads(POLICY_PATH.read_text())
    if not isinstance(data, dict):
        raise ValueError("Invalid server policy")
    for key in ("expected_services", "manageable_services", "expected_containers", "manageable_containers"):
        if not isinstance(data.get(key), list) or any(not isinstance(x, str) or not NAME.fullmatch(x) for x in data[key]):
            raise ValueError("Invalid server policy")
    return data


def validate(action: str, target: str, confirmation: str = "") -> None:
    if action not in OPERATIONS or not isinstance(target, str):
        raise ValueError("Unsupported action")
    if action.startswith("service_") or action.startswith("container_"):
        if not NAME.fullmatch(target):
            raise ValueError("Invalid target")
        allowed_key = "manageable_services" if action.startswith("service_") else "manageable_containers"
        if target not in policy()[allowed_key]:
            raise ValueError("Target is not manageable")
        if action.startswith("service_") and target in {"ssh", "sshd", "tailscaled"}:
            if target not in policy().get("sensitive_services_opt_in", []):
                raise ValueError("Sensitive service requires explicit server opt-in")
    elif target:
        raise ValueError("Action does not accept a target")
    if action in {"reboot", "shutdown"} and confirmation != socket.gethostname():
        raise ValueError("Power action requires exact hostname confirmation")
    if action == "restart_tailscaled" and "tailscaled" not in policy().get("sensitive_services_opt_in", []):
        raise ValueError("Tailscale restart requires explicit server opt-in")
    if action == "restart_docker" and "docker" not in policy()["manageable_services"]:
        raise ValueError("Docker daemon is not manageable")


def record(action_id: str, action: str, target: str, identity: str, status: str, error: str | None = None) -> None:
    with LOCK, db() as conn:
        conn.execute("""INSERT INTO actions(action_id,machine_id,action,target,identity,status,timestamp,error,boot_id_before)
                        VALUES(?,?,?,?,?,?,?,?,?)""",
                     (action_id, machine_id(), action, target, identity, status, utcnow(), error, boot_id()))
        conn.execute("""DELETE FROM actions WHERE action_id NOT IN
                        (SELECT action_id FROM actions ORDER BY timestamp DESC LIMIT 100)""")


def transition(action_id: str, status: str, result: str | None = None, error: str | None = None) -> None:
    if status not in {"running", "dispatched", "successful", "failed"}:
        raise ValueError("Invalid action state")
    now = utcnow()
    with LOCK, db() as conn:
        conn.execute("""UPDATE actions SET status=?,
                        started_at=CASE WHEN ?='running' THEN COALESCE(started_at,?) ELSE started_at END,
                        action_started_at=CASE WHEN ?='running' THEN COALESCE(action_started_at,?) ELSE action_started_at END,
                        dispatched_at=CASE WHEN ?='dispatched' THEN COALESCE(dispatched_at,?) ELSE dispatched_at END,
                        finished_at=CASE WHEN ? IN ('successful','failed') THEN ? ELSE finished_at END,
                        result=?, error=? WHERE action_id=?""",
                     (status, status, now, status, now, status, now, status, now, result, error, action_id))


def docker_target(target: str) -> str:
    proc = subprocess.run(["/usr/bin/docker", "container", "inspect", "--format", "{{.Id}}", target],
                          capture_output=True, text=True, timeout=15, check=False)
    if proc.returncode or not re.fullmatch(r"[0-9a-f]{64}", proc.stdout.strip()):
        raise RuntimeError("Container is unavailable")
    return proc.stdout.strip()


def security_update_configuration_is_safe() -> bool:
    """Fail closed unless unattended-upgrades is security-only and never reboots."""
    proc = subprocess.run(["/usr/bin/apt-config", "dump"], capture_output=True, text=True, timeout=10, check=False)
    if proc.returncode:
        return False
    origins = []
    reboot = False
    for line in proc.stdout.splitlines():
        key, _, value = line.partition(" ")
        value = value.strip().strip(";\"").lower()
        if key.startswith(("Unattended-Upgrade::Allowed-Origins::", "Unattended-Upgrade::Origins-Pattern::")):
            origins.append(value)
        if key == "Unattended-Upgrade::Automatic-Reboot":
            reboot = value in {"true", "1", "yes"}
    return bool(origins) and all("security" in origin for origin in origins) and not reboot


def perform(action: str, target: str) -> str:
    # Every branch constructs its own fixed argv. Target values have passed policy validation.
    if action == "reboot":
        proc = subprocess.run(["/usr/bin/systemctl", "reboot"], capture_output=True, timeout=10, check=False)
    elif action == "shutdown":
        proc = subprocess.run(["/usr/bin/systemctl", "poweroff"], capture_output=True, timeout=10, check=False)
    elif action == "update_refresh":
        proc = subprocess.run(["/usr/bin/apt-get", "update"], capture_output=True, timeout=900, check=False)
    elif action == "update_security":
        if not Path("/usr/bin/unattended-upgrade").exists():
            raise RuntimeError("unattended-upgrades is not installed")
        if not security_update_configuration_is_safe():
            raise RuntimeError("Configure unattended-upgrades for security origins only and disable automatic reboot")
        proc = subprocess.run(["/usr/bin/unattended-upgrade"], capture_output=True, timeout=3600, check=False)
    elif action == "update_all":
        proc = subprocess.run(["/usr/bin/apt-get", "-y", "upgrade"], capture_output=True, timeout=3600, check=False,
                              env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "DEBIAN_FRONTEND": "noninteractive", "LC_ALL": "C"})
    elif action == "service_start":
        proc = subprocess.run(["/usr/bin/systemctl", "start", "--", target], capture_output=True, timeout=120, check=False)
    elif action == "service_stop":
        proc = subprocess.run(["/usr/bin/systemctl", "stop", "--", target], capture_output=True, timeout=120, check=False)
    elif action == "service_restart":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "--", target], capture_output=True, timeout=120, check=False)
    elif action == "container_start":
        proc = subprocess.run(["/usr/bin/docker", "container", "start", docker_target(target)], capture_output=True, timeout=120, check=False)
    elif action == "container_stop":
        proc = subprocess.run(["/usr/bin/docker", "container", "stop", docker_target(target)], capture_output=True, timeout=120, check=False)
    elif action == "container_restart":
        proc = subprocess.run(["/usr/bin/docker", "container", "restart", docker_target(target)], capture_output=True, timeout=120, check=False)
    elif action == "restart_health_agent":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "interstellar-agent.service"], capture_output=True, timeout=120, check=False)
    elif action == "restart_control_agent":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "interstellar-control-api.service"], capture_output=True, timeout=120, check=False)
    elif action == "restart_mdns":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "interstellar-mdns.service"], capture_output=True, timeout=120, check=False)
    elif action == "restart_docker":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "docker.service"], capture_output=True, timeout=180, check=False)
    elif action == "restart_tailscaled":
        proc = subprocess.run(["/usr/bin/systemctl", "restart", "tailscaled.service"], capture_output=True, timeout=180, check=False)
    else:
        raise ValueError("Unsupported action")
    if proc.returncode:
        raise RuntimeError(f"Action exited with status {proc.returncode}")
    return "Action completed"


def worker(action_id: str, action: str, target: str) -> None:
    try:
        with EXECUTION_LOCK:
            transition(action_id, "running")
            if action in {"reboot", "shutdown", "restart_control_agent"}:
                time.sleep(1)
                transition(action_id, "dispatched", result="Action dispatched")
            try:
                result = perform(action, target)
            except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as err:
                transition(action_id, "failed", error=str(err)[:180])
            else:
                if action not in {"reboot", "shutdown"}:
                    transition(action_id, "successful", result=result)
                # Reboot is reconciled against a new boot ID; shutdown stays dispatched.
    finally:
        SLOTS.release()


def dispatch(request: dict, peer_uid: int) -> dict:
    if peer_uid != CONTROL_UID:
        return {"error": "Unauthorized socket peer"}
    action_id, action, target, identity = (request.get(k) for k in ("action_id", "action", "target", "identity"))
    confirmation = request.get("confirmation", "")
    try:
        UUID(action_id)
        if not isinstance(identity, str) or not 1 <= len(identity) <= 200 or any(ord(c) < 32 for c in identity):
            raise ValueError("Invalid identity")
        validate(action, target, confirmation)
    except (TypeError, ValueError) as err:
        if isinstance(action_id, str) and isinstance(action, str) and isinstance(target, str) and isinstance(identity, str):
            try:
                UUID(action_id)
                record(action_id, action[:80], target[:128], identity[:200], "failed", str(err))
            except (ValueError, sqlite3.IntegrityError):
                pass
        return {"error": str(err)}
    if not SLOTS.acquire(blocking=False):
        record(action_id, action, target, identity, "failed", "Action queue is full")
        return {"error": "Action queue is full"}
    try:
        record(action_id, action, target, identity, "queued")
    except sqlite3.IntegrityError:
        SLOTS.release()
        return {"error": "Duplicate action ID"}
    except sqlite3.Error:
        SLOTS.release()
        return {"error": "Audit unavailable"}
    threading.Thread(target=worker, args=(action_id, action, target), daemon=True).start()
    return {"action_id": action_id, "status": "queued"}


def snapshot() -> dict:
    result = {"docker": {"installed": Path("/usr/bin/docker").exists(), "daemon_running": False,
                         "containers": [], "images": None, "disk_usage": []},
              "toolbox_version": None, "boot_time_utc": None}
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("btime "):
            result["boot_time_utc"] = datetime.fromtimestamp(int(line.split()[1]), timezone.utc).isoformat()
            break
    toolbox = Path("/usr/local/sbin/interstellar-toolbox")
    if toolbox.exists():
        match = re.search(r'^TOOLBOX_VERSION="([0-9.]+)"$', toolbox.read_text(errors="replace"), re.M)
        if match:
            result["toolbox_version"] = match.group(1)
    if not result["docker"]["installed"]:
        return result
    try:
        info = subprocess.run(["/usr/bin/docker", "info", "--format", "{{json .}}"],
                              capture_output=True, text=True, timeout=10, check=False)
        if info.returncode:
            return result
        parsed = json.loads(info.stdout)
        result["docker"].update({"daemon_running": True, "version": parsed.get("ServerVersion"),
                                 "images": parsed.get("Images"), "total": parsed.get("Containers"),
                                 "running": parsed.get("ContainersRunning"), "stopped": parsed.get("ContainersStopped")})
        containers = subprocess.run(["/usr/bin/docker", "ps", "-a", "--format", "{{json .}}"],
                                    capture_output=True, text=True, timeout=10, check=False)
        if containers.returncode == 0:
            for line in containers.stdout.splitlines()[:100]:
                item = json.loads(line)
                identifier = item.get("ID", "")
                if not re.fullmatch(r"[0-9a-f]{12,64}", identifier):
                    continue
                detail = subprocess.run(["/usr/bin/docker", "container", "inspect", "--format", "{{json .}}", identifier],
                                        capture_output=True, text=True, timeout=10, check=False)
                if detail.returncode:
                    continue
                data = json.loads(detail.stdout)
                state = data.get("State") or {}
                labels = (data.get("Config") or {}).get("Labels") or {}
                result["docker"]["containers"].append({
                    "id": data.get("Id"), "name": str(data.get("Name", "")).lstrip("/"),
                    "image": (data.get("Config") or {}).get("Image"),
                    "state": state.get("Status"), "health": (state.get("Health") or {}).get("Status"),
                    "started_at": state.get("StartedAt"), "restart_count": data.get("RestartCount"),
                    "ports": item.get("Ports"), "project": labels.get("com.docker.compose.project"),
                })
        usage = subprocess.run(["/usr/bin/docker", "system", "df", "--format", "{{json .}}"],
                               capture_output=True, text=True, timeout=10, check=False)
        if usage.returncode == 0:
            result["docker"]["disk_usage"] = [json.loads(line) for line in usage.stdout.splitlines()[:10]]
        compose = subprocess.run(["/usr/bin/docker", "compose", "version", "--short"],
                                 capture_output=True, text=True, timeout=5, check=False)
        if compose.returncode == 0:
            result["docker"]["compose_version"] = compose.stdout.strip()[:60]
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return result


def main() -> None:
    global CONTROL_UID
    import pwd
    import grp
    CONTROL_UID = pwd.getpwnam("interstellar-control").pw_uid
    gid = grp.getgrnam("interstellar-control").gr_gid
    initialize()
    os.chown(DB_PATH, 0, gid)
    SOCKET_PATH.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCKET_PATH))
    os.chown(SOCKET_PATH, 0, gid)
    os.chmod(SOCKET_PATH, 0o660)
    server.listen(16)
    while True:
        conn, _ = server.accept()
        with conn:
            conn.settimeout(5)
            _, uid, _ = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            try:
                raw = conn.recv(4097)
                if len(raw) > 4096:
                    raise ValueError("Request too large")
                request = json.loads(raw)
                if not isinstance(request, dict):
                    raise ValueError("Invalid request")
                if request.get("query") == "state" and uid == CONTROL_UID:
                    response = snapshot()
                else:
                    response = dispatch(request, uid)
            except (ValueError, OSError, sqlite3.Error) as err:
                response = {"error": str(err)}
            conn.sendall(json.dumps(response).encode())


if __name__ == "__main__":
    main()
PYEOF
  chown root:root "$CONTROL_HELPER_PY"
  chmod 0755 "$CONTROL_HELPER_PY"
}

write_control_api_python() {
  cat >"$CONTROL_API_PY" <<'PYEOF'
#!/usr/bin/env python3
"""Unprivileged, loopback-only HTTP facade for allowlisted control actions."""
from __future__ import annotations

import json
from contextlib import closing
import os
import re
import socket
import sqlite3
import subprocess
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingUnixStreamServer
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

VERSION = "0.2.1"
TAILSCALE_CONTROL_MINIMUM_VERSION = "1.98.9"
CAPABILITY = "interstellarnetwork.nl/cap/server-control"
API_SOCKET = Path("/run/interstellar-control-api/api.sock")
SOCKET_PATH = "/run/interstellar-control/helper.sock"
DB_PATH = "/var/lib/interstellar-control/actions.db"
POLICY_PATH = Path("/etc/interstellar/control-policy.json")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$")
ACTION_PATHS = {
    "/actions/reboot": ("reboot", None),
    "/actions/shutdown": ("shutdown", None),
    "/actions/update/refresh": ("update_refresh", None),
    "/actions/interstellar/restart-health-agent": ("restart_health_agent", None),
    "/actions/interstellar/restart-control-agent": ("restart_control_agent", None),
    "/actions/interstellar/restart-mdns": ("restart_mdns", None),
    "/actions/docker/restart-daemon": ("restart_docker", None),
    "/actions/tailscale/restart": ("restart_tailscaled", None),
}


def version_supported(raw: str, daemon: bool = False) -> bool:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", raw)
    if not match:
        return False
    version = tuple(int(match.group(i)) for i in (1, 2, 3))
    suffix = match.group(4)
    # Tailscale daemonLong has release commit hashes after the numeric version.
    release_hashes = bool(daemon and suffix and re.fullmatch(r"[tg]?[0-9a-f]{6,}(?:-[tg]?[0-9a-f]{6,})?", suffix))
    return version > (1, 98, 9) or version == (1, 98, 9) and (not suffix or release_hashes)


def tailscale_control_status() -> dict:
    """Fail closed unless both the CLI and running Serve daemon are patched."""
    try:
        proc = subprocess.run(["/usr/bin/tailscale", "version", "--daemon", "--json"], capture_output=True,
                              text=True, timeout=5, check=False)
        payload = json.loads(proc.stdout) if proc.returncode == 0 else {}
    except (OSError, subprocess.TimeoutExpired, ValueError):
        payload = {}
    client = payload.get("short") if isinstance(payload, dict) else None
    daemon = payload.get("daemonLong") if isinstance(payload, dict) else None
    client = client if isinstance(client, str) else None
    daemon = daemon if isinstance(daemon, str) else None
    available = bool(client and daemon and version_supported(client) and version_supported(daemon, daemon=True))
    return {"control_available": available,
            "control_unavailable_reason": None if available else "Tailscale CLI and running daemon must both be 1.98.9 or newer",
            "tailscale_version": client,
            "tailscale_daemon_version": daemon,
            "tailscale_control_minimum_version": TAILSCALE_CONTROL_MINIMUM_VERSION}
for kind in ("service", "container"):
    for operation in ("start", "stop", "restart"):
        segment = "docker" if kind == "container" else kind
        ACTION_PATHS[f"/actions/{segment}/{operation}"] = (f"{kind}_{operation}", kind)


def identity(headers) -> str | None:
    try:
        caps = json.loads(headers.get("Tailscale-App-Capabilities", ""))
    except (ValueError, TypeError):
        return None
    if not isinstance(caps, dict) or not isinstance(caps.get(CAPABILITY), list) or not caps[CAPABILITY]:
        return None
    # Tailscale omits user identity for tagged devices. The grant still authenticates the node.
    value = headers.get("Tailscale-User-Login") or headers.get("Tailscale-User-Name") or "tailscale-tagged-node"
    if len(value) > 200 or any(ord(c) < 32 for c in value):
        return None
    return value


def audit(limit: int = 50, action_id: str | None = None) -> list[dict]:
    try:
        with closing(sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)) as conn:
            conn.row_factory = sqlite3.Row
            if action_id:
                rows = conn.execute("SELECT * FROM actions WHERE action_id=?", (action_id,)).fetchall()
            else:
                rows = conn.execute("SELECT * FROM actions ORDER BY timestamp DESC LIMIT ?", (limit,)).fetchall()
            return [dict(row) for row in rows]
    except sqlite3.Error:
        return []


def current_policy() -> dict:
    data = json.loads(POLICY_PATH.read_text())
    return {key: data.get(key, []) for key in (
        "expected_services", "manageable_services", "expected_containers", "manageable_containers",
        "sensitive_services_opt_in")}


def helper_state() -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(15)
        conn.connect(SOCKET_PATH)
        conn.sendall(b'{"query":"state"}')
        return json.loads(conn.recv(262144))


def send_action(action: str, target: str, principal: str, confirmation: str = "") -> dict:
    request = {"action_id": str(uuid4()), "action": action, "target": target,
               "identity": principal, "confirmation": confirmation}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(5)
        conn.connect(SOCKET_PATH)
        conn.sendall(json.dumps(request).encode())
        result = json.loads(conn.recv(4096))
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = f"InterstellarControl/{VERSION}"
    sys_version = ""

    def version_string(self) -> str:
        # The default appends the Python runtime version, and joining with an
        # empty sys_version would leave a trailing space in the header.
        return self.server_version

    def log_message(self, fmt: str, *args) -> None:
        # Action audit is structured; avoid request lines that may contain secrets.
        pass

    def reply(self, status: int, data: dict) -> None:
        body = json.dumps(data, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path != "/" and identity(self.headers) is None:
            self.reply(403, {"error": "Tailscale control capability required"})
            return
        if path == "/":
            self.reply(200, {"name": "Interstellar control", "version": VERSION, "authenticated": identity(self.headers) is not None})
        elif path == "/state":
            try:
                state = {"version": VERSION, "policy": current_policy(), **helper_state()}
                state.update(tailscale_control_status())
                previous = next((a for a in audit(100) if a.get("action") == "reboot"), None)
                state["last_reboot_action"] = previous
                if previous and previous.get("reboot_duration_seconds") is not None:
                    state["last_reboot_duration_seconds"] = previous["reboot_duration_seconds"]
                self.reply(200, state)
            except (OSError, ValueError):
                self.reply(503, {"error": "Control state unavailable"})
        elif path == "/actions":
            self.reply(200, {"actions": audit()})
        elif re.fullmatch(r"/actions/[0-9a-fA-F-]{36}", path):
            rows = audit(action_id=path.split("/")[-1])
            self.reply(200 if rows else 404, rows[0] if rows else {"error": "Action not found"})
        else:
            self.reply(404, {"error": "Not found"})

    def do_POST(self) -> None:
        principal = identity(self.headers)
        if principal is None:
            self.reply(403, {"error": "Tailscale control capability required"})
            return
        version_status = tailscale_control_status()
        if not version_status["control_available"]:
            self.reply(503, {"error": version_status["control_unavailable_reason"], **version_status})
            return
        path = urlsplit(self.path).path
        length = self.headers.get("Content-Length", "0")
        if not length.isdecimal() or int(length) > 1024:
            self.reply(413, {"error": "Invalid body length"})
            return
        try:
            body = json.loads(self.rfile.read(int(length))) if int(length) else {}
        except (ValueError, UnicodeDecodeError):
            self.reply(400, {"error": "Invalid JSON"})
            return
        if not isinstance(body, dict):
            self.reply(400, {"error": "Expected object"})
            return
        if path == "/actions/update/install":
            if set(body) != {"type"} or body["type"] not in ("security", "all"):
                self.reply(400, {"error": "Update type must be security or all"})
                return
            action, target = "update_" + body["type"], ""
        else:
            route = ACTION_PATHS.get(path)
            if route is None:
                self.reply(404, {"error": "Unknown action"})
                return
            action, kind = route
            key = "service" if kind == "service" else "container" if kind == "container" else None
            if key:
                if set(body) != {key} or not isinstance(body[key], str) or not NAME.fullmatch(body[key]):
                    self.reply(400, {"error": "Invalid target"})
                    return
                target = body[key]
            elif action in {"reboot", "shutdown"}:
                if set(body) != {"confirm_hostname"} or not isinstance(body["confirm_hostname"], str):
                    self.reply(400, {"error": "Exact hostname confirmation required"})
                    return
                target = ""
            elif body:
                self.reply(400, {"error": "Action does not accept arguments"})
                return
            else:
                target = ""
        try:
            result = send_action(action, target, principal, body.get("confirm_hostname", ""))
        except (OSError, ValueError, socket.timeout):
            self.reply(503, {"error": "Control helper unavailable"})
            return
        self.reply(202 if "action_id" in result else 403, result)


if __name__ == "__main__":
    if API_SOCKET.exists():
        API_SOCKET.unlink()
    server = ThreadingUnixStreamServer(str(API_SOCKET), Handler)
    os.chmod(API_SOCKET, 0o600)
    server.serve_forever()
PYEOF
  chown root:root "$CONTROL_API_PY"
  chmod 0755 "$CONTROL_API_PY"
}

write_control_helper_unit() {
  cat >"$CONTROL_HELPER_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Privileged Control Helper
After=local-fs.target

[Service]
Type=simple
User=root
Group=root
RuntimeDirectory=interstellar-control
RuntimeDirectoryMode=0755
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/control-helper.py
Restart=on-failure
RestartSec=3
PrivateTmp=yes
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$CONTROL_HELPER_UNIT"
  chmod 0644 "$CONTROL_HELPER_UNIT"
}

write_control_api_unit() {
  cat >"$CONTROL_API_UNIT" <<'EOF'
[Unit]
Description=Interstellar Network Unprivileged Control API
After=network-online.target interstellar-control-helper.service
Requires=interstellar-control-helper.service

[Service]
Type=simple
User=interstellar-control
Group=interstellar-control
RuntimeDirectory=interstellar-control-api
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/python3 /usr/local/lib/interstellar/control-api.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/run/interstellar-control-api
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
RestrictAddressFamilies=AF_UNIX
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$CONTROL_API_UNIT"
  chmod 0644 "$CONTROL_API_UNIT"
}

write_control_policy() {
  local expected="$1" manageable="$2" expected_containers="$3" manageable_containers="$4"
  install -d -o root -g root -m 0755 /etc/interstellar
  python3 - "$CONTROL_POLICY" "$expected" "$manageable" "$expected_containers" "$manageable_containers" <<'PYEOF'
import json, re, sys
from pathlib import Path
name = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$")
keys = ("expected_services", "manageable_services", "expected_containers", "manageable_containers")
policy = {}
for key, raw in zip(keys, sys.argv[2:]):
    values = list(dict.fromkeys(x.strip() for x in raw.split(",") if x.strip()))
    if any(not name.fullmatch(x) for x in values):
        raise SystemExit(f"Invalid {key} target")
    policy[key] = values
policy["sensitive_services_opt_in"] = []
Path(sys.argv[1]).write_text(json.dumps(policy, indent=2) + "\n")
PYEOF
  chown root:root "$CONTROL_POLICY"
  chmod 0644 "$CONTROL_POLICY"
}

install_control_plane() {
  if ! tailscale_control_version_supported; then
    warn "Control installation requires Tailscale 1.98.9 or newer. Health monitoring remains available."
    return 1
  fi
  install_pkg python3
  if ! getent group interstellar-control >/dev/null; then
    groupadd --system interstellar-control
  fi
  if ! getent passwd interstellar-control >/dev/null; then
    useradd --system --gid interstellar-control --shell /usr/sbin/nologin --home-dir /nonexistent interstellar-control
  else
    usermod --gid interstellar-control interstellar-control
  fi
  install -d -o root -g interstellar-control -m 2750 /var/lib/interstellar-control
  local expected manageable expected_containers manageable_containers
  expected="$(agent_env_value INTERSTELLAR_EXPECTED_SERVICES 2>/dev/null || echo ssh,tailscaled)"
  manageable="$(ui_input "Manageable services" "Comma-separated systemd units HA may control. SSH and Tailscale require extra server-side opt-in." "docker")" || return
  expected_containers="$(ui_input "Expected containers" "Comma-separated Docker container names that should run:" "")" || return
  manageable_containers="$(ui_input "Manageable containers" "Comma-separated Docker container names HA may control:" "")" || return
  write_control_policy "$expected" "$manageable" "$expected_containers" "$manageable_containers"
  write_control_helper_python
  write_control_api_python
  write_control_helper_unit
  write_control_api_unit
  systemctl daemon-reload
  systemctl enable interstellar-control-helper interstellar-control-api
  systemctl restart interstellar-control-helper
  systemctl restart interstellar-control-api
  fix "Interstellar control plane v0.2.1 installed."
  # Running services are useless without the Serve listener, so configure it here
  # instead of printing instructions and hoping the operator runs them.
  ensure_health_serve || true
  ensure_control_serve || warn "Control Serve is not configured; Home Assistant cannot reach the control API."
  echo
  control_grant_guidance
}

upgrade_control_plane_noninteractive() {
  [[ -f "$CONTROL_POLICY" && -f "$CONTROL_API_UNIT" ]] || return 0
  if ! tailscale_control_version_supported; then
    warn "Control upgrade paused until Tailscale is 1.98.9 or newer."
    return 1
  fi
  write_control_helper_python
  write_control_api_python
  write_control_helper_unit
  write_control_api_unit
  systemctl daemon-reload
  systemctl restart interstellar-control-helper
  systemctl restart interstellar-control-api
  # Repairs a health-only or partially configured Serve topology on upgrade.
  ensure_control_serve || true
}

# The grant tool runs from stdin so no credential ever reaches a file or argv.
run_tailnet_grant() {
  python3 - "$@" <<'PYEOF'
#!/usr/bin/env python3
"""Add the Interstellar control grant to a tailnet policy file.

The tailnet policy file is HuJSON: JSON with comments and trailing commas.
Parsing it and writing JSON back would silently delete every comment the
operator wrote, so the grant is inserted textually and the rest of the file is
left byte for byte identical.

Nothing here writes without an explicit confirmation from the caller, the API's
own validation passing first, and an If-Match precondition so a concurrent edit
in the admin console aborts the write instead of being overwritten.

Standard library only; this runs on the node with no extra packages.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("TS_GRANT_API") or "https://api.tailscale.com"
# Passed by environment, never argv: /proc/<pid>/cmdline is world readable while
# /proc/<pid>/environ is not.
CREDENTIAL_ENV = "TS_GRANT_CREDENTIAL"
CODE, STRING, COMMENT = "code", "string", "comment"


# --------------------------------------------------------------------------
# HuJSON handling
# --------------------------------------------------------------------------

def scan(text: str):
    """Classify every character as code, string or comment.

    Needed because a `//` inside a string is not a comment and a `{` inside a
    comment is not structure. Everything else here depends on getting that right.
    """
    kinds = [CODE] * len(text)
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            kinds[i] = STRING
            i += 1
            while i < n:
                kinds[i] = STRING
                if text[i] == "\\":
                    if i + 1 < n:
                        kinds[i + 1] = STRING
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                kinds[i] = COMMENT
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            kinds[i] = kinds[i + 1] = COMMENT
            i += 2
            while i < n:
                kinds[i] = COMMENT
                if text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    kinds[i + 1] = COMMENT
                    i += 2
                    break
                i += 1
            continue
        i += 1
    return kinds


def to_json(text: str) -> str:
    """Strip HuJSON comments and trailing commas so json.loads can read it."""
    kinds = scan(text)
    kept = []
    for i, ch in enumerate(text):
        if kinds[i] == COMMENT:
            # Keep newlines so error line numbers stay meaningful.
            kept.append("\n" if ch == "\n" else " ")
        else:
            kept.append(ch)
    stripped = "".join(kept)
    kinds = scan(stripped)
    out = list(stripped)
    for i, ch in enumerate(stripped):
        if ch != "," or kinds[i] != CODE:
            continue
        j = i + 1
        while j < len(stripped) and (stripped[j].isspace() or kinds[j] == COMMENT):
            j += 1
        if j < len(stripped) and stripped[j] in "]}" and kinds[j] == CODE:
            out[i] = " "
    return "".join(out)


def parse(text: str) -> dict:
    return json.loads(to_json(text))


def find_top_level_array(text: str, key: str) -> int | None:
    """Return the index just after the `[` of a top-level array, or None.

    Only depth-1 keys count, so a nested "grants" inside another object or
    inside "tests" is never mistaken for the real one.
    """
    kinds = scan(text)
    depth = 0
    i, n = 0, len(text)
    target = f'"{key}"'
    while i < n:
        if kinds[i] == COMMENT:
            i += 1
            continue
        ch = text[i]
        if kinds[i] == CODE and ch in "{[":
            depth += 1
            i += 1
            continue
        if kinds[i] == CODE and ch in "}]":
            depth -= 1
            i += 1
            continue
        if depth == 1 and kinds[i] == STRING and text.startswith(target, i):
            j = i + len(target)
            while j < n and (text[j].isspace() or kinds[j] == COMMENT):
                j += 1
            if j < n and text[j] == ":":
                j += 1
                while j < n and (text[j].isspace() or kinds[j] == COMMENT):
                    j += 1
                if j < n and text[j] == "[":
                    return j + 1
                return None
            i = j
            continue
        i += 1
    return None


def find_object_start(text: str) -> int | None:
    """Index just after the opening `{` of the top-level object."""
    kinds = scan(text)
    for i, ch in enumerate(text):
        if kinds[i] == CODE and ch == "{":
            return i + 1
        if kinds[i] == CODE and not ch.isspace():
            return None
    return None


def line_indent(text: str, index: int) -> str:
    start = text.rfind("\n", 0, index) + 1
    line = text[start:index]
    return line[:len(line) - len(line.lstrip())]


# --------------------------------------------------------------------------
# Grant construction and detection
# --------------------------------------------------------------------------

def build_grant(src: list[str], dst: list[str], port: int, capability: str) -> dict:
    return {"src": src, "dst": dst, "ip": [f"tcp:{port}"], "app": {capability: [{}]}}


def grant_matches(grant: dict, src: list[str], dst: list[str], port: int, capability: str) -> bool:
    """True when this grant already gives src->dst the capability on the port."""
    if not isinstance(grant, dict):
        return False
    app = grant.get("app")
    if not isinstance(app, dict) or capability not in app:
        return False
    have_src = {str(x) for x in grant.get("src", []) if isinstance(x, (str, int))}
    have_dst = {str(x) for x in grant.get("dst", []) if isinstance(x, (str, int))}
    if not set(src) <= have_src or not set(dst) <= have_dst:
        return False
    ports = grant.get("ip")
    if ports is None:
        return True  # no ip restriction means all ports
    allowed = {str(x) for x in ports if isinstance(x, (str, int))}
    return f"tcp:{port}" in allowed or "*" in allowed or f"tcp:*" in allowed


def has_grant(policy: dict, src, dst, port, capability) -> bool:
    grants = policy.get("grants")
    if not isinstance(grants, list):
        return False
    return any(grant_matches(g, src, dst, port, capability) for g in grants)


def render_grant(grant: dict, indent: str) -> str:
    """Render compactly, the way policy files are normally written by hand.

    json.dumps(indent=2) puts every array element on its own line, which looks
    nothing like the surrounding file. No trailing commas inside the object, so
    the result is also valid strict JSON.
    """
    def array(values):
        return "[" + ", ".join(json.dumps(v) for v in values) + "]"

    capability = next(iter(grant["app"]))
    lines = [
        "{",
        f'  "src": {array(grant["src"])},',
        f'  "dst": {array(grant["dst"])},',
        f'  "ip":  {array(grant["ip"])},',
        f'  "app": {{{json.dumps(capability)}: [{{}}]}}',
        "}",
    ]
    return "\n".join(indent + line for line in lines)


def insert_grant(text: str, grant: dict) -> str:
    """Insert the grant into the policy text, preserving everything else.

    Raises ValueError when the insertion point cannot be located confidently,
    so the caller can fall back to printing the snippet instead of guessing.
    """
    note = "// Interstellar Network: Home Assistant control plane."
    position = find_top_level_array(text, "grants")
    if position is not None:
        indent = line_indent(text, position) + "  "
        block = render_grant(grant, indent)
        return f"{text[:position]}\n{indent}{note}\n{block},\n{text[position:].lstrip(chr(10))}"

    if "grants" in parse(text):
        raise ValueError('"grants" exists but is not a plain array literal; edit the policy by hand')

    start = find_object_start(text)
    if start is None:
        raise ValueError("policy file does not start with a JSON object")
    indent = line_indent(text, start) + "  "
    block = render_grant(grant, indent + "  ")
    return (f"{text[:start]}\n{indent}\"grants\": [\n{indent}  {note}\n{block},\n{indent}],"
            f"\n{text[start:].lstrip(chr(10))}")


def diff(before: str, after: str) -> str:
    return "".join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile="current policy", tofile="proposed policy", n=3))


# --------------------------------------------------------------------------
# Tailscale API
# --------------------------------------------------------------------------

class ApiError(Exception):
    pass


def request(method, url, token=None, body=None, content_type=None, etag=None, form=None):
    data = None
    headers = {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = body.encode()
        headers["Content-Type"] = content_type or "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if etag:
        headers["If-Match"] = f'"{etag.strip(chr(34))}"'
    if method == "GET":
        headers["Accept"] = content_type or "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.read().decode(), dict(response.headers)
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace").strip()
        try:
            parsed = json.loads(detail)
            detail = parsed.get("message") or parsed.get("error") or detail
        except ValueError:
            pass
        if err.code == 401:
            raise ApiError("Unauthorized: check the credential") from err
        if err.code == 403:
            raise ApiError("Forbidden: the credential needs the policy_file scope") from err
        if err.code == 412:
            raise ApiError("The policy changed while this ran; nothing was written. Try again.") from err
        raise ApiError(f"HTTP {err.code}: {detail}") from err
    except urllib.error.URLError as err:
        raise ApiError(f"Could not reach the Tailscale API: {err.reason}") from err


def access_token(credential: str, client_id: str = "") -> str:
    """API keys are bearer tokens; OAuth client secrets are exchanged first."""
    if credential.startswith("tskey-api-"):
        return credential
    form = {"client_secret": credential}
    if client_id:
        form["client_id"] = client_id
    body, _ = request("POST", f"{API}/api/v2/oauth/token", form=form)
    token = json.loads(body).get("access_token")
    if not token:
        raise ApiError("The OAuth response contained no access token")
    return token


def get_policy(token: str, tailnet: str) -> tuple[str, str]:
    url = f"{API}/api/v2/tailnet/{urllib.parse.quote(tailnet, safe='')}/acl"
    body, headers = request("GET", url, token=token, content_type="application/hujson")
    return body, headers.get("ETag", "")


def validate_policy(token: str, tailnet: str, text: str) -> None:
    url = f"{API}/api/v2/tailnet/{urllib.parse.quote(tailnet, safe='')}/acl/validate"
    request("POST", url, token=token, body=text, content_type="application/hujson")


def put_policy(token: str, tailnet: str, text: str, etag: str) -> None:
    url = f"{API}/api/v2/tailnet/{urllib.parse.quote(tailnet, safe='')}/acl"
    request("POST", url, token=token, body=text, content_type="application/hujson", etag=etag)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def run(args) -> int:
    src = [x for x in args.src.split(",") if x]
    dst = [x for x in args.dst.split(",") if x]
    if not src or not dst:
        print("A source and destination are required.", file=sys.stderr)
        return 2

    token = access_token(args.credential, args.client_id)
    current, etag = get_policy(token, args.tailnet)

    try:
        policy = parse(current)
    except ValueError as err:
        raise ApiError(f"Could not read the current policy file: {err}") from err

    if has_grant(policy, src, dst, args.port, args.capability):
        print("The tailnet already grants this capability. Nothing to change.")
        return 0

    grant = build_grant(src, dst, args.port, args.capability)
    try:
        proposed = insert_grant(current, grant)
    except ValueError as err:
        print(f"Cannot edit this policy file safely: {err}\n", file=sys.stderr)
        print("Add this grant by hand in the admin console:\n", file=sys.stderr)
        print(json.dumps(grant, indent=2), file=sys.stderr)
        return 3

    print(diff(current, proposed) or "(no textual change)")

    validate_policy(token, args.tailnet, proposed)
    print("\n[✓] Tailscale validated the proposed policy.")

    if args.dry_run:
        print("\nDry run: nothing was written.")
        return 0

    if args.confirm != args.tailnet:
        print("\nNot confirmed; nothing was written.", file=sys.stderr)
        return 4

    put_policy(token, args.tailnet, proposed, etag)

    verify, _ = get_policy(token, args.tailnet)
    if not has_grant(parse(verify), src, dst, args.port, args.capability):
        raise ApiError("The policy was written but the grant is not visible; check the admin console")
    print("[✓] Grant applied and verified.")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tailnet", default="-")
    parser.add_argument("--credential", default="",
                        help=f"prefer the {CREDENTIAL_ENV} environment variable")
    parser.add_argument("--client-id", default="")
    parser.add_argument("--src", required=True, help="comma-separated grant sources")
    parser.add_argument("--dst", required=True, help="comma-separated grant destinations")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--capability", default="interstellarnetwork.nl/cap/server-control")
    parser.add_argument("--confirm", default="", help="must equal --tailnet to write")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    args.credential = os.environ.get(CREDENTIAL_ENV) or args.credential
    if not args.credential:
        print(f"No credential supplied; set {CREDENTIAL_ENV}.", file=sys.stderr)
        return 2
    try:
        return run(args)
    except ApiError as err:
        print(f"{err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF
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
  systemctl enable interstellar-agent
  systemctl restart interstellar-agent
  if [[ -f "$MDNS_ENV" ]]; then
    sed -i 's/^INTERSTELLAR_AGENT_VERSION=.*/INTERSTELLAR_AGENT_VERSION=3.2.1/' "$MDNS_ENV"
    systemctl restart interstellar-mdns 2>/dev/null || true
  fi

  fix "Read-only health agent v3.2.1 installed/upgraded."
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
  tailscale_control_version_supported || true
  echo
  control_show_status
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
  result="$(ui_checklist "Server roles" "Choose one or more roles. Roles are presentation metadata; add Docker explicitly to expected services if needed." \
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

  expected="$(ui_input "Expected services" "Comma-separated systemd service names.\nIf an expected service is not active, Home Assistant will raise a problem.\n\nRoles do not add expected services automatically." "$current_expected")" || return
  expected="$(printf '%s' "$expected" | tr -d ' ' | sed 's/^,*//;s/,*$//')"
  [[ -n "$expected" ]] || expected="ssh,tailscaled"

  write_agent_env "$port" "$roles" "$expected"
  if [[ -f "$CONTROL_POLICY" ]]; then
    python3 - "$CONTROL_POLICY" "$expected" <<'PYEOF'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
policy = json.loads(path.read_text())
policy["expected_services"] = [x for x in sys.argv[2].split(",") if x]
path.write_text(json.dumps(policy, indent=2) + "\n")
PYEOF
  fi
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
INTERSTELLAR_AGENT_VERSION=3.2.1
EOF
  chmod 0644 "$MDNS_ENV"
  systemctl daemon-reload
  systemctl enable interstellar-mdns
  systemctl restart interstellar-mdns
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
  tailscale_available || { warn "Tailscale is not installed."; return; }
  clear
  ensure_health_serve || true
  if [[ -f "$CONTROL_API_UNIT" ]]; then
    ensure_control_serve || true
  fi
  echo
  tailscale serve status || true
}

agent_disable_tailscale_serve() {
  tailscale_available || return
  local port
  port="$(health_serve_port)"
  # `tailscale serve off` would also drop the control listener and any unrelated
  # route this node serves, so only the Interstellar handlers are removed.
  ui_yesno "Disable Interstellar Serve" \
    "Remove the Interstellar health and control Serve listeners?\n\nUnrelated Serve routes are kept." || return
  tailscale serve --https=443 off 2>/dev/null || true
  tailscale serve --https="$CONTROL_SERVE_PORT" off 2>/dev/null || true
  fix "Interstellar Serve listeners removed. Local health port ${port} is unchanged."
  echo
  tailscale serve status || true
}

agent_security_model() {
  ui_msg "Health/control security" "HEALTH: unprivileged GET-only agent on 127.0.0.1:9127.\n\nCONTROL: separate private Unix HTTP socket with Tailscale Serve app capability, root helper, server policy, and audit. Local root and trusted local processes remain inside the host trust boundary."
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
  ui_yesno "Uninstall agents" "Remove the local Interstellar agents?" || return
  systemctl disable --now interstellar-agent 2>/dev/null || true
  systemctl disable --now interstellar-mdns 2>/dev/null || true
  systemctl disable --now interstellar-control-api 2>/dev/null || true
  systemctl disable --now interstellar-control-helper 2>/dev/null || true
  rm -f "$AGENT_UNIT" "$AGENT_ENV" "$AGENT_PY" "$MDNS_UNIT" "$MDNS_ENV" "$MDNS_PY"
  rm -f "$CONTROL_API_UNIT" "$CONTROL_API_PY" "$CONTROL_HELPER_UNIT" "$CONTROL_HELPER_PY" "$CONTROL_POLICY"
  rm -f /var/lib/interstellar-control/actions.db
  rmdir "$AGENT_DIR" 2>/dev/null || true
  systemctl daemon-reload
  fix "Agents uninstalled."
  info "Tailscale Serve is left unchanged; disable it separately if desired."
}

agent_menu() {
  while true; do
    local choice
    choice="$(ui_menu "Interstellar API / Agent" \
"Telemetry, Control plane, policy and Home Assistant discovery." \
      "1" "Show status, policy, ports & Serve URL" \
      "2" "Install / repair / upgrade Health API" \
      "3" "Install / repair / upgrade Control API" \
      "4" "Change Health API port" \
      "5" "Configure server roles & expected services" \
      "6" "Enable Tailscale Serve (health + control)" \
      "7" "Disable Interstellar Tailscale Serve" \
      "8" "Enable Home Assistant auto-discovery" \
      "9" "Disable Home Assistant auto-discovery" \
      "10" "Test /health" \
      "11" "Test /stats" \
      "12" "Test /metrics" \
      "13" "Explain security model" \
      "14" "Restart agents" \
      "15" "Uninstall agents" \
      "16" "Control plane self-check" \
      "17" "Show required Tailscale Grant" \
      "18" "Configure tailnet Grant (Tailscale API)" \
      "0" "Back")" || return
    case "$choice" in
      1) clear; agent_show_status; pause ;;
      2) clear; install_health_agent; pause ;;
      3) clear; if ! tailscale_control_version_supported; then warn "Control requires Tailscale 1.98.9+ for both CLI and daemon."; pause; continue; fi; install_control_plane; pause ;;
      4) agent_configure_binding ;;
      5) agent_configure_roles_services ;;
      6) clear; agent_enable_tailscale_serve; pause ;;
      7) clear; agent_disable_tailscale_serve; pause ;;
      8) clear; agent_enable_discovery; pause ;;
      9) clear; agent_disable_discovery; pause ;;
      10) clear; agent_test_health; pause ;;
      11) clear; agent_test_stats; pause ;;
      12) clear; agent_test_metrics; pause ;;
      13) agent_security_model ;;
      14) systemctl restart interstellar-agent interstellar-control-api interstellar-control-helper; ui_msg "API" "Agents restarted." ;;
      15) clear; agent_uninstall; pause ;;
      16) clear; control_self_check; pause ;;
      17) clear; control_grant_guidance; pause ;;
      18) clear; control_configure_grant || true; pause ;;
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
  echo "  Installed version: ${TOOLBOX_VERSION}"
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

  if dpkg --compare-versions "$latest" gt "$TOOLBOX_VERSION"; then
    warn "Update available: ${TOOLBOX_VERSION} -> ${latest}"
    return 2
  elif dpkg --compare-versions "$latest" eq "$TOOLBOX_VERSION"; then
    ok "Toolbox is up to date."
  else
    info "Installed version ${TOOLBOX_VERSION} is newer than the latest published release ${latest}."
  fi
}

manager_update_latest() {
  local latest tmp asset sums expected actual
  latest="$(manager_latest_release_version)" || {
    ui_msg "Update failed" "Could not determine the latest Interstellar Network release."
    return 1
  }

  if ! dpkg --compare-versions "$latest" gt "$TOOLBOX_VERSION"; then
    ui_msg "Interstellar Network" "Installed: ${TOOLBOX_VERSION}\nLatest: ${latest}\n\nNo newer release is available."
    return 0
  fi

  if ! ui_yesno "Update Interstellar Network" \
"Update the Interstellar Network Toolbox?

Current: ${TOOLBOX_VERSION}
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

  if systemctl list-unit-files interstellar-agent.service >/dev/null 2>&1 ||
     systemctl list-unit-files interstellar-control-api.service >/dev/null 2>&1; then
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
${TOOLBOX_VERSION}

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
          UI_BACKTITLE="Interstellar Network Toolbox v${TOOLBOX_VERSION} | $(hostname)"
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
      "10" "Interstellar API / Agent" \
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
  if [[ -f "$AGENT_UNIT" ]]; then install_health_agent; fi
  upgrade_control_plane_noninteractive
  exit 0
fi

main_menu

#!/usr/bin/env bash
# =============================================================================
#  CLIENT MACHINE SETUP SCRIPT
# =============================================================================
#  Configures a Debian-based machine based on a local config file.
#
#  USAGE (recommended):
#    1. Download this script:
#       curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.sh -o setup.sh
#
#    2. Copy and edit the config:
#       curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.conf.example -o setup.conf
#       nano setup.conf
#
#    3. Run:
#       chmod +x setup.sh && sudo ./setup.sh [--debug]
#
#  OR run directly (config must already exist at ./setup.conf):
#    curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.sh | sudo bash
#    To enable debug output when running directly: `curl ... | sudo bash -s -- --debug`
#
#  CUSTOM CONFIG PATH:
#    sudo ./setup.sh --config /path/to/my.conf [--debug]
#
#  DISCOVER NFS EXPORTS (find the correct remote paths for your NAS):
#    sudo ./setup.sh --discover-nfs <NAS_IP> [--debug]
#
# =============================================================================

VERSION="0.1.6"

# Do NOT use set -e — we handle errors manually to ensure script runs to completion
  TS_STATE=$(tailscale status --json ${SILENT_ERR} | grep -oP '"BackendState":\s*"\K[^"]+')

# =============================================================================
# COLOR & FORMATTING
# =============================================================================
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
DIM=$(tput dim 2>/dev/null || echo "")

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

# Print a styled section header
header() {
  local title="$1"
  local width=60
  local line
  line=$(printf '━%.0s' $(seq 1 $width))
  echo ""
  echo "${BOLD}${BLUE}┏${line}┓${RESET}"
  printf "${BOLD}${BLUE}┃${RESET}  %-58s${BOLD}${BLUE}┃${RESET}\n" "$title"
  echo "${BOLD}${BLUE}┗${line}┛${RESET}"
}

# Print a sub-task line
task() {
  printf "  ${CYAN}▸${RESET} %-48s" "$1"
}

# Print status after task()
ok() {
  echo "${BOLD}${GREEN}✔ OK${RESET}"
}

skip() {
  echo "${YELLOW}⊘ SKIPPED${RESET}"
}

updated() {
  echo "${BOLD}${GREEN}↑ UPDATED${RESET}"
}

installed_new() {
  echo "${BOLD}${GREEN}✚ INSTALLED${RESET}"
}

fail() {
  echo "${BOLD}${RED}✘ FAILED${RESET}"
}

# Print an info line
info() {
  echo "  ${DIM}${CYAN}ℹ${RESET}  ${DIM}$*${RESET}"
}

# Print a warning
warn() {
  echo "  ${YELLOW}⚠${RESET}  ${YELLOW}$*${RESET}"
}

# Print an error
error() {
  echo "  ${RED}✘${RESET}  ${RED}ERROR: $*${RESET}"
}

# Print the final summary table
print_summary() {
  local width=60
  local line
  line=$(printf '─%.0s' $(seq 1 $width))
  echo ""
  echo "${BOLD}${BLUE}┌${line}┐${RESET}"
  printf "${BOLD}${BLUE}│${RESET}  %-58s${BOLD}${BLUE}│${RESET}\n" "SETUP SUMMARY"
  echo "${BOLD}${BLUE}├${line}┤${RESET}"
  printf "${BOLD}${BLUE}│${RESET}  ${GREEN}%-10s${RESET} %-47s${BOLD}${BLUE}│${RESET}\n" "Installed:" "${#INSTALLED_LIST[@]} package(s)"
  printf "${BOLD}${BLUE}│${RESET}  ${CYAN}%-10s${RESET} %-47s${BOLD}${BLUE}│${RESET}\n" "Updated:"   "${#UPDATED_LIST[@]} package(s)"
  printf "${BOLD}${BLUE}│${RESET}  ${BLUE}%-10s${RESET} %-47s${BOLD}${BLUE}│${RESET}\n" "Current:"   "${#CURRENT_LIST[@]} package(s)"
  printf "${BOLD}${BLUE}│${RESET}  ${YELLOW}%-10s${RESET} %-47s${BOLD}${BLUE}│${RESET}\n" "Skipped:"   "${#SKIPPED_LIST[@]} package(s)"
  printf "${BOLD}${BLUE}│${RESET}  ${RED}%-10s${RESET} %-47s${BOLD}${BLUE}│${RESET}\n" "Errors:"    "${#ERROR_LIST[@]} error(s)"
  echo "${BOLD}${BLUE}└${line}┘${RESET}"
  echo ""
}

# =============================================================================
# RESULT TRACKING
# =============================================================================
declare -a INSTALLED_LIST=()
declare -a UPDATED_LIST=()
declare -a CURRENT_LIST=()
declare -a SKIPPED_LIST=()
declare -a ERROR_LIST=()

get_pkg_version() {
  local pkg="$1"
  local ver
  # Try dpkg first (covers apt and .deb installs)
  if [[ "${DEBUG:-false}" == "true" ]]; then
    ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>&1)
  else
    ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
  fi
  [[ -n "$ver" ]] && echo "$ver" && return
  # Special cases for manually installed tools
  case "$pkg" in
    awscli)
      if [[ "${DEBUG:-false}" == "true" ]]; then
        ver=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[^\s]+')
      else
        ver=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[^\s]+' 2>/dev/null)
      fi
      ;;
  esac
  echo "${ver:-unknown}"
}

track_installed()  { INSTALLED_LIST+=("$1 ($(get_pkg_version "$1"))"); }
track_updated()    { UPDATED_LIST+=("$1 ($2 → $(get_pkg_version "$1"))"); }
track_current()    { CURRENT_LIST+=("$1 ($(get_pkg_version "$1"))"); }
track_skipped()    { SKIPPED_LIST+=("$1"); }
track_error()      { ERROR_LIST+=("$1: $2"); }

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
CONFIG_FILE="${SCRIPT_DIR}/setup.conf"

# Debug flag: when true, show command output (do not redirect to /dev/null)
DEBUG=false

run_cmd() {
  local cmd="$*"
  if [[ "${DEBUG:-false}" == "true" ]]; then
    bash -c "$cmd"
  else
    bash -c "$cmd" >/dev/null 2>&1
  fi
}

# Run apt-get while respecting debug mode. Removes quiet flag in debug to show full output.
apt_run() {
  local args=("$@")
  # Build a single command string and run through run_cmd so debug controls output
  local cmd=("apt-get")
  cmd+=("${args[@]}")
  run_cmd "${cmd[*]}"
}

# When not in DEBUG mode, silence stderr/stdout as appropriate.
if [[ "${DEBUG:-false}" == "true" ]]; then
  SILENT_ERR=""
  SILENT_OUT=""
else
  SILENT_ERR="2>/dev/null"
  SILENT_OUT=">/dev/null 2>&1"
fi

discover_nfs() {
  local ip="$1"

  if [[ -z "$ip" ]]; then
    error "No IP address provided."
    echo "  Usage: sudo $0 --discover-nfs <NAS_IP>"
    echo ""
    exit 1
  fi

  echo ""
  echo "${BOLD}${BLUE}  NFS Export Discovery — ${ip}${RESET}"
  echo ""

  # Install showmount if missing
  if ! command -v showmount &>/dev/null; then
    info "showmount not found — installing nfs-common..."
    if [[ $EUID -ne 0 ]]; then
      error "Run with sudo to install nfs-common"
      exit 1
    fi
    apt_run update -qq
    DEBIAN_FRONTEND=noninteractive apt_run install -y -qq nfs-common
  fi

  local exports
  exports=$(showmount -e "$ip" 2>&1)
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    error "Could not reach NFS server at ${ip}"
    echo "  ${DIM}Check that:"
    echo "    • The NAS IP is correct and reachable (ping ${ip})"
    echo "    • NFS exports are enabled on the NAS"
    echo "    • Port 2049/111 (TCP/UDP) are not firewalled${RESET}"
    echo ""
    exit 1
  fi

  # Collect export paths
  local paths=()
  while IFS= read -r line; do
    [[ "$line" =~ ^Export ]] && continue
    local path
    path=$(awk '{print $1}' <<< "$line")
    [[ -z "$path" ]] && continue
    paths+=("$path")
  done <<< "$exports"

  if [[ ${#paths[@]} -eq 0 ]]; then
    warn "No exports found on ${ip}."
    echo ""
    exit 0
  fi

  echo "  ${BOLD}Found ${#paths[@]} export(s) on ${ip}.${RESET}"
  echo "  ${DIM}For each export, choose: [a]ccept  [s]kip${RESET}"
  echo ""

  local accepted_entries=()

  for path in "${paths[@]}"; do
    local suggested_name
    suggested_name=$(basename "$path")
    local suggested_mount="/mnt/${suggested_name}"

    printf "  ${CYAN}▸${RESET} ${BOLD}%s${RESET}\n" "$path"
    printf "    Accept or skip? ${BOLD}[a/s]${RESET} (default: s): "
    local answer
    read -r answer </dev/tty
    answer="${answer:-s}"

    if [[ "$answer" =~ ^[Aa] ]]; then
      printf "    Local mount point ${DIM}(default: %s)${RESET}: " "$suggested_mount"
      local mount_point
      read -r mount_point </dev/tty
      mount_point="${mount_point:-$suggested_mount}"

      printf "    Mount options ${DIM}(default: rw,nfsvers=3)${RESET}: "
      local mount_opts
      read -r mount_opts </dev/tty
      mount_opts="${mount_opts:-rw,nfsvers=3}"

      local entry="${ip}:${path}:${mount_point}:${mount_opts}"
      accepted_entries+=("$entry")
      info "Added: ${entry}"
    else
      info "Skipped: ${path}"
    fi
    echo ""
  done

  if [[ ${#accepted_entries[@]} -eq 0 ]]; then
    warn "No mounts selected. Nothing written to config."
    echo ""
    exit 0
  fi

  echo "  ${BOLD}Selected mounts:${RESET}"
  for entry in "${accepted_entries[@]}"; do
    echo "    ${DIM}\"${entry}\"${RESET}"
  done
  echo ""

  printf "  Write these entries to ${CONFIG_FILE}? ${BOLD}[y/n]${RESET} (default: n): "
  local confirm
  read -r confirm </dev/tty
  echo ""

  if [[ "$confirm" =~ ^[Yy] ]]; then
    # Check if NFS_MOUNTS already exists in config
    if grep -q '^NFS_MOUNTS=(' "$CONFIG_FILE" ${SILENT_ERR}; then
      # Insert new entries before the closing )
      local insert_lines=""
      for entry in "${accepted_entries[@]}"; do
        insert_lines+="  \"${entry}\"\n"
      done
      # Use a temp file to safely edit
      local tmpfile
      tmpfile=$(mktemp)
      awk -v lines="$insert_lines" '
        /^\)/ && found { printf "%s", lines; found=0 }
        /^NFS_MOUNTS=\(/ { found=1 }
        { print }
      ' "$CONFIG_FILE" > "$tmpfile" && mv "$tmpfile" "$CONFIG_FILE"
      info "Entries appended to existing NFS_MOUNTS in ${CONFIG_FILE}"
    else
      # Append a new NFS_MOUNTS block
      {
        echo ""
        echo "NFS_MOUNTS=("
        for entry in "${accepted_entries[@]}"; do
          echo "  \"${entry}\""
        done
        echo ")"
      } >> "$CONFIG_FILE"
      info "NFS_MOUNTS block added to ${CONFIG_FILE}"
    fi

    echo ""
    warn "Remember to set INSTALL_NFS=true in ${CONFIG_FILE} to activate these mounts."
  else
    echo "  ${YELLOW}Not written.${RESET} Add these lines to NFS_MOUNTS in ${CONFIG_FILE} manually:"
    echo ""
    for entry in "${accepted_entries[@]}"; do
      echo "    \"${entry}\""
    done
  fi

  echo ""
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c) CONFIG_FILE="$2"; shift 2 ;;
    --debug) DEBUG=true; shift ;;
    --discover-nfs|-n)
      discover_nfs "${2:-}"
      ;;
    --help|-h)
      echo "Usage: sudo $0 [--config /path/to/setup.conf] [--debug]"
      echo "       sudo $0 --discover-nfs <NAS_IP> [--debug]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

clear
echo ""
echo "${BOLD}${BLUE}  ╔══════════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${BLUE}  ║          CLIENT MACHINE SETUP  •  v${VERSION}                 ║${RESET}"
echo "${BOLD}${BLUE}  ╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Script started at $(date '+%Y-%m-%d %H:%M:%S')"
info "Hostname: $(hostname)"
info "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"


# Must be root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Use: sudo $0"
  exit 1
fi

# Must be Debian-based
if ! command -v apt-get &>/dev/null; then
  error "This script requires a Debian-based OS (apt-get not found)"
  exit 1
fi

# Check config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  error "Config file not found: $CONFIG_FILE"
  echo ""
  info "Create one from the example:"
  info "  curl -fsSL https://raw.githubusercontent.com/lampapps/machine_setup/main/setup.conf.example -o setup.conf"
  exit 1
fi

info "Using config: $CONFIG_FILE"
echo ""

# Source the config file
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# =============================================================================
# HELPER: apt install with error handling
# =============================================================================
apt_install() {
  local pkg="$1"
  DEBIAN_FRONTEND=noninteractive apt_run install -y -qq "$pkg"
}

apt_update_pkg() {
  local pkg="$1"
  DEBIAN_FRONTEND=noninteractive apt_run install -y -qq --only-upgrade "$pkg"
}

is_installed() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    dpkg -l "$1" | grep -q "^ii"
  else
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
  fi
}

# Returns 0 if a newer candidate version is available for the package
is_upgradable() {
  local pkg="$1"
  local installed candidate
  if [[ "${DEBUG:-false}" == "true" ]]; then
    installed=$(apt-cache policy "$pkg" | awk '/Installed:/ {print $2}')
    candidate=$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2}')
  else
    installed=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Installed:/ {print $2}')
    candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
  fi
  [[ -n "$installed" && "$installed" != "(none)" && -n "$candidate" && "$installed" != "$candidate" ]]
}

# =============================================================================
# SYSTEM UPDATE
# =============================================================================
header "SYSTEM UPDATE"

task "Updating package lists"
if apt_run update -qq; then
  ok
else
  fail
  track_error "apt-get update" "Failed to update package lists"
fi

# =============================================================================
# PACKAGE: GIT
# =============================================================================
header "GIT"

if [[ "${INSTALL_GIT:-false}" != "true" ]]; then
  task "git"; skip; track_skipped "git"
else
  task "git"
  if is_installed git; then
    if is_upgradable git; then
      _old=$(get_pkg_version git)
      if apt_update_pkg git; then updated; track_updated "git" "$_old"
      else fail; track_error "git" "Update failed"; fi
    else ok; info "Already up to date"; track_current "git"; fi
  else
    if apt_install git; then installed_new; track_installed "git"
    else fail; track_error "git" "Install failed"; fi
  fi

  if [[ -n "${GIT_USER_NAME:-}" ]] && command -v git &>/dev/null; then
    task "Configuring git user name"
    if run_cmd "git config --global user.name \"$GIT_USER_NAME\""; then ok
    else fail; track_error "git config" "Failed to set user.name"; fi
  fi

  if [[ -n "${GIT_USER_EMAIL:-}" ]] && command -v git &>/dev/null; then
    task "Configuring git user email"
    if run_cmd "git config --global user.email \"$GIT_USER_EMAIL\""; then ok
    else fail; track_error "git config" "Failed to set user.email"; fi
  fi
fi

# =============================================================================
# PACKAGE: MIDNIGHT COMMANDER (mc)
# =============================================================================
header "MIDNIGHT COMMANDER (mc)"

if [[ "${INSTALL_MC:-false}" != "true" ]]; then
  task "mc"; skip; track_skipped "mc"
else
  task "mc"
  if is_installed mc; then
    if is_upgradable mc; then
      _old=$(get_pkg_version mc)
      if apt_update_pkg mc; then updated; track_updated "mc" "$_old"
      else fail; track_error "mc" "Update failed"; fi
    else ok; info "Already up to date"; track_current "mc"; fi
  else
    if apt_install mc; then installed_new; track_installed "mc"
    else fail; track_error "mc" "Install failed"; fi
  fi
fi

# =============================================================================
# PACKAGE: AWS CLI
# =============================================================================
header "AWS CLI"

if [[ "${INSTALL_AWSCLI:-false}" != "true" ]]; then
  task "awscli"; skip; track_skipped "awscli"
else
  # AWS CLI v2 requires manual install — not in apt
  AWSCLI_TMP=$(mktemp -d)

  if command -v aws &>/dev/null; then
    # Capture version before attempting update
    AWSCLI_INSTALLED=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[^\s]+')

    # Fetch latest version from GitHub tags (lightweight, no zip download)
    task "awscli (checking version)"
    AWSCLI_LATEST=$(curl -fsSL "https://api.github.com/repos/aws/aws-cli/git/refs/tags" ${SILENT_ERR} \
      | grep -oP '"ref":\s*"refs/tags/\K[0-9]+\.[0-9]+\.[0-9]+' \
      | sort -V | tail -1)

    if [[ -z "$AWSCLI_LATEST" ]]; then
      warn "Could not determine latest AWS CLI version — skipping update"
      ok; track_current "awscli"
    elif [[ "$AWSCLI_INSTALLED" == "$AWSCLI_LATEST" ]]; then
      ok; info "Already up to date (${AWSCLI_INSTALLED})"; track_current "awscli"
    else
      ok
      task "awscli (downloading ${AWSCLI_INSTALLED} → ${AWSCLI_LATEST})"
      if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
          -o "${AWSCLI_TMP}/awscliv2.zip" ${SILENT_ERR} \
        && unzip -q "${AWSCLI_TMP}/awscliv2.zip" -d "$AWSCLI_TMP" ${SILENT_ERR} \
        && run_cmd "${AWSCLI_TMP}/aws/install --update"; then
        # Verify version actually changed after install
        AWSCLI_NEW=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[^\s]+')
        if [[ "$AWSCLI_NEW" != "$AWSCLI_INSTALLED" ]]; then
          updated; track_updated "awscli" "$AWSCLI_INSTALLED"
        else
          ok; info "Installer ran but version unchanged (${AWSCLI_INSTALLED})"; track_current "awscli"
        fi
      else
        fail; track_error "awscli" "Update failed"
      fi
    fi
  else
    task "awscli (downloading installer)"
    if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
        -o "${AWSCLI_TMP}/awscliv2.zip" ${SILENT_ERR} \
      && unzip -q "${AWSCLI_TMP}/awscliv2.zip" -d "$AWSCLI_TMP" ${SILENT_ERR} \
      && run_cmd "${AWSCLI_TMP}/aws/install"; then
      installed_new; track_installed "awscli"
    else
      fail; track_error "awscli" "Install failed"
    fi
  fi

  if [[ -n "${AWS_DEFAULT_REGION:-}" ]] && command -v aws &>/dev/null; then
    task "Configuring AWS default region"
    if run_cmd "aws configure set default.region \"$AWS_DEFAULT_REGION\""; then ok
    else fail; track_error "aws config" "Failed to set region"; fi
  fi

  rm -rf "$AWSCLI_TMP"
fi

# =============================================================================
# PACKAGE: DUF (disk usage tool)
# =============================================================================
header "DUF (Disk Usage)"

if [[ "${INSTALL_DUF:-false}" != "true" ]]; then
  task "duf"; skip; track_skipped "duf"
else
  task "duf"
  if is_installed duf || command -v duf &>/dev/null; then
    if is_upgradable duf; then
      _old=$(get_pkg_version duf)
      if apt_update_pkg duf ${SILENT_ERR}; then updated; track_updated "duf" "$_old"
      else fail; track_error "duf" "Update failed"; fi
    else ok; info "Already up to date"; track_current "duf"; fi
  else
    # Try apt first, fall back to GitHub release
    if apt_install duf ${SILENT_ERR}; then
      installed_new; track_installed "duf"
    else
      # Install from GitHub releases
      DUF_TMP=$(mktemp -d)
      ARCH=$(dpkg --print-architecture)
      DUF_URL=$(curl -fsSL https://api.github.com/repos/muesli/duf/releases/latest \
        | grep "browser_download_url" \
        | grep "linux_${ARCH}.deb" \
        | cut -d '"' -f 4 | head -1)

      if [[ -n "$DUF_URL" ]] \
        && curl -fsSL "$DUF_URL" -o "${DUF_TMP}/duf.deb" ${SILENT_ERR} \
          && run_cmd "dpkg -i \"${DUF_TMP}/duf.deb\""; then
        installed_new; track_installed "duf"
      else
        fail; track_error "duf" "Install failed"
      fi
      rm -rf "$DUF_TMP"
    fi
  fi
fi

# =============================================================================
# PACKAGE: DOCKER & DOCKER COMPOSE
# =============================================================================
header "DOCKER & DOCKER COMPOSE"

if [[ "${INSTALL_DOCKER:-false}" != "true" ]]; then
  task "docker"; skip; track_skipped "docker"
else
  if command -v docker &>/dev/null; then
    task "docker (already installed, checking for updates)"
    if is_upgradable docker-ce; then
      _old=$(get_pkg_version docker-ce)
      if apt_update_pkg docker-ce ${SILENT_ERR}; then updated; track_updated "docker" "$_old"
      else fail; track_error "docker" "Update failed"; fi
    else ok; info "Already up to date"; track_current "docker-ce"; fi
  else
    task "Adding Docker apt repository"
    DOCKER_OK=true

    # Install prerequisites
    apt_install "ca-certificates curl gnupg" ${SILENT_ERR} || true
    install -m 0755 -d /etc/apt/keyrings

    # Add Docker GPG key
    if curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg ${SILENT_ERR}; then
      chmod a+r /etc/apt/keyrings/docker.gpg
      ok
    else
      fail; DOCKER_OK=false; track_error "docker" "Failed to add GPG key"
    fi

    if [[ "$DOCKER_OK" == "true" ]]; then
      task "Adding Docker apt sources"
      DISTRO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
      echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian ${DISTRO_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

      if apt_run update -qq; then ok
      else fail; DOCKER_OK=false; track_error "docker" "apt update after adding repo failed"; fi
    fi

    if [[ "$DOCKER_OK" == "true" ]]; then
      task "Installing docker"
      if apt_install "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"; then
        installed_new; track_installed "docker"
      else
        fail; track_error "docker" "Install failed"
      fi
    fi
  fi

  # Add user to docker group
  if [[ -n "${DOCKER_USER:-}" ]] && id "$DOCKER_USER" &>/dev/null; then
    task "Adding $DOCKER_USER to docker group"
    if run_cmd "usermod -aG docker \"$DOCKER_USER\""; then ok
    else fail; track_error "docker group" "Failed to add $DOCKER_USER"; fi
  fi

  # Enable and start Docker
  task "Enabling docker service"
  if run_cmd "systemctl enable --now docker"; then ok
  else fail; track_error "docker" "Failed to enable service"; fi
fi

# =============================================================================
# PACKAGE: TAILSCALE
# =============================================================================
header "TAILSCALE"

if [[ "${INSTALL_TAILSCALE:-false}" != "true" ]]; then
  task "tailscale"; skip; track_skipped "tailscale"
else
  if command -v tailscale &>/dev/null; then
    task "tailscale (already installed, checking for updates)"
    if is_upgradable tailscale; then
      _old=$(get_pkg_version tailscale)
      if apt_update_pkg tailscale ${SILENT_ERR}; then updated; track_updated "tailscale" "$_old"
      else fail; track_error "tailscale" "Update failed"; fi
    else ok; info "Already up to date"; track_current "tailscale"; fi
  else
    task "Adding Tailscale apt repository"
    TAILSCALE_OK=true

    if curl -fsSL https://pkgs.tailscale.com/stable/debian/$(. /etc/os-release && echo "$VERSION_CODENAME").gpg \
        | gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg ${SILENT_ERR} \
      && curl -fsSL https://pkgs.tailscale.com/stable/debian/$(. /etc/os-release && echo "$VERSION_CODENAME").list \
        | sed 's|]/|] signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg /|' \
        > /etc/apt/sources.list.d/tailscale.list ${SILENT_ERR} \
      && apt_run update -qq; then
      ok
    else
      fail; TAILSCALE_OK=false; track_error "tailscale" "Failed to add repository"
    fi

    if [[ "$TAILSCALE_OK" == "true" ]]; then
      task "Installing tailscale"
      if apt_install tailscale; then
        installed_new; track_installed "tailscale"
      else
        fail; track_error "tailscale" "Install failed"
      fi
    fi

    task "Enabling tailscale service"
    if run_cmd "systemctl enable --now tailscaled"; then ok
    else fail; track_error "tailscale" "Failed to enable service"; fi
  fi

  # Connect to Tailscale if auth key is provided and not already connected
  if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    task "Checking Tailscale connection status"
      TS_STATE=$(tailscale status --json ${SILENT_ERR} | grep -oP '"BackendState":\s*"\K[^"]+')
    if [[ "$TS_STATE" == "Running" ]]; then
      ok; info "Already connected to Tailscale — skipping 'tailscale up'"
    else
      ok
      task "Connecting to Tailscale network"
      if run_cmd "tailscale up --authkey=\"$TAILSCALE_AUTH_KEY\" --hostname=\"${TAILSCALE_HOSTNAME:-$(hostname)}\" ${TAILSCALE_EXTRA_ARGS:-}"; then
        ok
      else
        fail; track_error "tailscale" "Failed to connect (check auth key)"
      fi
    fi
  else
    info "No TAILSCALE_AUTH_KEY set — run 'tailscale up' manually to connect"
  fi
fi

# =============================================================================
# PACKAGE: NFS CLIENT & MOUNT
# =============================================================================
header "NFS CLIENT & MOUNTS"

if [[ "${INSTALL_NFS:-false}" != "true" ]]; then
  task "nfs-common"; skip; track_skipped "nfs"
else
  task "nfs-common"
  if is_installed nfs-common; then
    if is_upgradable nfs-common; then
      _old=$(get_pkg_version nfs-common)
      if apt_update_pkg nfs-common; then updated; track_updated "nfs-common" "$_old"
      else fail; track_error "nfs-common" "Update failed"; fi
    else ok; info "Already up to date"; track_current "nfs-common"; fi
  else
    if apt_install nfs-common; then installed_new; track_installed "nfs-common"
    else fail; track_error "nfs-common" "Install failed"; fi
  fi

  # Build mount list: use explicit NFS_MOUNTS if defined, otherwise auto-discover
  declare -a _mounts=()

  if [[ -n "${NFS_MOUNTS:-}" && ${#NFS_MOUNTS[@]} -gt 0 ]]; then
    _mounts=("${NFS_MOUNTS[@]}")
    info "Using NFS_MOUNTS from config (${#_mounts[@]} entr(ies))"

  elif [[ -n "${NFS_SERVER_IP:-}" ]]; then
    info "NFS_MOUNTS not set — auto-discovering exports on ${NFS_SERVER_IP}..."
    local_ver="${NFS_VERSION:-4}"
    local_base="${NFS_MOUNT_BASE:-/mnt}"

    task "Querying NFS exports on ${NFS_SERVER_IP}"
    if [[ "${DEBUG:-false}" == "true" ]]; then
      raw_exports=$(showmount -e "${NFS_SERVER_IP}" 2>&1)
    else
      raw_exports=$(showmount -e "${NFS_SERVER_IP}" 2>/dev/null)
    fi
    if [[ $? -ne 0 ]]; then
      fail
      warn "Could not reach NFS server at ${NFS_SERVER_IP} — skipping mounts"
        track_error "nfs discover" "showmount failed for ${NFS_SERVER_IP}"
    else
      ok
      while IFS= read -r line; do
        [[ "$line" =~ ^Export ]] && continue
        exp_path=$(awk '{print $1}' <<< "$line")
        [[ -z "$exp_path" ]] && continue

        # Check if this export is already mounted anywhere
        if grep -qF "${NFS_SERVER_IP}:${exp_path}" /proc/mounts ${SILENT_ERR}; then
          existing_mp=$(awk -v src="${NFS_SERVER_IP}:${exp_path}" '$1==src {print $2}' /proc/mounts)
          info "Already mounted: ${exp_path} → ${existing_mp} — skipping"
          continue
        fi

        exp_default="${local_base}/$(basename "$exp_path")"
        # If NFS_MOUNT_NAME is set in config, use it as the default for the first export
        if [[ -n "${NFS_MOUNT_NAME:-}" && ${#_mounts[@]} -eq 0 ]]; then
          exp_default="${local_base}/${NFS_MOUNT_NAME}"
        fi
        printf "  ${CYAN}▸${RESET} ${BOLD}%s${RESET}  —  mount point ${DIM}(default: %s)${RESET}: " \
          "$exp_path" "$exp_default"
        read -r exp_mount </dev/tty
        exp_mount="${exp_mount:-$exp_default}"
        # Ensure path is absolute — prepend NFS_MOUNT_BASE if relative
        if [[ "$exp_mount" != /* ]]; then
          exp_mount="${local_base}/${exp_mount}"
          info "Relative path given — using ${exp_mount}"
        fi
        _mounts+=("${NFS_SERVER_IP}:${exp_path}:${exp_mount}:rw,nfsvers=${local_ver}")
        info "Queued: ${exp_path} → ${exp_mount}"
      done <<< "$raw_exports"
      info "${#_mounts[@]} export(s) queued for mounting"
    fi

  else
    warn "Neither NFS_MOUNTS nor NFS_SERVER_IP is set in config — skipping mount setup"
  fi

  # Process the mount list
  if [[ ${#_mounts[@]} -gt 0 ]]; then
    FSTAB_BACKED_UP=false

    for mount_entry in "${_mounts[@]}"; do
      [[ -z "$mount_entry" || "$mount_entry" =~ ^# ]] && continue

      IFS=':' read -r nas_ip remote_path mount_point mount_opts <<< "$mount_entry"
      nas_ip="${nas_ip:-}"
      remote_path="${remote_path:-}"
      mount_point="${mount_point:-}"
      mount_opts="${mount_opts:-rw,nfsvers=${NFS_VERSION:-4}}"

      [[ -z "$nas_ip" || -z "$remote_path" || -z "$mount_point" ]] && continue

      # Check if this export is already mounted anywhere (catches duplicate/different mount point)
      if grep -qF "${nas_ip}:${remote_path}" /proc/mounts ${SILENT_ERR}; then
        existing_mp=$(awk -v src="${nas_ip}:${remote_path}" '$1==src {print $2}' /proc/mounts)
        task "Mount ${remote_path}"; ok; info "Already mounted at ${existing_mp} — skipping"
        continue
      fi

      # Already in fstab AND actively mounted — nothing to do
        if grep -qF "${nas_ip}:${remote_path}" /etc/fstab ${SILENT_ERR} \
          && mountpoint -q "$mount_point" ${SILENT_ERR}; then
        task "Mount $mount_point"; ok; info "Already configured and mounted — skipping"
        continue
      fi

      # Create mount point if needed
      task "Creating mount point: $mount_point"
      if run_cmd "mkdir -p \"$mount_point\""; then ok
      else fail; track_error "nfs mount" "Could not create $mount_point"; continue; fi

      FSTAB_ENTRY="${nas_ip}:${remote_path} ${mount_point} nfs ${mount_opts},_netdev,nofail 0 0"

      # Add to fstab only if not already present
      if grep -qF "${nas_ip}:${remote_path}" /etc/fstab ${SILENT_ERR}; then
        task "fstab entry for $remote_path"; ok; info "Already exists — skipping add"
      else
        if [[ "$FSTAB_BACKED_UP" == "false" ]]; then
          run_cmd "cp /etc/fstab \"/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)\" || true"
          FSTAB_BACKED_UP=true
        fi
        task "Adding fstab entry for $remote_path"
        if run_cmd "bash -c 'printf \"%s\\n\" \"$FSTAB_ENTRY\" >> /etc/fstab'"; then ok
        else fail; track_error "fstab" "Failed to add entry for $remote_path"; continue; fi
      fi

      # Attempt mount
      task "Mounting ${nas_ip}:${remote_path}"
      if run_cmd "mount \"$mount_point\""; then
        ok
      else
        fail
        warn "Mount failed — will retry at boot (_netdev,nofail ensures safe boot)"
        track_error "nfs mount" "Could not mount $mount_point (NAS may be offline)"
      fi
    done
  fi
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_summary

# Detail lists
if [[ ${#INSTALLED_LIST[@]} -gt 0 ]]; then
  echo "  ${GREEN}Installed:${RESET}"
  for item in "${INSTALLED_LIST[@]}"; do echo "    ${DIM}• $item${RESET}"; done
fi
if [[ ${#UPDATED_LIST[@]} -gt 0 ]]; then
  echo "  ${CYAN}Updated:${RESET}"
  for item in "${UPDATED_LIST[@]}"; do echo "    ${DIM}• $item${RESET}"; done
fi
if [[ ${#CURRENT_LIST[@]} -gt 0 ]]; then
  echo "  ${BLUE}Current:${RESET}"
  for item in "${CURRENT_LIST[@]}"; do echo "    ${DIM}• $item${RESET}"; done
fi
if [[ ${#SKIPPED_LIST[@]} -gt 0 ]]; then
  echo "  ${YELLOW}Skipped:${RESET}"
  for item in "${SKIPPED_LIST[@]}"; do echo "    ${DIM}• $item${RESET}"; done
fi
if [[ ${#ERROR_LIST[@]} -gt 0 ]]; then
  echo "  ${RED}Errors:${RESET}"
  for item in "${ERROR_LIST[@]}"; do echo "    ${DIM}• $item${RESET}"; done
fi
echo ""

# =============================================================================
# APPEND RUN RECORD TO CONFIG FILE
# =============================================================================
{
  echo ""
  echo "# =============================================================="
  echo "# RUN RECORD: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Host:       $(hostname)"
  echo "# OS:         $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "# Script:     v${VERSION}"
  echo "# --------------------------------------------------------------"
  if [[ ${#INSTALLED_LIST[@]} -gt 0 ]]; then
    echo "# Installed:"
    for item in "${INSTALLED_LIST[@]}"; do echo "#   • $item"; done
  fi
  if [[ ${#UPDATED_LIST[@]} -gt 0 ]]; then
    echo "# Updated:"
    for item in "${UPDATED_LIST[@]}"; do echo "#   • $item"; done
  fi
  if [[ ${#CURRENT_LIST[@]} -gt 0 ]]; then
    echo "# Current:"
    for item in "${CURRENT_LIST[@]}"; do echo "#   • $item"; done
  fi
  if [[ ${#SKIPPED_LIST[@]} -gt 0 ]]; then
    echo "# Skipped:"
    for item in "${SKIPPED_LIST[@]}"; do echo "#   • $item"; done
  fi
  if [[ ${#ERROR_LIST[@]} -gt 0 ]]; then
    echo "# Errors:"
    for item in "${ERROR_LIST[@]}"; do echo "#   • $item"; done
  fi
  echo "# =============================================================="
} >> "$CONFIG_FILE"

info "Run record appended to: $CONFIG_FILE"
echo ""

if [[ ${#ERROR_LIST[@]} -gt 0 ]]; then
  warn "Setup completed with ${#ERROR_LIST[@]} error(s). Review above for details."
  exit 1
else
  echo "  ${BOLD}${GREEN}Setup completed successfully.${RESET}"
  echo ""
  exit 0
fi

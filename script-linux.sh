#!/usr/bin/env bash
# DevOps Bootcamp Environment Readiness Checker — Linux Desktop
# (Ubuntu/Debian via apt, Fedora/RHEL family via dnf).
#
# Phase 1: detect Git, VS Code, Docker Engine.
# Phase 2: for each missing item, prompt user to install (Y) or skip (n).
#          Non-interactive runs auto-install (preserves CI behavior).
# Phase 3: print summary table.
#
# Docker Engine install follows Docker's official docs:
#   https://docs.docker.com/engine/install/ubuntu/
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/install/fedora/
#   https://docs.docker.com/engine/install/rhel/  (and Rocky/AlmaLinux via the centos repo)
#
# Self-elevates via sudo. Logs to script.log next to itself. Idempotent.

set -u
set -o pipefail

# --- self-elevate -----------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "Requesting sudo privileges..."
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: sudo not installed and script not run as root." >&2
    exit 1
  fi
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/script.log"
: > "$LOG_FILE"

# --- helpers ----------------------------------------------------------
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Run a command, tee combined output to the log. Returns the command's exit code.
run_logged() {
  log "Running: $*"
  local rc=0
  { "$@" 2>&1 | tee -a "$LOG_FILE"; rc=${PIPESTATUS[0]}; } || true
  log "Exit: $rc"
  return "$rc"
}

# Summary table state — three parallel arrays.
SUMMARY_COMPONENT=()
SUMMARY_STATUS=()
SUMMARY_REASON=()

add_result() {
  SUMMARY_COMPONENT+=("$1")
  SUMMARY_STATUS+=("$2")
  SUMMARY_REASON+=("${3:-}")
  if [ -n "${3:-}" ]; then
    log "$1 : $2 ($3)"
  else
    log "$1 : $2"
  fi
}

# Color helpers — auto-disabled when stdout is not a TTY.
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
  C_DIM=$'\033[90m';  C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YEL=''; C_DIM=''; C_CYAN=''; C_RESET=''
fi

# Prompt the user before running an installer. Default Y; non-TTY auto-installs.
# Args: <component> <command-description-shown-to-user>
# Returns 0 to install, 1 to skip.
prompt_install() {
  local component="$1" cmd_desc="$2" reply=""
  if [ ! -t 0 ]; then
    log "Non-interactive: auto-installing $component"
    return 0
  fi
  printf '\n  %sInstall %s?%s Will run: %s%s%s\n' \
    "$C_CYAN" "$component" "$C_RESET" "$C_DIM" "$cmd_desc" "$C_RESET"
  printf '    [Y] Let this script install it (default)\n'
  printf '    [n] Skip — I will install it myself\n'
  printf '  Choice [Y/n]: '
  IFS= read -r reply || reply=""
  reply="${reply:-Y}"
  case "$reply" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

print_table() {
  local n=${#SUMMARY_COMPONENT[@]}
  local w1=9 w2=13 w3=6
  local i len
  for ((i=0; i<n; i++)); do
    len=${#SUMMARY_COMPONENT[i]}; (( len > w1 )) && w1=$len
    len=${#SUMMARY_STATUS[i]};    (( len > w2 )) && w2=$len
    len=${#SUMMARY_REASON[i]};    (( len > w3 )) && w3=$len
  done
  local h1 h2 h3
  h1=$(printf '%*s' "$((w1+2))" '' | tr ' ' '-')
  h2=$(printf '%*s' "$((w2+2))" '' | tr ' ' '-')
  h3=$(printf '%*s' "$((w3+2))" '' | tr ' ' '-')
  printf '%s+%s+%s+%s+%s\n' "$C_DIM" "$h1" "$h2" "$h3" "$C_RESET"
  printf '%s| %-*s | %-*s | %-*s |%s\n' "$C_DIM" "$w1" "Component" "$w2" "Status" "$w3" "Reason" "$C_RESET"
  printf '%s+%s+%s+%s+%s\n' "$C_DIM" "$h1" "$h2" "$h3" "$C_RESET"
  for ((i=0; i<n; i++)); do
    local color
    case "${SUMMARY_STATUS[i]}" in
      Ready)         color="$C_GREEN" ;;
      "Not Ready")   color="$C_RED"   ;;
      "Not Supported") color="$C_YEL" ;;
      Skipped)       color="$C_YEL"   ;;
      *)             color="$C_YEL"   ;;
    esac
    printf '%s| %s%-*s%s | %s%-*s%s | %-*s |%s\n' \
      "$C_DIM" "$C_RESET" "$w1" "${SUMMARY_COMPONENT[i]}" "$C_DIM" \
      "$color" "$w2" "${SUMMARY_STATUS[i]}" "$C_DIM" \
      "$w3" "${SUMMARY_REASON[i]}" "$C_RESET"
  done
  printf '%s+%s+%s+%s+%s\n' "$C_DIM" "$h1" "$h2" "$h3" "$C_RESET"
}

# --- distro detect ----------------------------------------------------
PKG_MGR=""        # "apt" | "dnf" | ""
DISTRO_PRETTY=""
DISTRO_ID=""      # raw ID from /etc/os-release (ubuntu|debian|fedora|rhel|rocky|almalinux|...)

detect_distro() {
  if [ ! -r /etc/os-release ]; then
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
  DISTRO_ID="${ID:-}"
  local id_like="${ID_LIKE:-}"
  case " $DISTRO_ID $id_like " in
    *" debian "*|*" ubuntu "*) PKG_MGR="apt" ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) PKG_MGR="dnf" ;;
  esac
  log "Detected: $DISTRO_PRETTY (pkg_mgr=${PKG_MGR:-none})"
}

# --- header -----------------------------------------------------------
echo "${C_CYAN}=== DevOps Bootcamp Environment Readiness Checker (Linux) ===${C_RESET}"
detect_distro
printf '%s\n' "${C_DIM}OS:  ${DISTRO_PRETTY:-unknown}${C_RESET}"
echo "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
echo

if [ -z "$PKG_MGR" ]; then
  echo "${C_YEL}This distro is not supported by this script (unsupported distro).${C_RESET}"
  echo "${C_DIM}Supported families: Ubuntu/Debian (apt), Fedora/RHEL/Rocky/AlmaLinux (dnf).${C_RESET}"
  add_result "Git"           "Not Supported" "unsupported distro"
  add_result "VS Code"       "Not Supported" "unsupported distro"
  add_result "Docker Engine" "Not Supported" "unsupported distro"
  echo
  echo "${C_CYAN}=== Summary ===${C_RESET}"
  print_table
  exit 0
fi

# --- Phase 1: detection ----------------------------------------------
echo "${C_CYAN}-- Checking installed components --${C_RESET}"

GIT_PRESENT=0;    command -v git    >/dev/null 2>&1 && GIT_PRESENT=1
VSCODE_PRESENT=0; command -v code   >/dev/null 2>&1 && VSCODE_PRESENT=1
DOCKER_PRESENT=0
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
  DOCKER_PRESENT=1
fi

mark() {
  if [ "$2" -eq 1 ]; then
    printf '  %s[x]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
  else
    printf '  %s[ ]%s %s %s(missing)%s\n' "$C_RED" "$C_RESET" "$1" "$C_DIM" "$C_RESET"
  fi
}
mark "Git"           "$GIT_PRESENT"
mark "VS Code"       "$VSCODE_PRESENT"
mark "Docker Engine" "$DOCKER_PRESENT"
echo

MISSING=$(( (1-GIT_PRESENT) + (1-VSCODE_PRESENT) + (1-DOCKER_PRESENT) ))
if [ "$MISSING" -eq 0 ]; then
  echo "${C_GREEN}All components are present — nothing to install.${C_RESET}"
else
  if [ -t 0 ]; then
    echo "${C_DIM}For each missing item you'll be asked whether to let this script install it (Y) or install it yourself (n).${C_RESET}"
  else
    echo "${C_DIM}Non-interactive mode: missing components will be installed automatically.${C_RESET}"
  fi
fi
echo

# --- package index refresh -------------------------------------------
# Only refresh if there's something to install.
if [ "$MISSING" -gt 0 ]; then
  echo -n "Refreshing package index..."
  case "$PKG_MGR" in
    apt) run_logged apt-get update -qq ;;
    dnf) run_logged dnf -q makecache ;;
  esac
  echo " done."
fi

# --- Phase 2: install missing components ------------------------------
if [ "$MISSING" -gt 0 ]; then
  echo "${C_CYAN}-- Installing missing components --${C_RESET}"
fi

# --- Git --------------------------------------------------------------
install_git() {
  case "$PKG_MGR" in
    apt) run_logged env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ;;
    dnf) run_logged dnf install -y -q git ;;
  esac
}

if [ "$GIT_PRESENT" -eq 1 ]; then
  add_result "Git" "Ready"
else
  git_cmd="apt-get install -y git"
  [ "$PKG_MGR" = "dnf" ] && git_cmd="dnf install -y git"
  if prompt_install "Git" "$git_cmd"; then
    echo " ${C_YEL}installing Git...${C_RESET}"
    if install_git && command -v git >/dev/null 2>&1; then
      add_result "Git" "Ready"
    else
      add_result "Git" "Not Ready" "install failed (rc=$?)"
    fi
  else
    add_result "Git" "Skipped" "user will install manually"
  fi
fi

# --- VS Code ----------------------------------------------------------
install_vscode_apt() {
  run_logged install -m 0755 -d /etc/apt/keyrings
  run_logged bash -c "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg"
  run_logged chmod a+r /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
  run_logged apt-get update -qq
  run_logged env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq code
}

install_vscode_dnf() {
  run_logged rpm --import https://packages.microsoft.com/keys/microsoft.asc
  cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  run_logged dnf install -y -q code
}

if [ "$VSCODE_PRESENT" -eq 1 ]; then
  add_result "VS Code" "Ready"
else
  vscode_cmd="add Microsoft apt repo + apt-get install code"
  [ "$PKG_MGR" = "dnf" ] && vscode_cmd="add Microsoft yum repo + dnf install code"
  if prompt_install "VS Code" "$vscode_cmd"; then
    echo " ${C_YEL}installing VS Code...${C_RESET}"
    case "$PKG_MGR" in
      apt) install_vscode_apt ;;
      dnf) install_vscode_dnf ;;
    esac
    if command -v code >/dev/null 2>&1; then
      add_result "VS Code" "Ready"
    else
      add_result "VS Code" "Not Ready" "install failed"
    fi
  else
    add_result "VS Code" "Skipped" "user will install manually"
  fi
fi

# --- Docker Engine ----------------------------------------------------
# Follows Docker's official "Install using the apt/dnf repository" steps
# from https://docs.docker.com/engine/install/{ubuntu,debian,fedora,rhel}/.
# Installs: docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin,
# docker-compose-plugin. Then enables docker.service and adds the invoking
# user to the 'docker' group per the Linux post-install guide
# (https://docs.docker.com/engine/install/linux-postinstall/).

install_docker_engine_apt() {
  local docker_distro="ubuntu"
  [ "$DISTRO_ID" = "debian" ] && docker_distro="debian"
  local codename
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"

  run_logged install -m 0755 -d /etc/apt/keyrings
  run_logged curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" -o /etc/apt/keyrings/docker.asc
  run_logged chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_distro} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  run_logged apt-get update -qq
  run_logged env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_engine_dnf() {
  # RHEL/Rocky/AlmaLinux use the centos repo path; Fedora uses fedora.
  local docker_distro="fedora"
  case "$DISTRO_ID" in
    rhel|centos|rocky|almalinux) docker_distro="centos" ;;
  esac
  # curl the .repo file directly — works across dnf4 and dnf5 (avoids the
  # `config-manager addrepo` syntax change in dnf5).
  run_logged curl -fsSL "https://download.docker.com/linux/${docker_distro}/docker-ce.repo" \
    -o /etc/yum.repos.d/docker-ce.repo
  run_logged dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Returns the best non-root user to add to the docker group, or empty string.
target_docker_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    echo "$SUDO_USER"; return
  fi
  local lname
  lname="$(logname 2>/dev/null || true)"
  if [ -n "$lname" ] && [ "$lname" != "root" ]; then
    echo "$lname"; return
  fi
  echo ""
}

DOCKER_GROUP_NOTE=""

if [ "$DOCKER_PRESENT" -eq 1 ]; then
  add_result "Docker Engine" "Ready"
else
  docker_cmd="add Docker official apt repo + install docker-ce + enable docker.service + add user to 'docker' group"
  [ "$PKG_MGR" = "dnf" ] && docker_cmd="add Docker official dnf repo + install docker-ce + enable docker.service + add user to 'docker' group"
  if prompt_install "Docker Engine" "$docker_cmd"; then
    echo " ${C_YEL}installing Docker Engine...${C_RESET}"
    install_rc=127
    case "$PKG_MGR" in
      apt) install_docker_engine_apt; install_rc=$? ;;
      dnf) install_docker_engine_dnf; install_rc=$? ;;
    esac
    if ! command -v docker >/dev/null 2>&1; then
      add_result "Docker Engine" "Not Ready" "install failed (rc=$install_rc)"
    else
      # Try to enable + start the daemon. Fails inside containers without systemd.
      if command -v systemctl >/dev/null 2>&1 && run_logged systemctl enable --now docker; then
        du="$(target_docker_user)"
        if [ -n "$du" ]; then
          run_logged usermod -aG docker "$du"
          DOCKER_GROUP_NOTE="user '$du' added to 'docker' group — log out and back in for it to take effect"
          add_result "Docker Engine" "Ready"
        else
          add_result "Docker Engine" "Ready" "no non-root user detected — add yourself to 'docker' group manually"
        fi
      else
        add_result "Docker Engine" "Not Ready" "could not enable docker.service (no systemd or daemon failed)"
      fi
    fi
  else
    add_result "Docker Engine" "Skipped" "user will install manually"
  fi
fi

# --- Phase 3: summary -------------------------------------------------
echo
echo "${C_CYAN}=== Summary ===${C_RESET}"
print_table
echo
if [ -n "$DOCKER_GROUP_NOTE" ]; then
  echo "${C_CYAN}Note:${C_RESET} ${DOCKER_GROUP_NOTE}"
  echo
fi
echo "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
log "Bootstrap finished."

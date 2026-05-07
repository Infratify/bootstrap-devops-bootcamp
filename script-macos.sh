#!/usr/bin/env bash
# DevOps Bootcamp Environment Readiness Checker — macOS.
#
# Phase 1: detect Xcode CLT, Homebrew, Git, VS Code, Docker Desktop.
# Phase 2: for each missing item, prompt user to install (Y) or skip (n).
#          Non-interactive runs auto-install (preserves CI behavior).
# Phase 3: print summary table.
#
# Logs to script.log next to itself. Idempotent — safe to re-run.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/script.log"
: > "$LOG_FILE"

# --- helpers ----------------------------------------------------------
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

run_logged() {
  log "Running: $*"
  local rc=0
  { "$@" 2>&1 | tee -a "$LOG_FILE"; rc=${PIPESTATUS[0]}; } || true
  log "Exit: $rc"
  return "$rc"
}

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

ensure_brew_on_path() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

vscode_present() {
  [ -d "/Applications/Visual Studio Code.app" ] || command -v code >/dev/null 2>&1
}

docker_desktop_present() {
  [ -d "/Applications/Docker.app" ] || command -v docker >/dev/null 2>&1
}

# --- header -----------------------------------------------------------
echo "${C_CYAN}=== DevOps Bootcamp Environment Readiness Checker (macOS) ===${C_RESET}"
printf '%s\n' "${C_DIM}OS:  $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))${C_RESET}"
printf '%s\n' "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
echo

# --- Phase 1: detection ----------------------------------------------
echo "${C_CYAN}-- Checking installed components --${C_RESET}"

ensure_brew_on_path

XCODE_PRESENT=0; xcode-select -p >/dev/null 2>&1 && XCODE_PRESENT=1
BREW_PRESENT=0;  command -v brew >/dev/null 2>&1 && BREW_PRESENT=1
GIT_PRESENT=0;   command -v git  >/dev/null 2>&1 && GIT_PRESENT=1
VSCODE_PRESENT=0; vscode_present && VSCODE_PRESENT=1
DOCKER_PRESENT=0; docker_desktop_present && DOCKER_PRESENT=1

mark() {
  if [ "$2" -eq 1 ]; then
    printf '  %s[x]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
  else
    printf '  %s[ ]%s %s %s(missing)%s\n' "$C_RED" "$C_RESET" "$1" "$C_DIM" "$C_RESET"
  fi
}
mark "Xcode Command Line Tools" "$XCODE_PRESENT"
mark "Homebrew"                  "$BREW_PRESENT"
mark "Git"                       "$GIT_PRESENT"
mark "VS Code"                   "$VSCODE_PRESENT"
mark "Docker Desktop"            "$DOCKER_PRESENT"
echo

MISSING=$(( (1-XCODE_PRESENT) + (1-BREW_PRESENT) + (1-GIT_PRESENT) + (1-VSCODE_PRESENT) + (1-DOCKER_PRESENT) ))
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

# --- Phase 2: install missing components ------------------------------
if [ "$MISSING" -gt 0 ]; then
  echo "${C_CYAN}-- Installing missing components --${C_RESET}"
fi

# Xcode CLT
if [ "$XCODE_PRESENT" -eq 1 ]; then
  add_result "Xcode CLT" "Ready"
elif prompt_install "Xcode Command Line Tools" "xcode-select --install"; then
  echo " ${C_YEL}installing Xcode CLT (a system dialog will appear)...${C_RESET}"
  run_logged xcode-select --install || true
  waited=0
  max_wait=$((30 * 60))
  while ! xcode-select -p >/dev/null 2>&1; do
    sleep 10
    waited=$((waited + 10))
    if [ "$waited" -ge "$max_wait" ]; then
      add_result "Xcode CLT" "Not Ready" "install did not complete within 30 min"
      break
    fi
    printf '.'
  done
  if xcode-select -p >/dev/null 2>&1; then
    add_result "Xcode CLT" "Ready"
    echo " ${C_GREEN}done.${C_RESET}"
  fi
else
  add_result "Xcode CLT" "Skipped" "user will install manually"
fi

# Homebrew
if [ "$BREW_PRESENT" -eq 1 ]; then
  add_result "Homebrew" "Ready"
elif prompt_install "Homebrew" "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""; then
  echo " ${C_YEL}installing Homebrew...${C_RESET}"
  # shellcheck disable=SC2016
  # The $() must be expanded by the inner bash -c, not the outer one — this is
  # the canonical Homebrew installer invocation per https://brew.sh.
  run_logged bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null'
  ensure_brew_on_path
  if command -v brew >/dev/null 2>&1; then
    add_result "Homebrew" "Ready"
  else
    add_result "Homebrew" "Not Ready" "install failed"
  fi
else
  add_result "Homebrew" "Skipped" "user will install manually"
fi

BREW_AVAILABLE=0
command -v brew >/dev/null 2>&1 && BREW_AVAILABLE=1

# Git
if [ "$GIT_PRESENT" -eq 1 ]; then
  add_result "Git" "Ready"
elif [ "$BREW_AVAILABLE" -ne 1 ]; then
  add_result "Git" "Not Ready" "requires Homebrew"
elif prompt_install "Git" "brew install git"; then
  echo " ${C_YEL}installing Git...${C_RESET}"
  if run_logged brew install git && command -v git >/dev/null 2>&1; then
    add_result "Git" "Ready"
  else
    add_result "Git" "Not Ready" "brew install failed"
  fi
else
  add_result "Git" "Skipped" "user will install manually"
fi

# VS Code
if [ "$VSCODE_PRESENT" -eq 1 ]; then
  add_result "VS Code" "Ready"
elif [ "$BREW_AVAILABLE" -ne 1 ]; then
  add_result "VS Code" "Not Ready" "requires Homebrew"
elif prompt_install "VS Code" "brew install --cask visual-studio-code"; then
  echo " ${C_YEL}installing VS Code...${C_RESET}"
  if run_logged brew install --cask visual-studio-code && vscode_present; then
    add_result "VS Code" "Ready"
  else
    add_result "VS Code" "Not Ready" "brew --cask install failed"
  fi
else
  add_result "VS Code" "Skipped" "user will install manually"
fi

# Docker Desktop
if [ "$DOCKER_PRESENT" -eq 1 ]; then
  add_result "Docker Desktop" "Ready"
elif [ "$BREW_AVAILABLE" -ne 1 ]; then
  add_result "Docker Desktop" "Not Ready" "requires Homebrew"
elif prompt_install "Docker Desktop" "brew install --cask docker"; then
  echo " ${C_YEL}installing Docker Desktop...${C_RESET}"
  if run_logged brew install --cask docker && docker_desktop_present; then
    add_result "Docker Desktop" "Ready"
  else
    add_result "Docker Desktop" "Not Ready" "brew --cask install failed"
  fi
else
  add_result "Docker Desktop" "Skipped" "user will install manually"
fi

# --- Phase 3: summary -------------------------------------------------
echo
echo "${C_CYAN}=== Summary ===${C_RESET}"
print_table
echo
echo "${C_DIM}Open Docker Desktop once to finish first-run setup.${C_RESET}"
echo "${C_DIM}Restart your terminal so PATH changes take effect.${C_RESET}"
echo "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
log "Bootstrap finished."

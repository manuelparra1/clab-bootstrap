#!/usr/bin/env bash
#
# lib/ui.sh — shared terminal UI helpers.
#
# Every function here works two ways:
#   * If `gum` (https://github.com/charmbracelet/gum) is installed, use it —
#     nice menus, spinners, styled boxes.
#   * If not, fall back to plain bash: `read`, a braille spinner, and ANSI
#     colors. No external dependency, works on any POSIX-ish box.
#
# This matters because setup.sh runs BEFORE anything is installed, so it
# can't assume gum exists. It offers to install it, then re-sources this
# file to light up the nicer path.
#
# Source it, don't execute it:
#   source "$(dirname "$0")/lib/ui.sh"

# ---------------------------------------------------------------------------
# Capability detection
# ---------------------------------------------------------------------------
ui_has_gum() { command -v gum >/dev/null 2>&1; }

# Colors (used by the fallback path and for gum's --foreground flags)
UI_PRIMARY="212"   # pink
UI_ACCENT="99"     # purple
UI_OK="42"         # green
UI_WARN="214"      # orange
UI_ERR="196"       # red
UI_MUTED="244"     # grey

# Raw ANSI for the no-gum path
_C_RESET=$'\033[0m'
_C_BOLD=$'\033[1m'
_C_GREEN=$'\033[32m'
_C_YELLOW=$'\033[33m'
_C_RED=$'\033[31m'
_C_CYAN=$'\033[36m'
_C_GREY=$'\033[90m'

# ---------------------------------------------------------------------------
# Output primitives
# ---------------------------------------------------------------------------

# ui_header "Title" — big banner box
ui_header() {
  if ui_has_gum; then
    gum style --border double --margin "1 0" --padding "1 3" \
      --border-foreground "$UI_PRIMARY" --foreground "$UI_PRIMARY" --bold "$1"
  else
    echo
    echo "${_C_BOLD}${_C_CYAN}==============================================${_C_RESET}"
    echo "${_C_BOLD}${_C_CYAN}  $1${_C_RESET}"
    echo "${_C_BOLD}${_C_CYAN}==============================================${_C_RESET}"
    echo
  fi
}

# ui_step "Doing the thing" — section marker
ui_step() {
  if ui_has_gum; then
    gum style --foreground "$UI_ACCENT" --bold "==> $1"
  else
    echo "${_C_BOLD}${_C_CYAN}==>${_C_RESET} ${_C_BOLD}$1${_C_RESET}"
  fi
}

ui_ok() {
  if ui_has_gum; then
    gum style --foreground "$UI_OK" "  ✓ $1"
  else
    echo "  ${_C_GREEN}✓${_C_RESET} $1"
  fi
}

ui_warn() {
  if ui_has_gum; then
    gum style --foreground "$UI_WARN" "  ! $1"
  else
    echo "  ${_C_YELLOW}!${_C_RESET} $1"
  fi
}

ui_err() {
  if ui_has_gum; then
    gum style --foreground "$UI_ERR" --bold "  ✗ $1"
  else
    echo "  ${_C_RED}✗${_C_RESET} $1" >&2
  fi
}

ui_info() {
  if ui_has_gum; then
    gum style --foreground "$UI_MUTED" "    $1"
  else
    echo "    ${_C_GREY}$1${_C_RESET}"
  fi
}

# ui_note "multi-line body text" — soft bordered callout for explanations
ui_note() {
  if ui_has_gum; then
    gum style --border rounded --padding "0 2" --margin "0 0" \
      --border-foreground "$UI_MUTED" --foreground "$UI_MUTED" "$1"
  else
    echo
    echo "${_C_GREY}$1${_C_RESET}"
    echo
  fi
}

# ---------------------------------------------------------------------------
# Spinner — runs a command, shows progress while it works
#   ui_spin "Installing Docker" sudo apt-get install -y docker-ce
# Command output is captured to a log; on failure we dump the tail of it.
# ---------------------------------------------------------------------------
UI_LOG="${UI_LOG:-/tmp/clab-setup.log}"

ui_spin() {
  local title="$1"; shift

  if ui_has_gum; then
    if gum spin --spinner dot --title "$title" --show-error -- "$@" >>"$UI_LOG" 2>&1; then
      ui_ok "$title"
      return 0
    else
      ui_err "$title — failed"
      ui_info "Last 20 lines of $UI_LOG:"
      tail -n 20 "$UI_LOG" >&2
      return 1
    fi
  fi

  # Fallback: braille spinner in pure bash, backgrounded command.
  local frames='⣾⣽⣻⢿⡿⣟⣯⣷'
  "$@" >>"$UI_LOG" 2>&1 &
  local pid=$!
  local i=0
  # Only animate on an interactive TTY; in a pipe/CI just print the title.
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i + 1) % 8 ))
      printf '\r  %s %s' "${frames:$i:1}" "$title"
      sleep 0.1
    done
    printf '\r\033[K'
  else
    echo "  ... $title"
  fi
  if wait "$pid"; then
    ui_ok "$title"
    return 0
  else
    ui_err "$title — failed"
    ui_info "Last 20 lines of $UI_LOG:"
    tail -n 20 "$UI_LOG" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Input primitives
# ---------------------------------------------------------------------------

# ui_confirm "Question?" [default_yes|default_no] -> returns 0 for yes
ui_confirm() {
  local prompt="$1"
  local default="${2:-default_yes}"

  if ui_has_gum; then
    if [[ "$default" == "default_no" ]]; then
      gum confirm --default=false "$prompt"
    else
      gum confirm --default=true "$prompt"
    fi
    return $?
  fi

  local hint="[Y/n]"; [[ "$default" == "default_no" ]] && hint="[y/N]"
  local reply
  read -r -p "  $prompt $hint " reply
  reply="${reply:-}"
  if [[ -z "$reply" ]]; then
    [[ "$default" == "default_no" ]] && return 1 || return 0
  fi
  [[ "$reply" =~ ^[Yy] ]]
}

# ui_choose "Header" "opt1" "opt2" ... -> echoes chosen option
ui_choose() {
  local header="$1"; shift

  if ui_has_gum; then
    gum choose --header "$header" --cursor "▸ " \
      --header.foreground "$UI_ACCENT" --cursor.foreground "$UI_PRIMARY" "$@"
    return $?
  fi

  echo "  $header" >&2
  local i=1
  for opt in "$@"; do
    echo "    $i) $opt" >&2
    i=$((i + 1))
  done
  local pick
  while true; do
    read -r -p "  Choose [1-$#]: " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= $# )); then
      echo "${!pick}"
      return 0
    fi
    echo "  Enter a number between 1 and $#." >&2
  done
}

# ui_input "Prompt" "placeholder" -> echoes what was typed
ui_input() {
  local prompt="$1"
  local placeholder="${2:-}"

  if ui_has_gum; then
    gum input --header "$prompt" --placeholder "$placeholder"
    return $?
  fi

  local val
  read -r -p "  $prompt " val
  echo "$val"
}

# ui_pause "Press enter to continue"
ui_pause() {
  local msg="${1:-Press enter to continue}"
  if ui_has_gum; then
    gum input --header "$msg" --placeholder "" >/dev/null
  else
    read -r -p "  $msg... " _
  fi
}

# ---------------------------------------------------------------------------
# gum bootstrap — offered by setup.sh before anything else
# ---------------------------------------------------------------------------
ui_install_gum() {
  if ui_has_gum; then
    return 0
  fi
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
    | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gum
}

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

# Deliberately does NOT use `gum spin`, even when gum is available.
#
# gum spin renders its spinner to stdout and swallows the child's output into
# its own buffer. To keep a log we'd have to redirect gum's stdout to the file
# — which puts bubbletea's escape codes (cursor hide, bracketed paste, mouse
# tracking) into the log, hides the spinner from the user, and leaves the
# child's real error mangled and truncated. Two streams, two destinations:
# animation to the terminal, command output to the log. Plain bash does that
# correctly and gum does not, so gum stays where it's actually better —
# ui_header, ui_confirm, ui_choose.
#
# The command runs with stdin closed. Anything needing user input must happen
# BEFORE the spinner starts: a prompt under a spinner is invisible (erased
# every 0.1s) and looks exactly like a hang. sudo is the usual offender — it
# reads from /dev/tty, which no stdout redirection captures. Call
# ui_ensure_sudo first so the credential cache is already warm.
#
# CLAB_VERBOSE=1 skips the spinner and streams output live. Reach for it when
# a step fails and you need to watch it happen.
ui_spin() {
  local title="$1"; shift

  printf '\n===== %s =====\n' "$title" >>"$UI_LOG"

  if [[ "${CLAB_VERBOSE:-0}" == "1" ]]; then
    ui_step "$title"
    if "$@" </dev/null 2>&1 | tee -a "$UI_LOG"; then
      ui_ok "$title"
      return 0
    fi
    ui_err "$title — failed"
    return 1
  fi

  local frames='⣾⣽⣻⢿⡿⣟⣯⣷'
  "$@" </dev/null >>"$UI_LOG" 2>&1 &
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
  fi

  ui_err "$title — failed"
  ui_info "Last 40 lines of $UI_LOG:"
  echo >&2
  tail -n 40 "$UI_LOG" >&2
  echo >&2
  ui_info "To watch this step run live instead:"
  ui_info "  CLAB_VERBOSE=1 ./setup.sh"
  return 1
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
# Preflight — sudo and the handful of packages this repo assumes exist
#
# A Debian netinst install is *minimal*: no curl, no gnupg, and if you set a
# root password during install, your user isn't in the sudo group either.
# Everything below runs before the first spinner, so prompts are visible.
# ---------------------------------------------------------------------------

UI_SUDO_KEEPALIVE_PID=""

# $USER is unset in non-login shells; resolve once so the guidance messages
# below can still name the actual account.
UI_ME="${USER:-$(id -un 2>/dev/null)}"
UI_ME="${UI_ME:-your-user}"

ui_sudo_stop() {
  if [[ -n "$UI_SUDO_KEEPALIVE_PID" ]]; then
    kill "$UI_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    UI_SUDO_KEEPALIVE_PID=""
  fi
}

# ui_ensure_sudo — prove we can sudo, and prime the credential cache.
#
# The priming is the important part. Later steps run inside ui_spin, where a
# sudo password prompt is invisible and indistinguishable from a hang. Getting
# the password now means every later sudo hits a warm cache and never asks.
ui_ensure_sudo() {
  [[ $EUID -eq 0 ]] && return 0

  if ! command -v sudo >/dev/null 2>&1; then
    ui_err "sudo is not installed."
    ui_info "Debian's installer skips sudo when you set a root password."
    ui_info "Fix it from a root shell, then re-run this script:"
    ui_info ""
    ui_info "  su -"
    ui_info "  apt-get update && apt-get install -y sudo"
    ui_info "  usermod -aG sudo ${UI_ME}"
    ui_info "  exit"
    ui_info ""
    ui_info "Then log out and back in so the group takes effect."
    return 1
  fi

  if ! sudo -n true 2>/dev/null; then
    ui_info "This needs root for package installs. You'll be asked once."
    if ! sudo -v; then
      ui_err "Can't get sudo rights for ${UI_ME}."
      ui_info "If you saw 'user is not in the sudoers file', run from a root shell:"
      ui_info ""
      ui_info "  su -"
      ui_info "  usermod -aG sudo ${UI_ME}"
      ui_info "  exit"
      ui_info ""
      ui_info "Then log out and back in — group changes need a new login."
      return 1
    fi
  fi

  # Keep the cache warm for the whole run, so a long bootstrap doesn't hit
  # the 15-minute sudo timeout mid-spinner and stall waiting for a password.
  ( while true; do sleep 50; sudo -n true 2>/dev/null || exit 0; done ) &
  UI_SUDO_KEEPALIVE_PID=$!
  trap ui_sudo_stop EXIT
  return 0
}

# ui_repair_apt_sources — find apt repos pointing at a signed-by keyring that
# doesn't exist, and offer to disable them.
#
# A sources line whose keyring is missing makes apt fail *globally*: every
# `apt-get update` exits 100 with "the repository is not signed", so unrelated
# installs break too. Earlier versions of ui_install_gum could leave exactly
# this behind, so heal it rather than making people debug apt by hand.
#
# Disables by renaming to .disabled — reversible, unlike deleting.
ui_repair_apt_sources() {
  local f key broken=()

  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list; do
    # Pull the signed-by=<path> out of the options block, if present.
    # Bracket expression: ']' must come first, and [:space:] needs its own
    # brackets — GNU sed hard-errors on the [^],[:space:]] spelling.
    key="$(sed -n 's/.*signed-by=\([^][:space:],]*\).*/\1/p' "$f" | head -1)"
    if [[ -n "$key" && ! -e "$key" ]]; then
      broken+=("$f")
    fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    key="$(sed -n 's/^[[:space:]]*Signed-By:[[:space:]]*\(.*\)$/\1/p' "$f" | head -1)"
    if [[ -n "$key" && "$key" != /dev/null && ! -e "$key" ]]; then
      broken+=("$f")
    fi
  done
  shopt -u nullglob

  [[ ${#broken[@]} -eq 0 ]] && return 0

  ui_warn "Found apt repos whose signing key is missing:"
  for f in "${broken[@]}"; do
    ui_info "  $f"
  done
  ui_info "Until these are dealt with, every apt-get update on this machine"
  ui_info "fails — not just this script's."

  if ! ui_confirm "Disable them (rename to .disabled) so apt works again?"; then
    ui_warn "Left alone. Setup will fail at the first apt step."
    ui_info "Remove them by hand with: sudo rm <file>"
    return 1
  fi

  for f in "${broken[@]}"; do
    sudo mv "$f" "$f.disabled"
    ui_ok "Disabled $(basename "$f") (now $(basename "$f").disabled)"
  done
  return 0
}

# ui_ensure_base_deps — install what this repo uses before apt gets a chance to
# install it. curl and gpg are needed by the gum installer and by the Docker
# repo setup, both of which run before 00-bootstrap.sh's package step.
ui_ensure_base_deps() {
  local missing=()
  command -v curl    >/dev/null 2>&1 || missing+=(curl)
  command -v gpg     >/dev/null 2>&1 || missing+=(gnupg)
  command -v ip      >/dev/null 2>&1 || missing+=(iproute2)
  command -v getent  >/dev/null 2>&1 || missing+=(libc-bin)
  [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  ui_step "Installing prerequisites: ${missing[*]}"
  if ! sudo apt-get update -qq; then
    ui_err "apt-get update failed — check network and /etc/apt/sources.list.d/."
    return 1
  fi
  if ! sudo apt-get install -y -qq "${missing[@]}"; then
    ui_err "Couldn't install: ${missing[*]}"
    return 1
  fi
  ui_ok "Prerequisites installed"
}

# ---------------------------------------------------------------------------
# gum bootstrap — offered by setup.sh before anything else
# ---------------------------------------------------------------------------
#
# Ordering here is load-bearing. Writing charm.list before the keyring exists
# leaves apt permanently broken — EVERY later `apt-get update` exits 100 with
# "repository is not signed", which takes down the whole bootstrap, not just
# gum. That is exactly what the original version did when curl and gpg weren't
# installed yet: the key fetch failed, the sources line got written anyway, and
# apt stayed wedged until someone deleted the file by hand.
#
# So: fetch and validate the key first, install the sources line only once the
# keyring is really on disk, and roll the sources line back if anything after
# it fails. gum is a cosmetic nicety — it must never be able to break apt.
ui_install_gum() {
  if ui_has_gum; then
    return 0
  fi
  # Needs curl + gpg; ui_ensure_base_deps should have run by now, but this is
  # also callable on its own.
  if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
    echo "gum install needs curl and gnupg; run ui_ensure_base_deps first." >&2
    return 1
  fi

  local keyring="/etc/apt/keyrings/charm.gpg"
  local listfile="/etc/apt/sources.list.d/charm.list"
  local tmp
  tmp="$(mktemp -d)" || return 1

  if ! curl -fsSL https://repo.charm.sh/apt/gpg.key -o "$tmp/gpg.key"; then
    echo "Couldn't download the Charm signing key." >&2
    rm -rf "$tmp"
    return 1
  fi

  # Dearmor to a temp file and confirm it's non-empty before it goes anywhere
  # near /etc/apt. An empty or unparseable keyring is what apt chokes on.
  if ! gpg --dearmor < "$tmp/gpg.key" > "$tmp/charm.gpg" 2>/dev/null \
     || [[ ! -s "$tmp/charm.gpg" ]]; then
    echo "The Charm signing key didn't parse as a valid keyring." >&2
    rm -rf "$tmp"
    return 1
  fi

  sudo install -m 0755 -d /etc/apt/keyrings
  if ! sudo install -m 0644 "$tmp/charm.gpg" "$keyring"; then
    echo "Couldn't write $keyring." >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  echo "deb [signed-by=$keyring] https://repo.charm.sh/apt/ * *" \
    | sudo tee "$listfile" >/dev/null

  if ! sudo apt-get update -qq || ! sudo apt-get install -y -qq gum; then
    # Leave apt exactly as we found it rather than wedged.
    sudo rm -f "$listfile"
    echo "gum install failed — removed $listfile so apt keeps working." >&2
    return 1
  fi
  return 0
}

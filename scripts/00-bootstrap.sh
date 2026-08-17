#!/usr/bin/env bash
#
# 00-bootstrap.sh
#
# Turns a fresh Debian 13 (Trixie) VM into a Containerlab + network
# automation host. Safe to re-run — every step checks whether it already
# happened before doing it again.
#
# What it does:
#   1. Sanity-checks network/DNS
#   2. Fixes common netinst apt issues (stray cdrom line, missing repos)
#   3. Installs base packages (ifupdown, ssh, sudo, tmux, pv, git, python3-venv)
#   4. Installs Docker CE from Docker's official repo
#   5. Installs Containerlab (latest release via the official installer)
#   6. Creates ~/labs working directory structure
#   7. Builds a Python virtualenv (via uv if available, else python3 -m venv
#      + pip) with Ansible / Nornir / NAPALM / Netmiko
#
# Run as the regular user with sudo rights, NOT as root:
#   ./00-bootstrap.sh
#
# -E so the ERR trap below is inherited by functions and subshells.
set -Eeuo pipefail

# This script usually runs captured behind a spinner, where a bare non-zero
# exit tells you nothing. Report exactly which command died and where.
_on_err() {
  local rc=$?
  {
    echo
    echo "!! 00-bootstrap.sh FAILED"
    echo "   line:      ${BASH_LINENO[0]}"
    echo "   command:   ${BASH_COMMAND}"
    echo "   exit code: ${rc}"
    echo
  } >&2
  exit "$rc"
}
trap _on_err ERR

# ---------------------------------------------------------------------------
# Config — edit if your environment differs
# ---------------------------------------------------------------------------

# Docker publishes packages under the Debian codename directly. Read the
# codename off the running system rather than hardcoding it, so this works on
# bookworm as well as trixie. Override by exporting DOCKER_CODENAME=bookworm.
# If Docker hasn't cut packages for this release yet, the install step below
# retries against bookworm on its own.
# Subshell, and the `echo` is unconditional: sourcing a missing /etc/os-release
# inside `$( ... && ... )` makes the whole substitution non-zero, which under
# `set -e` aborts the script on what should be a soft detection step.
detect_codename() {
  [[ -r /etc/os-release ]] || return 0
  ( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}" )
}
DOCKER_CODENAME="${DOCKER_CODENAME:-$(detect_codename)}"
DOCKER_CODENAME="${DOCKER_CODENAME:-bookworm}"

# $USER isn't always set in non-login/non-interactive shells (e.g. when this
# is called from setup.sh), and `set -u` would abort on it — fall back to
# `id -un`, which always works.
WORK_USER="${SUDO_USER:-${USER:-$(id -un)}}"
LABS_DIR="$HOME/labs"
VENV_DIR="$HOME/.venvs/netauto"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$1"; }

# All apt goes through here.
#   DEBIAN_FRONTEND=noninteractive — a debconf prompt would render underneath
#     the caller's progress line where nobody can see it, and wait forever.
#     Same invisible-hang class as an unprimed sudo password prompt.
#   -q (not -qq) — -qq silences apt completely, which is what made "Installing
#     base packages" sit there for minutes with nothing to show. -q keeps the
#     Get:/Unpacking/Setting up lines that make progress legible.
apt_get() { sudo DEBIAN_FRONTEND=noninteractive apt-get -q "$@"; }

# Add $WORK_USER to a group only if the group exists and they aren't in it.
# Sets GROUPS_CHANGED so the caller can tell the user to re-login only when
# something actually changed.
GROUPS_CHANGED=0
add_user_to_group() {
  local grp="$1"
  if ! getent group "$grp" >/dev/null 2>&1; then
    return 1
  fi
  if id -nG "$WORK_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
    echo "$WORK_USER is already in the '$grp' group."
    return 0
  fi
  sudo usermod -aG "$grp" "$WORK_USER"
  echo "Added $WORK_USER to the '$grp' group (takes effect on next login)."
  GROUPS_CHANGED=1
}

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it calls sudo itself), not as root." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 0. sudo
#
# setup.sh primes the sudo cache before calling us, so `sudo -n` succeeds and
# nothing prompts. Run standalone from a terminal, we prompt here instead.
# What we must never do is let sudo prompt while our output is being captured
# — the prompt goes to /dev/tty, the caller's spinner erases it, and the whole
# thing looks like a hang.
# ---------------------------------------------------------------------------
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is not installed. From a root shell:" >&2
  echo "  su -" >&2
  echo "  apt-get update && apt-get install -y sudo" >&2
  echo "  usermod -aG sudo $(id -un)" >&2
  echo "Then log out, back in, and re-run this." >&2
  exit 1
fi

if ! sudo -n true 2>/dev/null; then
  if [[ -t 0 ]]; then
    sudo -v || { echo "Need sudo rights to continue." >&2; exit 1; }
  else
    echo "sudo needs a password but there's no terminal to ask on." >&2
    echo "Run 'sudo -v' first, then re-run this script." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Network / DNS sanity check
# ---------------------------------------------------------------------------
log "Checking network connectivity"
# Interface name varies by platform: ens192 on VMware (VMXNET3), ens18 or
# eth0 on Proxmox/KVM (virtio), enp0s* on bare metal. Detect it rather than
# hardcoding, so the error message is actually useful wherever this runs.
PRIMARY_IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
PRIMARY_IFACE="${PRIMARY_IFACE:-$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')}"
PRIMARY_IFACE="${PRIMARY_IFACE:-<your-interface>}"

if ! getent hosts deb.debian.org >/dev/null 2>&1; then
  warn "DNS resolution failed for deb.debian.org."
  warn "Check 'ip addr show ${PRIMARY_IFACE}' and 'cat /etc/resolv.conf'."
  warn "If ${PRIMARY_IFACE} has no address, make sure the VM's network is"
  warn "attached to a bridge/port group with DHCP (vmbr0 on Proxmox, the"
  warn "routable port group on VMware). See the README troubleshooting table."
  exit 1
fi
echo "DNS OK (via ${PRIMARY_IFACE})."

# ---------------------------------------------------------------------------
# 2. Fix common netinst apt issues
# ---------------------------------------------------------------------------
log "Checking apt sources"
if grep -rq '^deb cdrom:' /etc/apt/sources.list 2>/dev/null; then
  echo "Commenting out stray cdrom line left by netinst..."
  sudo sed -i 's/^deb cdrom:/# deb cdrom:/' /etc/apt/sources.list
fi

# Debian 13 ships sources in the deb822 format (/etc/apt/sources.list.d/*.sources),
# not the old one-line .list format — and its URIs may be a mirror indirection
# (mirror+file:///etc/apt/mirrors/debian.list) rather than a literal
# deb.debian.org URL. So don't pattern-match URLs; just ask whether ANY
# non-cdrom source is configured in either format. Getting this wrong means
# adding duplicate repos, which makes apt warn on every subsequent run.
#
# Takes an optional path to ignore, so we can ask "are there Debian sources
# OTHER than the file we ourselves added?" — which is how the duplicate
# cleanup below decides whether our file is still needed.
has_apt_sources() {
  local exclude="${1:-}" f
  shopt -s nullglob
  # Old format: any uncommented "deb " line that isn't a cdrom
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    [[ -n "$exclude" && "$f" == "$exclude" ]] && continue
    if grep -hs '^[[:space:]]*deb[[:space:]]' "$f" 2>/dev/null | grep -qv 'cdrom:'; then
      shopt -u nullglob; return 0
    fi
  done
  # deb822 format: any URIs: line in a .sources file
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    [[ -n "$exclude" && "$f" == "$exclude" ]] && continue
    if grep -qs '^[[:space:]]*URIs:' "$f"; then
      shopt -u nullglob; return 0
    fi
  done
  shopt -u nullglob
  return 1
}

# An earlier run could add trixie.list at a moment when the stock sources
# looked absent. Once both exist, apt prints a "configured multiple times"
# warning for every duplicated target on every single run. Ours is the
# redundant one — retire it (renamed, not deleted, so it's recoverable).
OUR_LIST=/etc/apt/sources.list.d/trixie.list
if [[ -f "$OUR_LIST" ]] && has_apt_sources "$OUR_LIST"; then
  echo "Debian repos are configured elsewhere too — retiring our redundant"
  echo "$OUR_LIST (moved to $OUR_LIST.disabled) to stop apt's duplicate warnings."
  sudo mv "$OUR_LIST" "$OUR_LIST.disabled"
fi

if has_apt_sources; then
  echo "Debian repos already configured — leaving apt sources alone."
else
  echo "No Debian repos found; adding Trixie main + security..."
  sudo tee /etc/apt/sources.list.d/trixie.list >/dev/null <<'EOF'
deb http://deb.debian.org/debian trixie main
deb http://security.debian.org/debian-security trixie-security main
EOF
fi

# Not -qq here: -qq hides the very errors we need when this fails, and a
# failing third-party repo (charm, docker) is the most common reason it does.
# -q keeps it tidy without gagging apt.
log "Updating apt package lists"
if ! apt_get update; then
  warn "apt-get update failed."
  warn "Usual cause: a third-party repo in /etc/apt/sources.list.d/ is"
  warn "unreachable, unsigned, or has no packages for this Debian release."
  warn "Look at the errors above — the failing repo is named in them."
  warn ""
  warn "To see what's configured:  ls /etc/apt/sources.list.d/"
  warn "Remove a broken one with:  sudo rm /etc/apt/sources.list.d/<name>.list"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Base packages
# ---------------------------------------------------------------------------
log "Installing base packages"
apt_get install -y \
  ca-certificates curl gnupg \
  ifupdown openssh-server sudo tmux pv \
  git python3-venv python3-pip \
  jq

add_user_to_group sudo || warn "No 'sudo' group on this system; skipping."

# ---------------------------------------------------------------------------
# 4. Docker
# ---------------------------------------------------------------------------
log "Installing Docker CE"
if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed ($(docker --version)), skipping install."
else
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  write_docker_list() {
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $1 stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  }

  echo "Using Docker repo codename: ${DOCKER_CODENAME}"
  write_docker_list "$DOCKER_CODENAME"

  # Docker sometimes lags a fresh Debian release. If this codename has no
  # packages, fall back to bookworm — the binaries are compatible and this is
  # the workaround the original Trixie build needed.
  if ! apt_get update 2>/dev/null \
     || ! apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    if [[ "$DOCKER_CODENAME" != "bookworm" ]]; then
      warn "No Docker packages for '${DOCKER_CODENAME}' — retrying with bookworm."
      write_docker_list bookworm
      apt_get update
      if ! apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        warn "Docker install failed against both '${DOCKER_CODENAME}' and bookworm."
        warn "Check https://download.docker.com/linux/debian/dists/ for what's published."
        exit 1
      fi
    else
      warn "Docker install failed against codename 'bookworm'."
      warn "Check https://download.docker.com/linux/debian/dists/ for what's published."
      exit 1
    fi
  fi
fi

add_user_to_group docker || warn "No 'docker' group found after install."

# Installed but not running is its own failure mode — a VM cloned from a
# template, or a package installed while systemd was masked, leaves a docker
# binary that errors on every call. Checking beats assuming.
if command -v systemctl >/dev/null 2>&1; then
  if sudo systemctl is-active --quiet docker; then
    echo "Docker service is running."
  else
    echo "Docker service isn't running — enabling and starting it."
    sudo systemctl enable --now docker
  fi
fi

if ! sudo docker info >/dev/null 2>&1; then
  warn "Docker is installed but 'docker info' fails even under sudo."
  warn "Check: sudo systemctl status docker  and  sudo journalctl -u docker -n 50"
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Containerlab
# ---------------------------------------------------------------------------
log "Installing Containerlab"
if command -v containerlab >/dev/null 2>&1; then
  # `containerlab version` leads with a blank line and an ASCII banner, so
  # head -1 yields "". Grab the first line that actually names a version.
  CLAB_VER="$(containerlab version 2>/dev/null | grep -im1 'version:' | tr -s ' ')"
  CLAB_VER="${CLAB_VER:-version unknown}"
  echo "Containerlab already installed (${CLAB_VER}), skipping."
else
  bash -c "$(curl -sL https://get.containerlab.dev)"
fi

# clab_admins group is created by the containerlab .deb postinst
if ! add_user_to_group clab_admins; then
  warn "clab_admins group not found — containerlab install may need review."
fi

# ---------------------------------------------------------------------------
# 6. Working directories
# ---------------------------------------------------------------------------
log "Setting up ~/labs working directory"
mkdir -p "$LABS_DIR"/{topologies,automation}
cp -n "$REPO_DIR"/topologies/*.yml "$LABS_DIR/topologies/" 2>/dev/null || true
cp -rn "$REPO_DIR"/automation/* "$LABS_DIR/automation/" 2>/dev/null || true
echo "Working tree ready at $LABS_DIR"

# ---------------------------------------------------------------------------
# 7. Python automation environment (Ansible / Nornir / NAPALM / Netmiko)
# ---------------------------------------------------------------------------
# Preferred path: uv (https://astral.sh/uv) — a single Rust-native binary
# that replaces pip + venv + pip-tools, and is dramatically faster on a
# resource-constrained lab VM. Falls back to plain python3 -m venv + pip if
# uv can't be installed (offline box, restricted network policy, etc.) —
# either path produces the same venv layout, so `netauto` works the same
# way regardless of which one built it.
log "Setting up the Python automation environment"

# setup.sh sets CLAB_FORCE_PIP=1 if the user explicitly chose plain pip.
if [[ "${CLAB_FORCE_PIP:-0}" == "1" ]]; then
  echo "CLAB_FORCE_PIP set — skipping uv, using python3 -m venv + pip."
elif ! command -v uv >/dev/null 2>&1; then
  echo "uv not found — installing (https://astral.sh/uv)..."
  if curl -LsSf https://astral.sh/uv/install.sh | sh; then
    export PATH="$HOME/.local/bin:$PATH"
  else
    warn "uv install failed — falling back to python3 -m venv + pip."
  fi
fi

# A venv is "usable" if it has an activate script. A directory that exists but
# lacks one is a half-built venv from an interrupted run — rebuild rather than
# reuse, or the `source` below fails with something far less obvious.
venv_is_usable() { [[ -f "$VENV_DIR/bin/activate" ]]; }

if [[ "${CLAB_FORCE_PIP:-0}" != "1" ]] && command -v uv >/dev/null 2>&1; then
  echo "Using uv ($(uv --version))."

  # `uv venv` errors out if the target already exists, so check first. The old
  # code paired `--python 3.12` with a bare `|| uv venv "$VENV_DIR"` fallback
  # meant for "3.12 isn't available" — but it swallowed every other failure
  # too, then retried the identical command and failed the same way. That made
  # the second run of this supposedly re-runnable script fail every time.
  if venv_is_usable; then
    echo "Reusing the existing venv at $VENV_DIR."
  else
    venv_flags=()
    [[ -d "$VENV_DIR" ]] && {
      echo "Incomplete venv at $VENV_DIR — rebuilding it."
      venv_flags=(--clear)
    }
    if ! uv venv "${venv_flags[@]+"${venv_flags[@]}"}" --python 3.12 "$VENV_DIR"; then
      echo "Python 3.12 unavailable to uv — using its default interpreter."
      uv venv "${venv_flags[@]+"${venv_flags[@]}"}" "$VENV_DIR"
    fi
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  uv pip install --quiet -r "$REPO_DIR/automation/requirements.txt"
  ansible-galaxy collection install -r "$REPO_DIR/automation/ansible/requirements.yml"
  deactivate
  echo "(Prefer the full uv workflow with a lockfile? See automation/pyproject.toml"
  echo " and run: cd automation && uv sync)"
else
  echo "Using python3 -m venv + pip (uv unavailable)."
  if venv_is_usable; then
    echo "Reusing the existing venv at $VENV_DIR."
  else
    # --clear is a no-op on a fresh path and cleans out a half-built one.
    python3 -m venv --clear "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  pip install --quiet --upgrade pip
  pip install --quiet -r "$REPO_DIR/automation/requirements.txt"
  ansible-galaxy collection install -r "$REPO_DIR/automation/ansible/requirements.yml"
  deactivate
fi

chmod +x "$LABS_DIR/automation/link-inventory.sh" 2>/dev/null || true

# This script is meant to be re-runnable, so don't stack up duplicate aliases
# in .bashrc every time someone runs it again.
if ! grep -q 'added by clab-bootstrap' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<EOF

# Network automation venv (added by clab-bootstrap)
alias netauto="source $VENV_DIR/bin/activate"
EOF
fi

log "Bootstrap complete."
cat <<EOF

Next steps:
  1. Log out and back in (or run: newgrp docker && newgrp clab_admins)
     so your new group memberships take effect.
  2. Bring cEOS64-lab-<version>.tar.xz + .sha512sum onto this VM (see README).
  3. Run: ./scripts/01-import-ceos.sh ~/cEOS64-lab-<version>.tar.xz
  4. Run: ./scripts/02-deploy-lab.sh
  5. Activate the automation venv any time with:  netauto
     (defined as a shell alias in ~/.bashrc)

EOF

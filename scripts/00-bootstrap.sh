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
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit if your environment differs
# ---------------------------------------------------------------------------

# Docker publishes packages under the Debian codename directly now. If apt
# 404s on this during `apt update` (Docker hasn't cut packages for a very
# new point release yet), set this to "bookworm" instead — that was the
# workaround needed on the original Trixie build.
DOCKER_CODENAME="trixie"

# $USER isn't always set in non-login/non-interactive shells (e.g. when this
# is called from setup.sh), and `set -u` would abort on it — fall back to
# `id -un`, which always works.
WORK_USER="${SUDO_USER:-${USER:-$(id -un)}}"
LABS_DIR="$HOME/labs"
VENV_DIR="$HOME/.venvs/netauto"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$1"; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it calls sudo itself), not as root." >&2
  exit 1
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
has_apt_sources() {
  # Old format: any uncommented "deb " line that isn't a cdrom
  if grep -rhs '^[[:space:]]*deb[[:space:]]' \
       /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
       | grep -qv 'cdrom:'; then
    return 0
  fi
  # deb822 format: any URIs: line in a .sources file
  if grep -rqs '^[[:space:]]*URIs:' /etc/apt/sources.list.d/*.sources 2>/dev/null; then
    return 0
  fi
  return 1
}

if has_apt_sources; then
  echo "Debian repos already configured — leaving apt sources alone."
else
  echo "No Debian repos found; adding Trixie main + security..."
  sudo tee /etc/apt/sources.list.d/trixie.list >/dev/null <<'EOF'
deb http://deb.debian.org/debian trixie main
deb http://security.debian.org/debian-security trixie-security main
EOF
fi

sudo apt-get update -qq

# ---------------------------------------------------------------------------
# 3. Base packages
# ---------------------------------------------------------------------------
log "Installing base packages"
sudo apt-get install -y -qq \
  ca-certificates curl gnupg \
  ifupdown openssh-server sudo tmux pv \
  git python3-venv python3-pip \
  jq

sudo usermod -aG sudo "$WORK_USER" || true

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

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DOCKER_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -qq
  if ! sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    warn "Docker install failed against codename '${DOCKER_CODENAME}'."
    warn "Docker's repo may not have packages for this Trixie point release yet."
    warn "Edit DOCKER_CODENAME=bookworm near the top of this script and re-run."
    exit 1
  fi
fi

sudo usermod -aG docker "$WORK_USER"

# ---------------------------------------------------------------------------
# 5. Containerlab
# ---------------------------------------------------------------------------
log "Installing Containerlab"
if command -v containerlab >/dev/null 2>&1; then
  echo "Containerlab already installed ($(containerlab version 2>/dev/null | head -1)), skipping."
else
  bash -c "$(curl -sL https://get.containerlab.dev)"
fi

# clab_admins group is created by the containerlab .deb postinst
if getent group clab_admins >/dev/null 2>&1; then
  sudo usermod -aG clab_admins "$WORK_USER"
else
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

if [[ "${CLAB_FORCE_PIP:-0}" != "1" ]] && command -v uv >/dev/null 2>&1; then
  echo "Using uv ($(uv --version))."
  uv venv "$VENV_DIR" --python 3.12 2>/dev/null || uv venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  uv pip install --quiet -r "$REPO_DIR/automation/requirements.txt"
  ansible-galaxy collection install -r "$REPO_DIR/automation/ansible/requirements.yml"
  deactivate
  echo "(Prefer the full uv workflow with a lockfile? See automation/pyproject.toml"
  echo " and run: cd automation && uv sync)"
else
  echo "Using python3 -m venv + pip (uv unavailable)."
  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  pip install --quiet --upgrade pip
  pip install --quiet -r "$REPO_DIR/automation/requirements.txt"
  ansible-galaxy collection install -r "$REPO_DIR/automation/ansible/requirements.yml"
  deactivate
fi

chmod +x "$LABS_DIR/automation/link-inventory.sh" 2>/dev/null || true

cat >> "$HOME/.bashrc" <<EOF

# Network automation venv (added by clab-bootstrap)
alias netauto="source $VENV_DIR/bin/activate"
EOF

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

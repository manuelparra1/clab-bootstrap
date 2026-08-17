#!/usr/bin/env bash
#
# setup.sh — guided, interactive setup for the containerlab automation lab.
#
# This is the "just run this" entry point. It asks what you want, explains
# the trade-offs as it goes, and calls the scripts in scripts/ for you. It
# doesn't do anything you couldn't do by running those scripts yourself —
# see README.md if you'd rather drive manually.
#
#   ./setup.sh
#
# Everything here is safe to re-run. Steps that are already done get
# detected and skipped.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_DIR/lib/ui.sh"

export UI_LOG="/tmp/clab-setup.log"
: > "$UI_LOG"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  ui_err "Run this as your normal user (it calls sudo itself), not as root."
  exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
  ui_warn "This wasn't built or tested on non-Debian systems. Continuing anyway."
fi

ui_header "Containerlab Network Automation Lab — Setup"

cat <<'INTRO'
  This will set up a network automation lab on this VM:

    Docker + Containerlab      run virtual Arista cEOS topologies
    Python automation tooling  Nornir / NAPALM / Netmiko (+ optional Ansible)
    A 2-node test topology     to prove the whole thing works

  You'll be asked a few questions. Defaults are sensible — if you're not
  sure, take them. Nothing here is irreversible.

INTRO

if ! ui_confirm "Ready to start?"; then
  ui_info "No problem. Run ./setup.sh whenever you're ready."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight: sudo + prerequisites
#
# This has to happen here, before the first ui_spin. Spinners hide prompts,
# so any password or apt question asked later reads as a hang.
# ---------------------------------------------------------------------------
ui_step "Checking prerequisites"
if ! ui_ensure_sudo; then
  exit 1
fi
# Must run before anything touches apt — a repo with a missing signing key
# makes every apt-get update fail, including the one in ui_ensure_base_deps.
if ! ui_repair_apt_sources; then
  exit 1
fi
if ! ui_ensure_base_deps; then
  exit 1
fi
ui_ok "Prerequisites OK"

# ---------------------------------------------------------------------------
# Step 0: pretty output (gum)
# ---------------------------------------------------------------------------
if ! ui_has_gum; then
  ui_step "Optional: nicer terminal UI"
  ui_note "gum (github.com/charmbracelet/gum) gives this script real menus,
spinners, and styled prompts instead of plain text. It's a small Go
binary from Charm, installed from their apt repo.

Purely cosmetic — everything works without it."
  if ui_confirm "Install gum for a nicer setup experience?"; then
    # set -e matters: without it a failed step here just falls through to the
    # next one, which is how a half-configured apt repo used to get left behind.
    if ui_spin "Installing gum" bash -c "set -e; source '$REPO_DIR/lib/ui.sh'; ui_install_gum"; then
      # Re-source so the rest of this run uses the gum code paths.
      # shellcheck source=lib/ui.sh
      source "$REPO_DIR/lib/ui.sh"
      ui_ok "gum installed — enjoy the colors"
    else
      ui_warn "gum install failed; continuing with plain text output."
    fi
  else
    ui_info "Skipping gum. Using plain text output."
  fi
fi

# ---------------------------------------------------------------------------
# Step 1: base system (Docker, Containerlab, Python env)
# ---------------------------------------------------------------------------
ui_header "Step 1 of 4 — Base system"

NEED_BOOTSTRAP=yes
if command -v docker >/dev/null 2>&1 && command -v containerlab >/dev/null 2>&1; then
  ui_ok "Docker and Containerlab are already installed"
  if ! ui_confirm "Re-run the bootstrap anyway (safe, just slower)?" default_no; then
    NEED_BOOTSTRAP=no
  fi
fi

if [[ "$NEED_BOOTSTRAP" == "yes" ]]; then
  ui_note "About to install: Docker CE, Containerlab, base packages, and a
Python virtualenv with the automation libraries.

The Python env is built with uv (astral.sh/uv) — a single fast binary that
replaces pip + venv. If uv can't be installed, it falls back to plain pip
automatically. Either way you end up with the same venv."

  PYTHON_TOOL=$(ui_choose "How should the Python environment be built?" \
    "uv (recommended — much faster)" \
    "plain pip + venv (no extra tooling)")

  if [[ "$PYTHON_TOOL" == plain* ]]; then
    export CLAB_FORCE_PIP=1
    ui_info "Will use python3 -m venv + pip."
  fi

  ui_info "This takes a few minutes. Full log: $UI_LOG"
  if ! ui_spin "Running bootstrap (Docker, Containerlab, Python env)" \
      bash "$REPO_DIR/scripts/00-bootstrap.sh"; then
    ui_err "Bootstrap failed. See $UI_LOG for details."
    exit 1
  fi

  ui_warn "Group membership changed (docker, clab_admins)."
  ui_info "Those take effect in a NEW login shell. This script will keep"
  ui_info "working via sudo, but log out and back in when it's done."
fi

# ---------------------------------------------------------------------------
# Step 2: cEOS image
# ---------------------------------------------------------------------------
ui_header "Step 2 of 4 — Arista cEOS image"

# $USER may be unset in a non-login shell; id -un always works.
THIS_USER="${USER:-$(id -un)}"
THIS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
THIS_IP="${THIS_IP:-<VM-IP>}"

if docker images 2>/dev/null | grep -q '^ceos ' || sudo docker images 2>/dev/null | grep -q '^ceos '; then
  ui_ok "A cEOS image is already imported"
else
  ui_note "The cEOS-lab image can't be downloaded automatically — Arista puts
it behind a free account, and their EULA doesn't allow redistributing it.
So everyone grabs their own copy.

  1. On your LAPTOP (not this VM), log in at:
       https://www.arista.com/en/support/software-download
  2. Software Downloads -> cEOS-lab -> newest 64-bit .tar.xz
     (also grab the matching .sha512sum file)
  3. Verify it downloaded intact:
       shasum -a 512 -c cEOS64-lab-<version>.tar.xz.sha512sum
  4. Copy it here:
       scp cEOS64-lab-<version>.tar.xz ${THIS_USER}@${THIS_IP}:~/"

  if ui_confirm "Is the .tar.xz file on this VM now?"; then
    # Try to find it automatically before asking.
    FOUND=$(find "$HOME" -maxdepth 2 -name 'cEOS*-lab-*.tar.xz' 2>/dev/null | head -1)
    if [[ -n "$FOUND" ]]; then
      ui_ok "Found: $FOUND"
      if ! ui_confirm "Import this one?"; then
        FOUND=""
      fi
    fi
    if [[ -z "$FOUND" ]]; then
      FOUND=$(ui_input "Full path to the cEOS .tar.xz:" "$HOME/cEOS64-lab-4.35.3F.tar.xz")
    fi

    if [[ -f "$FOUND" ]]; then
      ui_info "Verifying checksum and importing (this takes a few minutes)..."
      if ui_spin "Importing cEOS into Docker" \
          bash "$REPO_DIR/scripts/01-import-ceos.sh" "$FOUND"; then
        ui_ok "cEOS imported"
      else
        ui_err "Import failed — see $UI_LOG"
        ui_info "Most common cause: the file got corrupted in transit."
        ui_info "Re-verify on your laptop, re-scp, and run ./setup.sh again."
        exit 1
      fi
    else
      ui_err "No file at: $FOUND"
      ui_info "Get the image onto the VM, then re-run ./setup.sh."
      exit 1
    fi
  else
    ui_info "No problem — grab the image, then re-run ./setup.sh."
    ui_info "Everything installed so far is already done and will be skipped."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: deploy the test topology
# ---------------------------------------------------------------------------
ui_header "Step 3 of 4 — Deploy the test lab"

ui_note "This deploys a 2-node topology: two Arista switches wired
back-to-back. It's a smoke test — if these two come up and can see each
other, the whole platform works and you can build anything from here."

if ui_confirm "Deploy the test topology now?"; then
  if ui_spin "Deploying testlab (cEOS nodes take ~60s to boot)" \
      bash "$REPO_DIR/scripts/02-deploy-lab.sh"; then
    ui_ok "Lab deployed"
    sudo containerlab inspect -t "$REPO_DIR/topologies/testlab.clab.yml" 2>/dev/null || true
  else
    ui_err "Deploy failed — see $UI_LOG"
    exit 1
  fi

  # Link the generated inventories so the automation scripts can find them.
  LAB_DIR="$REPO_DIR/topologies/clab-testlab"
  [[ -d "$HOME/labs/topologies/clab-testlab" ]] && LAB_DIR="$HOME/labs/topologies/clab-testlab"
  if [[ -d "$LAB_DIR" ]]; then
    if bash "$REPO_DIR/automation/link-inventory.sh" "$LAB_DIR" >>"$UI_LOG" 2>&1; then
      ui_ok "Automation inventories linked"
    else
      ui_warn "Couldn't link inventories automatically — run this by hand:"
      ui_info "  ./automation/link-inventory.sh $LAB_DIR"
    fi
  fi
else
  ui_info "Skipped. Deploy later with: ./scripts/02-deploy-lab.sh"
fi

# ---------------------------------------------------------------------------
# Step 4: pick an automation path
# ---------------------------------------------------------------------------
ui_header "Step 4 of 4 — Automation"

ui_note "Two ways to automate this lab, both fully set up:

  Nornir / NAPALM / Netmiko  — pure Python, zero credential setup needed.
                               Four scripts that build from 'SSH one device'
                               up to 'declarative, self-healing config'.

  Ansible                    — the YAML/playbook route. More setup (Galaxy
                               collections, encrypted vault) but it's what
                               most enterprises standardize on.

You don't have to choose permanently — both stay installed."

AUTOMATION_PATH=$(ui_choose "Which would you like to try first?" \
  "Nornir demo (recommended — start here)" \
  "Ansible playbook" \
  "Neither right now — just finish setup")

case "$AUTOMATION_PATH" in
  Nornir*)
    ui_note "The demo is four scripts, meant to be run in order:

  01_netmiko_hello.py     one device, one command — the simplest thing
  02_nornir_scale.py      same thing, every device at once
  03_napalm_facts.py      structured JSON instead of scraped CLI text
  04_idempotent_deploy.py describe the desired config, let it enforce

Run 04 twice — the second run does nothing, because nothing needs
changing. That's idempotency, and it's the whole point."

    if ui_confirm "Run the first script now as a quick test?"; then
      ui_info "Running 01_netmiko_hello.py..."
      (
        cd "$REPO_DIR/automation/nornir" || exit 1
        # shellcheck disable=SC1090
        source "$HOME/.venvs/netauto/bin/activate" 2>/dev/null || true
        python3 01_netmiko_hello.py
      ) || ui_warn "Script errored — see automation/nornir/README.md for troubleshooting."
    fi
    ;;
  Ansible*)
    ui_note "Ansible needs a couple of one-time setup steps the Nornir path
doesn't: Galaxy collections (installed already by the bootstrap) and an
encrypted vault holding the device credentials.

Set up the vault with:
  cd automation/ansible/group_vars/ceos
  cp vault.yml.example vault.yml
  nano vault.yml
  ansible-vault encrypt vault.yml

Then run a playbook with:
  cd automation/ansible
  ansible-playbook --ask-vault-pass playbooks/gather_facts.yml"
    ;;
  *)
    ui_info "Fine — everything's installed whenever you want it."
    ;;
esac

# ---------------------------------------------------------------------------
# Optional: secrets backend tour
# ---------------------------------------------------------------------------
if ui_confirm "Want to set up a secrets manager for device credentials?" default_no; then
  ui_note "This lab doesn't need one — Containerlab already knows cEOS's
default admin/admin, so the scripts just work. But in a real network you'd
never rely on that, and these are three tools worth knowing:

  .env         plaintext file, gitignored. Zero setup, zero protection.
  pass         GPG-encrypted, one file per secret. The classic Unix answer.
  sops + age   encrypts values but keeps keys readable, so encrypted files
               still diff cleanly in git. Closest to real CI/GitOps practice."

  SECRETS_CHOICE=$(ui_choose "Set one up now?" \
    ".env (simplest)" \
    "pass (GPG-based)" \
    "sops + age (recommended for teams)" \
    "Just show me the docs")

  case "$SECRETS_CHOICE" in
    .env*)
      cp -n "$REPO_DIR/automation/nornir/.env.example" "$REPO_DIR/automation/nornir/.env" 2>/dev/null || true
      ui_ok "Created automation/nornir/.env (gitignored)"
      ui_info "Edit it, then run scripts via: ./run-with-env.sh python3 02_nornir_scale.py"
      ;;
    pass*)
      if ui_spin "Installing pass and gnupg" sudo apt-get install -y -qq pass gnupg; then
        ui_ok "Installed"
      fi
      ui_info "Next: create a GPG key, then 'pass init <key-id>'."
      ui_info "Full steps: automation/nornir/SECRETS.md (Option B)"
      ;;
    sops*)
      if ui_spin "Installing age" sudo apt-get install -y -qq age; then
        ui_ok "age installed"
      fi
      ui_info "sops has no Debian package — install the .deb from GitHub releases."
      ui_info "Full steps: automation/nornir/SECRETS.md (Option C)"
      ;;
    *)
      ui_info "See automation/nornir/SECRETS.md — all three compared."
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
ui_header "Setup complete"

cat <<OUTRO
  What to do next:

    1. Log out and back in (group changes for docker / clab_admins)
    2. Activate the Python environment any time with:   netauto
    3. Try the automation demo:
         cd automation/nornir && python3 02_nornir_scale.py
    4. Tear the lab down when you're done (it eats RAM):
         ./scripts/02-deploy-lab.sh topologies/testlab.clab.yml destroy

  Docs:
    README.md                      overview, tooling choices, troubleshooting
    automation/nornir/README.md    the demo walkthrough
    automation/nornir/SECRETS.md   secrets managers compared
    docs/vcenter-vm-setup.md       how this VM was built (for the next person)

  Setup log: $UI_LOG

OUTRO

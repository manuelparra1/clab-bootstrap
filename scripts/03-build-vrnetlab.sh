#!/usr/bin/env bash
#
# 03-build-vrnetlab.sh [path-to-qcow2] [vendor]
#
# Turns a vendor VM image (a .qcow2) into a Containerlab-runnable container,
# using vrnetlab. Defaults to FortiGate.
#
#   ./scripts/03-build-vrnetlab.sh                                  # find the qcow2 itself
#   ./scripts/03-build-vrnetlab.sh ~/fortinet-FGT-v7.0.9-*.qcow2
#   ./scripts/03-build-vrnetlab.sh ~/some-image.qcow2 fortigate
#
# Why this exists: FortiGate isn't a container and isn't on any registry. It
# has to be built locally, the build needs nested virtualization, and the image
# tag vrnetlab produces has changed between vrnetlab versions — three separate
# ways to get stuck before you ever deploy a topology. This does all three and
# tells you the tag it actually produced.
#
# Safe to re-run: it skips the build if the image already exists, and updates
# an existing vrnetlab clone instead of failing on it.
#
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/ui.sh
source "$REPO_DIR/lib/ui.sh"

QCOW="${1:-}"
VENDOR="${2:-fortigate}"
VRNETLAB_DIR="${VRNETLAB_DIR:-$HOME/vrnetlab}"

_on_err() {
  local rc=$?
  ui_err "03-build-vrnetlab.sh failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND} (exit $rc)"
  exit "$rc"
}
trap _on_err ERR

# ---------------------------------------------------------------------------
# 1. Nested virtualization
#
# Check before doing anything expensive. Without /dev/kvm the build either
# fails or silently falls back to emulation and takes forever, and the fix is
# a hypervisor setting that needs the VM powered off — so finding out now
# rather than 20 minutes in matters.
# ---------------------------------------------------------------------------
ui_step "Checking nested virtualization"
if [[ -e /dev/kvm ]]; then
  ui_ok "/dev/kvm present"
else
  ui_err "/dev/kvm is missing — vrnetlab can't boot the VM image without it."
  ui_info ""
  ui_info "vSphere:  power the VM OFF, then Edit Settings -> Virtual Hardware"
  ui_info "          -> expand CPU -> tick 'Expose hardware assisted"
  ui_info "          virtualization to the guest OS'. Power back on."
  ui_info ""
  ui_info "Proxmox:  set the VM's CPU type to 'host' and enable nesting on the"
  ui_info "          Proxmox host (see docs/proxmox-vm-setup.md)."
  ui_info ""
  ui_info "Then check with:  ls -l /dev/kvm"
  exit 1
fi

if ! grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
  ui_warn "No vmx/svm CPU flags visible — virtualization may still be emulated."
  ui_info "The build may work but will be very slow."
fi

# ---------------------------------------------------------------------------
# 2. Build dependencies
# ---------------------------------------------------------------------------
ui_step "Checking build dependencies"
NEED=()
command -v git  >/dev/null 2>&1 || NEED+=(git)
command -v make >/dev/null 2>&1 || NEED+=(make)
command -v qemu-img >/dev/null 2>&1 || NEED+=(qemu-utils)
if [[ ${#NEED[@]} -gt 0 ]]; then
  ui_info "Installing: ${NEED[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${NEED[@]}"
fi
ui_ok "Build dependencies present"

if ! sudo docker info >/dev/null 2>&1; then
  ui_err "Docker isn't responding — run ./setup.sh first."
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. vrnetlab checkout
# ---------------------------------------------------------------------------
ui_step "Preparing vrnetlab"
if [[ -d "$VRNETLAB_DIR/.git" ]]; then
  ui_info "Updating existing clone at $VRNETLAB_DIR"
  git -C "$VRNETLAB_DIR" pull --ff-only >/dev/null 2>&1 \
    || ui_warn "Couldn't fast-forward the clone; using it as-is."
else
  ui_info "Cloning hellt/vrnetlab into $VRNETLAB_DIR"
  git clone --depth 1 https://github.com/hellt/vrnetlab.git "$VRNETLAB_DIR"
fi
ui_ok "vrnetlab ready at $VRNETLAB_DIR"

# The per-vendor directory name has changed across vrnetlab releases
# (fortios -> fortinet_fortigate, etc). Find it rather than hardcoding.
ui_step "Locating the $VENDOR build directory"
BUILD_DIR=""
case "$VENDOR" in
  fortigate|fortios|fortinet*) CANDIDATES=(fortinet_fortigate fortigate fortios) ;;
  *)                           CANDIDATES=("$VENDOR") ;;
esac
for c in "${CANDIDATES[@]}"; do
  if [[ -d "$VRNETLAB_DIR/$c" ]]; then BUILD_DIR="$VRNETLAB_DIR/$c"; break; fi
done
if [[ -z "$BUILD_DIR" ]]; then
  ui_err "No build directory for '$VENDOR' in $VRNETLAB_DIR"
  ui_info "Tried: ${CANDIDATES[*]}"
  ui_info "Available:"
  find "$VRNETLAB_DIR" -maxdepth 1 -mindepth 1 -type d ! -name '.*' \
    -printf '      %f\n' 2>/dev/null | sort | head -30
  exit 1
fi
ui_ok "Using $(basename "$BUILD_DIR")/"

# ---------------------------------------------------------------------------
# 4. The qcow2
# ---------------------------------------------------------------------------
ui_step "Locating the disk image"
if [[ -z "$QCOW" ]]; then
  # Already staged in the build dir from a previous run?
  QCOW="$(find "$BUILD_DIR" -maxdepth 1 -name '*.qcow2' 2>/dev/null | head -1)"
fi
if [[ -z "$QCOW" ]]; then
  QCOW="$(find "$HOME" -maxdepth 2 -iname '*FGT*.qcow2' -o -maxdepth 2 -iname '*forti*.qcow2' 2>/dev/null | head -1)"
fi
if [[ -z "$QCOW" || ! -f "$QCOW" ]]; then
  ui_err "No .qcow2 found."
  ui_info "Download the FortiGate image from the team Drive:"
  ui_info "  https://drive.google.com/drive/folders/1kBDv_xgv4T4NQJfWZtLKkCnYbmcfs9KU?usp=drive_link"
  ui_info "  -> ContainerLab/Fortigate Images/"
  ui_info "or from https://support.fortinet.com (Download -> VM Images -> KVM)."
  ui_info ""
  # Compute separately: under `set -e` + pipefail a failing `hostname -I`
  # inside the message would abort the script mid-error-message.
  THIS_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  ui_info "Then:  scp <image>.qcow2 $(id -un)@${THIS_IP:-<VM-IP>}:~/"
  ui_info "and re-run:  ./scripts/03-build-vrnetlab.sh"
  exit 1
fi
ui_ok "Found: $QCOW"

if [[ "$(dirname "$(readlink -f "$QCOW")")" != "$(readlink -f "$BUILD_DIR")" ]]; then
  ui_info "Copying into $(basename "$BUILD_DIR")/ (vrnetlab builds from there)"
  cp -n "$QCOW" "$BUILD_DIR/"
fi

# ---------------------------------------------------------------------------
# 5. Build
#
# vrnetlab derives the image name and tag from the qcow2 filename, and the
# scheme has changed between releases. Rather than predicting it, snapshot the
# image list either side of the build and report what actually appeared.
# ---------------------------------------------------------------------------
BEFORE="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u)"

ui_step "Building the container image"
ui_info "This boots the VM once to prepare it — several minutes is normal."
if ! ui_run "make ($(basename "$BUILD_DIR"))" bash -c "cd '$BUILD_DIR' && make"; then
  ui_err "Build failed. Full log: $UI_LOG"
  ui_info "Common causes: /dev/kvm missing, not enough RAM, or a qcow2 whose"
  ui_info "filename vrnetlab doesn't recognise (it parses the version from it)."
  exit 1
fi

AFTER="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u)"
NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -v '<none>' || true)"

ui_header "Build complete"
if [[ -z "$NEW" ]]; then
  ui_warn "No new image tag appeared — it may already have existed."
  ui_info "Check manually:  docker images | grep -i '$VENDOR'"
  sudo docker images | grep -i -E 'forti|vrnetlab' || true
  exit 0
fi

ui_ok "New image(s):"
while IFS= read -r i; do ui_info "  $i"; done <<<"$NEW"
echo

# ---------------------------------------------------------------------------
# 6. Reconcile the topology
#
# The single most common way this goes wrong: the built tag doesn't match the
# `image:` line in the topology, and containerlab then tries to pull it from a
# registry and fails with a misleading "pull access denied". Offer to fix it.
# ---------------------------------------------------------------------------
BUILT="$(printf '%s\n' "$NEW" | head -1)"
for topo in "$HOME/labs/topologies"/*.clab.yml "$REPO_DIR/topologies"/*.clab.yml; do
  [[ -f "$topo" ]] || continue
  CURRENT="$(grep -oE 'image:[[:space:]]*\S*(vr-fortios|fortinet_fortigate|fortigate)\S*' "$topo" 2>/dev/null | awk '{print $2}' | head -1)"
  [[ -n "$CURRENT" ]] || continue
  [[ "$CURRENT" == "$BUILT" ]] && { ui_ok "$(basename "$topo") already references $BUILT"; continue; }
  ui_warn "$(basename "$topo") references: $CURRENT"
  ui_info "You just built:               $BUILT"
  if ui_confirm "Update $(basename "$topo") to use $BUILT?"; then
    sed -i.bak "s|${CURRENT}|${BUILT}|g" "$topo"
    ui_ok "Updated (previous saved as $(basename "$topo").bak)"
  else
    ui_info "Left alone — deploy will stop until these match."
  fi
done

echo
ui_info "Deploy it with:"
ui_info "  ./lab topo memory-test.clab.yml && ./lab deploy"
ui_info ""
ui_info "FortiGate boots much more slowly than cEOS — give it several minutes."
ui_info "Default login is 'admin' with an EMPTY password; it forces a change."
